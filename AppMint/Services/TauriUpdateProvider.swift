import Foundation

struct TauriUpdateManifest: Equatable, Sendable {
  struct Platform: Equatable, Sendable {
    let url: URL
    let sha256: String?
    let sha512: String?
  }

  var version: String
  var notes: String?
  var publicationDate: Date?
  var releaseNotesURL: URL?
  var platforms: [String: Platform]

  func selectedPlatform(architecture: MacCPUArchitecture = .current) -> Platform? {
    let preferredKeys: [String]
    switch architecture {
    case .arm64:
      preferredKeys = [
        "darwin-aarch64",
        "darwin-aarch64-app",
        "darwin-arm64",
        "aarch64-apple-darwin",
        "darwin-universal",
        "universal-apple-darwin",
        "darwin-x86_64",
        "darwin-x86_64-app",
        "darwin-amd64",
        "x86_64-apple-darwin",
      ]
    case .x64:
      preferredKeys = [
        "darwin-x86_64",
        "darwin-x86_64-app",
        "darwin-amd64",
        "x86_64-apple-darwin",
        "darwin-universal",
        "universal-apple-darwin",
      ]
    }

    for key in preferredKeys {
      if let platform = platforms[key], Self.isInstallable(platform.url) {
        return platform
      }
    }

    return platforms.first(where: { key, platform in
      key.lowercased().contains("darwin") && Self.isInstallable(platform.url)
    })?.value
  }

