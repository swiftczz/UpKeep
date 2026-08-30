import Foundation

struct GitHubReleasesMetadata: Equatable, Sendable {
  let identifier: String
  let apiURL: URL
  let homepageURL: URL
}

enum GitHubReleasesDetector {
  private static let githubNeedle = Data("github.com/".utf8)
  private static let expressions = [
    #"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases/latest"#,
    #"https://api\.github\.com/repos/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases/latest"#,
  ].compactMap { try? NSRegularExpression(pattern: $0) }

  static func metadata(in data: Data) -> GitHubReleasesMetadata? {
    guard data.range(of: githubNeedle) != nil else { return nil }
    return metadata(in: String(decoding: data, as: UTF8.self))
  }

  static func metadata(in text: String) -> GitHubReleasesMetadata? {
    for expression in expressions {
      guard
        let match = expression.firstMatch(
          in: text,
          range: NSRange(text.startIndex..., in: text)
        ),
        let ownerRange = Range(match.range(at: 1), in: text),
        let repositoryRange = Range(match.range(at: 2), in: text)
      else {
        continue
      }

      let owner = String(text[ownerRange])
      let repository = String(text[repositoryRange]).replacingOccurrences(
        of: ".git",
        with: "",
        options: [.anchored, .backwards]
      )
      guard isRepositoryComponent(owner), isRepositoryComponent(repository),
        let apiURL = URL(
          string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest"
        ),
        let homepageURL = URL(string: "https://github.com/\(owner)/\(repository)")
      else {
        continue
      }

      return GitHubReleasesMetadata(
        identifier: "\(owner)/\(repository)",
        apiURL: apiURL,
        homepageURL: homepageURL
      )
    }
    return nil
  }

  static func matchesApplication(
    _ metadata: GitHubReleasesMetadata,
    name: String,
    bundleIdentifier: String
  ) -> Bool {
    guard let repository = metadata.identifier.split(separator: "/").last else {
      return false
    }
    let repositoryAliases = aliases(for: String(repository))
    let applicationValues = [name] + bundleIdentifier.split(separator: ".").map(String.init)
    return applicationValues.contains { value in
      !repositoryAliases.isDisjoint(with: aliases(for: value))
    }
  }

  private static func isRepositoryComponent(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".." && value.count <= 100
  }

  private static func aliases(for value: String) -> Set<String> {
    let normalized = value.unicodeScalars
      .filter(CharacterSet.alphanumerics.contains)
      .map(String.init)
      .joined()
      .lowercased()
    guard !normalized.isEmpty else { return [] }

    var values: Set<String> = [normalized]
    for suffix in ["desktop", "macos", "mac", "app"]
    where normalized.hasSuffix(suffix) && normalized.count > suffix.count + 2 {
      values.insert(String(normalized.dropLast(suffix.count)))
    }
    return values
  }
}

struct GitHubReleaseManifest: Equatable, Sendable {
  struct Asset: Equatable, Sendable {
    let name: String
    let downloadURL: URL
  }

  let version: String
  let releaseDate: Date?
  let releaseNotes: String?
  let releaseURL: URL?
  let assets: [Asset]

  static func parse(_ data: Data) -> GitHubReleaseManifest? {
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      json["draft"] as? Bool != true,
      json["prerelease"] as? Bool != true,
      let tag = (json["tag_name"] as? String)?.nonBlankValue,
      let version = releaseVersion(from: tag, fallback: json["name"] as? String)
    else {
      return nil
    }

    let assets = (json["assets"] as? [[String: Any]] ?? []).compactMap { value -> Asset? in
      guard let name = (value["name"] as? String)?.nonBlankValue,
        let rawURL = value["browser_download_url"] as? String,
        let downloadURL = SecureUpdateURL.https(string: rawURL)
      else {
        return nil
      }
      return Asset(name: name, downloadURL: downloadURL)
    }

    return GitHubReleaseManifest(
      version: version,
      releaseDate: (json["published_at"] as? String).flatMap(ISO8601Parsing.date),
      releaseNotes: (json["body"] as? String)?.nonBlankValue,
      releaseURL: (json["html_url"] as? String).flatMap(SecureUpdateURL.https(string:)),
      assets: assets
    )
  }

  func selectedPackage(
    architecture: MacCPUArchitecture = .current
  ) -> Asset? {
    assets
      .filter { macOSScore(of: $0.name) > 0 }
      .max { lhs, rhs in
        packageScore(lhs, architecture: architecture)
          < packageScore(rhs, architecture: architecture)
      }
  }

  var checksumsAsset: Asset? {
    assets.first { asset in
      let name = asset.name.lowercased()
      return name == "checksums.txt" || name == "sha256sums" || name == "sha256sums.txt"
    }
  }

