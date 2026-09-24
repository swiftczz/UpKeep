import Foundation

struct GitHubReleasesMetadata: Equatable, Sendable {
  let identifier: String
  let apiURL: URL
  let homepageURL: URL
}

struct GitHubReleaseDownload: Equatable, Sendable {
  let owner: String
  let repository: String
  let tag: String
  let fileName: String

  var cacheKey: String {
    "\(owner)/\(repository)/\(tag)/\(fileName)"
  }

  var apiURL: URL? {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
    guard let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: allowed) else {
      return nil
    }
    return SecureUpdateURL.https(
      string: "https://api.github.com/repos/\(owner)/\(repository)/releases/tags/\(encodedTag)"
    )
  }

  static func parse(_ value: String) -> GitHubReleaseDownload? {
    guard let url = SecureUpdateURL.https(string: value) else {
      return nil
    }
    return parse(url)
  }

  static func parse(_ url: URL) -> GitHubReleaseDownload? {
    guard let host = url.host?.lowercased(),
      host == "github.com" || host == "www.github.com"
    else {
      return nil
    }

    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count == 6,
      parts[2].lowercased() == "releases",
      parts[3].lowercased() == "download"
    else {
      return nil
    }

    let owner = parts[0]
    let repository = parts[1].replacingOccurrences(
      of: ".git",
      with: "",
      options: [.anchored, .backwards]
    )
    let tag = parts[4]
    let fileName = parts[5]
    guard !owner.isEmpty, owner != "." && owner != "..",
      !repository.isEmpty, repository != "." && repository != "..",
      !tag.isEmpty, !fileName.isEmpty
    else {
      return nil
    }

    return GitHubReleaseDownload(
      owner: owner,
      repository: repository,
      tag: tag,
      fileName: fileName
    )
  }
}

enum GitHubReleasesDetector {
  private static let githubNeedle = Data("github.com/".utf8)
  private static let expressions = [
    #"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases/latest"#,
    #"https://api\.github\.com/repos/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases/latest"#,
    #"https://api\.github\.com/repos/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases(?!/)"#,
  ].compactMap { try? NSRegularExpression(pattern: $0) }

  static func metadata(in data: Data) -> GitHubReleasesMetadata? {
    guard data.range(of: githubNeedle) != nil else { return nil }
    return metadata(in: String(decoding: data, as: UTF8.self))
  }

  static func metadataCandidates(in data: Data) -> [GitHubReleasesMetadata] {
    guard data.range(of: githubNeedle) != nil else { return [] }
    return metadataCandidates(in: String(decoding: data, as: UTF8.self))
  }

  static func metadata(in text: String) -> GitHubReleasesMetadata? {
    metadataCandidates(in: text).first
  }

  static func metadataCandidates(in text: String) -> [GitHubReleasesMetadata] {
    var matches: [(location: Int, metadata: GitHubReleasesMetadata)] = []
    for expression in expressions {
      expression.enumerateMatches(
        in: text,
        range: NSRange(text.startIndex..., in: text)
      ) { match, _, _ in
        guard
          let match,
          let ownerRange = Range(match.range(at: 1), in: text),
          let repositoryRange = Range(match.range(at: 2), in: text)
        else {
          return
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
          return
        }

        matches.append(
          (
            match.range.location,
            GitHubReleasesMetadata(
              identifier: "\(owner)/\(repository)",
              apiURL: apiURL,
              homepageURL: homepageURL
            )
          )
        )
      }
    }

    var seen = Set<String>()
    return matches.sorted { $0.location < $1.location }.compactMap { match in
      guard seen.insert(match.metadata.identifier).inserted else { return nil }
      return match.metadata
    }
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
    let size: Int64?
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
      return Asset(
        name: name,
        downloadURL: downloadURL,
        size: JSONByteCount.parse(value["size"])
      )
    }

    return GitHubReleaseManifest(
      version: version,
      releaseDate: (json["published_at"] as? String).flatMap(ISO8601Parsing.date),
      releaseNotes: (json["body"] as? String)?.nonBlankValue,
      releaseURL: (json["html_url"] as? String).flatMap(SecureUpdateURL.https(string:)),
      assets: assets
    )
  }

  static func packageByteCount(named fileName: String, in data: Data) -> Int64? {
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      json["draft"] as? Bool != true
    else {
      return nil
    }

    let target = fileName.lowercased()
    for asset in json["assets"] as? [[String: Any]] ?? [] {
      let name = (asset["name"] as? String)?.nonBlankValue
      let downloadName = (asset["browser_download_url"] as? String)
        .flatMap(URL.init(string:))?
        .lastPathComponent
      guard name?.lowercased() == target || downloadName?.lowercased() == target else {
        continue
      }
      return JSONByteCount.parse(asset["size"])
    }
    return nil
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
      let listedName = normalizedChecksumFileName(String(fields[1]))
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

  private static func normalizedChecksumFileName(_ value: String) -> String {
    var name = value.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
    while name.hasPrefix("./") {
      name.removeFirst(2)
    }
    return (name as NSString).lastPathComponent
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
      let installability = await installability(
        of: package,
        in: release,
        replacing: application
      )
      application.homepageURL = application.homepageURL ?? release.releaseURL
      application.applyRemoteRelease(
        version: release.version,
        releaseDate: release.releaseDate,
        releaseNotes: release.releaseNotes,
        releaseNotesURL: release.releaseURL,
        packageByteCount: package?.size,
        canInstall: installability.canInstall
      )
    } catch is CancellationError {
      return application
    } catch let error as GitHubAPIError {
      application.status = .unavailable(error.localizedDescription)
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

    let installability = await installability(
      of: package,
      in: release,
      replacing: application
    )
    guard installability.canInstall else {
      throw ProcessRunnerError.failed(status: 1, message: "GitHub Release 没有提供可验证的 macOS 更新包。")
    }
    try await ApplicationPackageInstaller.install(
      from: package.downloadURL,
      replacing: application,
      expectedSHA512: nil,
      expectedSHA256: installability.expectedSHA256,
      requiresValidSignature: installability.requiresValidSignature,
      requiresTeamIdentifier: installability.requiresTeamIdentifier,
      progress: progress
    )
  }

  private func loadRelease(from url: URL) async throws -> GitHubReleaseManifest {
    guard let result = try await UpdateHTTP.response(from: url) else {
      throw ProcessRunnerError.failed(status: 1, message: "未收到 GitHub 发布信息响应，请稍后重试。")
    }
    guard (200..<300).contains(result.statusCode) else {
      throw GitHubAPIError(message: "GitHub 发布信息请求失败（HTTP \(result.statusCode)），请稍后重试。")
    }
    let data = result.data
    guard data.count <= 5_000_000,
      let release = GitHubReleaseManifest.parse(data)
    else {
      throw ProcessRunnerError.failed(status: 1, message: "无法读取 GitHub Release。")
    }
    return release
  }

  private func installability(
    of package: GitHubReleaseManifest.Asset?,
    in release: GitHubReleaseManifest,
    replacing application: AppRecord
  ) async -> (
    canInstall: Bool,
    expectedSHA256: String?,
    requiresValidSignature: Bool,
    requiresTeamIdentifier: Bool
  ) {
    guard let package else {
      return (false, nil, false, false)
    }

    let requiresTeamIdentifier =
      ApplicationCodeSigning.teamIdentifier(at: application.applicationURL) != nil
    let expectedSHA256 = await checksum(for: package, in: release)
    return (true, expectedSHA256, true, requiresTeamIdentifier)
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