  static func parse(_ data: Data) -> TauriUpdateManifest? {
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = (json["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !version.isEmpty,
      let rawPlatforms = json["platforms"] as? [String: Any]
    else {
      return nil
    }

    var platforms: [String: Platform] = [:]
    for (key, value) in rawPlatforms {
      guard
        let dictionary = value as? [String: Any],
        let urlString = dictionary["url"] as? String,
        let url = SecureUpdateURL.https(string: urlString)
      else {
        continue
      }
      platforms[key] = Platform(
        url: url,
        sha256: (dictionary["sha256"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        sha512: (dictionary["sha512"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }

    guard !platforms.isEmpty else {
      return nil
    }

    return TauriUpdateManifest(
      version: version.hasPrefix("v") || version.hasPrefix("V")
        ? String(version.dropFirst())
        : version,
      notes: {
        let notes = (json["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes?.isEmpty == true ? nil : notes
      }(),
      publicationDate: (json["pub_date"] as? String).flatMap(parseDate),
      releaseNotesURL: (json["release_notes_url"] as? String).flatMap(
        SecureUpdateURL.https(string:)
      ),
      platforms: platforms
    )
  }

  private static func isInstallable(_ url: URL) -> Bool {
    ApplicationPackageInstaller.packageKindScore(of: url.lastPathComponent) > 0
  }

  private static func parseDate(_ value: String) -> Date? {
    ISO8601Parsing.date(from: value)
  }
}

struct TauriUpdateProvider: Sendable {
  func check(_ application: AppRecord) async -> AppRecord {
    var application = application

    guard let endpoint = application.sourceURL,
      SecureUpdateURL.https(endpoint) != nil
    else {
      application.status = .selfManaged
      return application
    }

    do {
      let manifest = try await fetchManifest(from: endpoint)
      let releaseNotes: String?
      if let notes = manifest.notes {
        releaseNotes = notes
      } else if let releaseNotesURL = manifest.releaseNotesURL {
        releaseNotes = await TauriReleaseNotes.fetch(from: releaseNotesURL)
      } else {
        releaseNotes = nil
      }
      application.applyRemoteRelease(
        version: manifest.version,
        releaseDate: manifest.publicationDate,
        releaseNotes: releaseNotes,
        releaseNotesURL: manifest.releaseNotesURL,
        canInstall: manifest.selectedPlatform() != nil
      )
    } catch is CancellationError {
      return application
    } catch {
      application.status = .unavailable("Tauri updater 更新源暂时无法访问。")
    }

    return application
  }

  func upgrade(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    guard let endpoint = application.sourceURL,
      SecureUpdateURL.https(endpoint) != nil
    else {
      throw ProcessRunnerError.failed(status: 1, message: "此应用没有安全的 Tauri updater 更新源。")
    }

    progress(.indeterminate("正在检查更新…"))
    let manifest = try await fetchManifest(from: endpoint)
    guard let platform = manifest.selectedPlatform() else {
      throw ProcessRunnerError.failed(status: 1, message: "更新源中没有兼容此 Mac 的安装包。")
    }

    try await ApplicationPackageInstaller.install(
      from: platform.url,
      replacing: application,
      expectedSHA512: platform.sha512,
      expectedSHA256: platform.sha256,
      progress: progress
    )
  }

  private func fetchManifest(from url: URL) async throws -> TauriUpdateManifest {
    guard let data = try await UpdateHTTP.successfulData(from: url) else {
      throw ProcessRunnerError.failed(status: 1, message: "无法读取 Tauri updater 更新清单。")
    }
    if let manifest = TauriUpdateManifest.parse(data) {
      return manifest
    }

    guard
      let catalogURL = TauriUpdateCatalog.parse(data)?.latestManifestURL,
      catalogURL != url,
      let catalogData = try await UpdateHTTP.successfulData(from: catalogURL),
      let manifest = TauriUpdateManifest.parse(catalogData)
    else {
      throw ProcessRunnerError.failed(status: 1, message: "无法读取 Tauri updater 更新清单。")
    }
    return manifest
  }
}

enum TauriReleaseNotes {
  static func fetch(from releaseURL: URL) async -> String? {
    guard let apiURL = githubReleaseAPIURL(from: releaseURL) else {
      return nil
    }

    do {
      guard
        let data = try await UpdateHTTP.successfulData(from: apiURL),
        data.count <= 2_000_000
      else {
        return nil
      }
      return parseGitHubRelease(data)
    } catch {
      return nil
    }
  }

  static func githubReleaseAPIURL(from releaseURL: URL) -> URL? {
    guard releaseURL.host?.lowercased() == "github.com" else {
      return nil
    }

    let components = releaseURL.pathComponents
      .filter { $0 != "/" }
      .map { $0.removingPercentEncoding ?? $0 }
    guard components.count >= 5,
      components[2].lowercased() == "releases",
      components[3].lowercased() == "tag"
    else {
      return nil
    }

    let owner = components[0]
    let repository = components[1]
    let tag = components[4...].joined(separator: "/")
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    guard
      let encodedOwner = owner.addingPercentEncoding(withAllowedCharacters: allowed),
      let encodedRepository = repository.addingPercentEncoding(withAllowedCharacters: allowed),
      let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: allowed),
      let url = URL(
        string:
          "https://api.github.com/repos/\(encodedOwner)/\(encodedRepository)/releases/tags/\(encodedTag)"
      )
    else {
      return nil
    }
    return url
  }

  static func parseGitHubRelease(_ data: Data) -> String? {
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let body = json["body"] as? String
    else {
      return nil
    }
    return body.nonBlankValue
  }
}

struct TauriUpdateCatalog: Equatable, Sendable {
  struct Release: Equatable, Sendable {
    var version: String
    var manifestURL: URL
  }

  var releases: [Release]

  var latestManifestURL: URL? {
    let stable = releases.filter { !VersionComparator.isPrerelease($0.version) }
    let pool = stable.isEmpty ? releases : stable
    return pool.max { lhs, rhs in
      if VersionComparator.isNewer(rhs.version, than: lhs.version) {
        return true
      }
      if VersionComparator.isNewer(lhs.version, than: rhs.version) {
        return false
      }
      return lhs.version < rhs.version
    }?.manifestURL
  }

  static func parse(_ data: Data) -> TauriUpdateCatalog? {
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rawReleases = json["versions"] as? [[String: Any]]
    else {
      return nil
    }

    let releases = rawReleases.compactMap { raw -> Release? in
      let version = (raw["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      let manifest = (raw["manifest"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      guard
        let version, !version.isEmpty,
        let manifest,
        let manifestURL = SecureUpdateURL.https(string: manifest)
      else {
        return nil
      }
      return Release(version: version, manifestURL: manifestURL)
    }

    guard !releases.isEmpty else {
      return nil
    }
    return TauriUpdateCatalog(releases: releases)
  }
}