  static func sha256(for fileName: String, in data: Data) -> String? {
    guard data.count <= 1_000_000, let text = String(data: data, encoding: .utf8) else {
      return nil
    }

    for line in text.split(whereSeparator: \.isNewline) {
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count >= 2 else { continue }
      let digest = String(fields[0]).lowercased()
      let listedName = String(fields[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
      if listedName == fileName, isSHA256(digest) {
        return digest
      }
    }

    let escaped = NSRegularExpression.escapedPattern(for: fileName)
    guard
      let expression = try? NSRegularExpression(
        pattern: #"(?i)SHA256\s*\("# + escaped + #"\)\s*=\s*([a-f0-9]{64})"#
      ),
      let match = expression.firstMatch(
        in: text,
        range: NSRange(text.startIndex..., in: text)
      ),
      let digestRange = Range(match.range(at: 1), in: text)
    else {
      return nil
    }
    return String(text[digestRange]).lowercased()
  }

  private static func releaseVersion(from tag: String, fallback: String?) -> String? {
    for candidate in [tag, fallback].compactMap({ $0 }) {
      guard
        let expression = try? NSRegularExpression(
          pattern: #"(?i)(?:^|[-_ ])v?(\d+(?:[._-]\d+)+(?:[-._]?[A-Za-z][A-Za-z0-9.-]*)?)"#
        ),
        let match = expression.firstMatch(
          in: candidate,
          range: NSRange(candidate.startIndex..., in: candidate)
        ),
        let range = Range(match.range(at: 1), in: candidate)
      else {
        continue
      }
      return String(candidate[range])
    }
    return nil
  }

  private func packageScore(_ asset: Asset, architecture: MacCPUArchitecture) -> Int {
    macOSScore(of: asset.name) * 1_000
      + ApplicationPackageInstaller.architectureScore(
        of: asset.name,
        architecture: architecture
      ) * 10
      + ApplicationPackageInstaller.packageKindScore(of: asset.name)
  }

  private func macOSScore(of fileName: String) -> Int {
    let name = fileName.lowercased()
    guard ApplicationPackageInstaller.packageKindScore(of: name) > 0 else { return 0 }
    if name.contains("linux") || name.contains("windows") || name.contains("win32")
      || name.contains("win64")
    {
      return 0
    }
    if name.hasSuffix(".dmg") { return 100 }
    if name.contains("macos") || name.contains("darwin") || name.contains("osx") {
      return 90
    }
    return name.hasSuffix(".zip") ? 20 : 0
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isHexDigit }
  }
}

struct GitHubReleasesUpdateProvider: Sendable {
  func check(_ application: AppRecord) async -> AppRecord {
    var application = application
    guard let apiURL = application.sourceURL,
      GitHubReleasesDetector.metadata(in: apiURL.absoluteString) != nil
    else {
      application.status = .selfManaged
      return application
    }

    do {
      let release = try await loadRelease(from: apiURL)
      let package = release.selectedPackage()
      application.homepageURL = application.homepageURL ?? release.releaseURL
      application.applyRemoteRelease(
        version: release.version,
        releaseDate: release.releaseDate,
        releaseNotes: release.releaseNotes,
        releaseNotesURL: release.releaseURL,
        canInstall: package != nil
          && ApplicationCodeSigning.teamIdentifier(at: application.applicationURL) != nil
      )
    } catch is CancellationError {
      return application
    } catch {
      application.status = .unavailable("GitHub Releases 更新源暂时无法访问。")
    }
    return application
  }

  func upgrade(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    guard let apiURL = application.sourceURL,
      GitHubReleasesDetector.metadata(in: apiURL.absoluteString) != nil
    else {
      throw ProcessRunnerError.failed(status: 1, message: "此应用没有安全的 GitHub Releases 更新源。")
    }

    progress(.indeterminate("正在检查更新…"))
    let release = try await loadRelease(from: apiURL)
    guard let package = release.selectedPackage() else {
      throw ProcessRunnerError.failed(status: 1, message: "GitHub Release 中没有兼容此 Mac 的安装包。")
    }

    let expectedSHA256 = await checksum(for: package, in: release)
    try await ApplicationPackageInstaller.install(
      from: package.downloadURL,
      replacing: application,
      expectedSHA512: nil,
      expectedSHA256: expectedSHA256,
      requiresTeamIdentifier: true,
      progress: progress
    )
  }

  private func loadRelease(from url: URL) async throws -> GitHubReleaseManifest {
    guard let data = try await UpdateHTTP.successfulData(from: url),
      data.count <= 5_000_000,
      let release = GitHubReleaseManifest.parse(data)
    else {
      throw ProcessRunnerError.failed(status: 1, message: "无法读取 GitHub Release。")
    }
    return release
  }

  private func checksum(
    for package: GitHubReleaseManifest.Asset,
    in release: GitHubReleaseManifest
  ) async -> String? {
    guard let checksums = release.checksumsAsset,
      let data = try? await UpdateHTTP.successfulData(from: checksums.downloadURL)
    else {
      return nil
    }
    return GitHubReleaseManifest.sha256(for: package.name, in: data)
  }
}
