import Foundation

struct CustomAPIUpdateManifest: Equatable, Sendable {
  struct Asset: Equatable, Sendable {
    let name: String
    let url: URL
    let sha256: String?
    let sha512: String?
    let size: Int64?
  }

  var version: String
  var notes: String?
  var publicationDate: Date?
  var assets: [Asset]
  var releaseURL: URL? = nil

  func selectedPackage(architecture: MacCPUArchitecture = .current) -> Asset? {
    let ranked = assets.compactMap { asset -> (Int, Asset)? in
      let fileName = asset.name.nonBlankValue ?? asset.url.lastPathComponent
      let kindScore = ApplicationPackageInstaller.packageKindScore(of: fileName)
      guard kindScore > 0 else {
        return nil
      }
      let architectureScore = ApplicationPackageInstaller.architectureScore(
        of: fileName,
        architecture: architecture
      )
      let platformScore = macPlatformScore(of: fileName)
      let tokens = fileName.lowercased().split { !$0.isLetter && !$0.isNumber }
      guard architectureScore > 0, platformScore > 0,
        !tokens.contains(where: {
          ["cli", "server", "web", "chrome", "firefox", "extension", "android", "ios"].contains($0)
        })
      else { return nil }
      return (platformScore * 1_000 + architectureScore * 10 + kindScore, asset)
    }

    return ranked.max(by: { $0.0 < $1.0 })?.1
  }

  static func parse(
    _ data: Data,
    languageCode: String = Locale.current.language.languageCode?.identifier ?? "en",
    sourceURL: URL? = nil
  ) -> CustomAPIUpdateManifest? {
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = normalizedVersion(json["productVersion"] as? String)
        ?? normalizedVersion(json["version"] as? String)
    else {
      return nil
    }

    let rawAssets: [[String: Any]]
    if let array = json["assets"] as? [[String: Any]] {
      rawAssets = array
    } else if let dictionary = json["assets"] as? [String: Any] {
      rawAssets = dictionary.keys.sorted().compactMap { key in
        guard var asset = dictionary[key] as? [String: Any] else { return nil }
        if asset["name"] == nil { asset["name"] = key }
        return asset
      }
    } else if json["assets"] == nil,
      let rawURL = json["url"] as? String,
      let url = SecureUpdateURL.https(string: rawURL),
      ApplicationPackageInstaller.packageKindScore(of: url.lastPathComponent) > 0
    {
      rawAssets = [
        [
          "url": rawURL, "sha256": json["sha256hash"] ?? json["sha256"] ?? "",
          "sha512": json["sha512"] ?? "", "size": json["size"] ?? 0,
        ]
      ]
    } else {
      return nil
    }
    let assets = rawAssets.compactMap { raw -> Asset? in
      let name = (raw["name"] as? String)?.nonBlankValue
      guard
        let rawURL = (raw["url"] as? String)?.nonBlankValue
          ?? (raw["download_url"] as? String)?.nonBlankValue ?? name
      else { return nil }
      var url: URL?
      if rawURL.hasPrefix("/"), !rawURL.hasPrefix("//"), let sourceURL,
        let relative = URL(string: rawURL, relativeTo: sourceURL),
        relative.absoluteURL.host == sourceURL.host,
        var resolved = URLComponents(
          url: relative.absoluteURL,
          resolvingAgainstBaseURL: false)
      {
        // Pin a relative download route to this release when the API supplies a tag.
        if resolved.path.hasPrefix("/api/download/"), let tag = json["tag"] as? String,
          !(resolved.queryItems ?? []).contains(where: { $0.name == "tag" })
        {
          resolved.queryItems =
            (resolved.queryItems ?? []) + [URLQueryItem(name: "tag", value: tag)]
        }
        url = resolved.url.flatMap(SecureUpdateURL.https)
      } else {
        url = SecureUpdateURL.https(string: rawURL)
      }
      guard let url, url.user == nil, url.password == nil else { return nil }
      return Asset(
        name: name ?? url.lastPathComponent, url: url,
        sha256: (raw["sha256"] as? String)?.nonBlankValue,
        sha512: (raw["sha512"] as? String)?.nonBlankValue,
        size: JSONByteCount.parse(raw["size"]))
    }

    guard !assets.isEmpty else {
      return nil
    }

    return CustomAPIUpdateManifest(
      version: version,
      notes: localizedNotes(json, languageCode: languageCode),
      publicationDate: date(from: json["published_at"]) ?? date(from: json["created_at"])
        ?? date(from: json["pub_date"]) ?? date(from: json["published"])
        ?? epochDate(from: json["timestamp"]),
      assets: assets,
      releaseURL: (json["releaseNotesUrl"] as? String ?? json["release_notes_url"] as? String
        ?? json["html_url"] as? String ?? (json["assets"] == nil ? nil : json["url"] as? String))
        .flatMap(SecureUpdateURL.https(string:))
    )
  }

  static func localizedNotes(
    _ json: [String: Any],
    languageCode: String
  ) -> String? {
    if let notes = (json["notes"] as? String)?.nonBlankValue {
      return notes
    }
    if let notes = (json["releaseNotes"] as? String)?.nonBlankValue { return notes }
    if let notes = (json["release_notes"] as? String)?.nonBlankValue {
      return notes
    }
    guard let values = json["release_notes"] as? [String: String] else {
      return nil
    }

    let prefersChinese = languageCode.lowercased().hasPrefix("zh")
    let keys =
      prefersChinese
      ? ["zh-CN", "zh-Hans", "zh", "zh-HK", "zh-Hant", "en"]
      : ["en", "zh-CN", "zh"]
    for key in keys {
      if let notes = values[key]?.nonBlankValue {
        return notes
      }
    }
    return values.values.compactMap(\.nonBlankValue).first
  }

  private static func normalizedVersion(_ value: String?) -> String? {
    guard var version = value?.nonBlankValue else {
      return nil
    }
    if version.hasPrefix("v") || version.hasPrefix("V") {
      version = String(version.dropFirst())
    }
    return version.nonBlankValue
  }

  private static func date(from value: Any?) -> Date? {
    guard let text = value as? String else {
      return nil
    }
    return ISO8601Parsing.date(from: text)
  }

  private static func epochDate(from value: Any?) -> Date? {
    let number = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    guard let number, number.isFinite, number > 0 else { return nil }
    return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
  }

  private func macPlatformScore(of fileName: String) -> Int {
    let name = fileName.lowercased()
    if name.contains("macos") || name.contains("darwin") || name.contains("osx") {
      return 50
    }
    if name.contains("windows") || name.contains("win32") || name.contains("win64")
      || name.contains("linux")
    {
      return 0
    }
    return 10
  }
}

struct CustomAPIUpdateProvider: Sendable {
  var fetchResponse: @Sendable (URL) async throws -> (statusCode: Int, data: Data)? = {
    try await UpdateHTTP.response(from: $0)
  }
  func check(_ application: AppRecord) async -> AppRecord {
    var application = application

    guard let requestURL = Self.feedURL(for: application) else {
      application.status = .selfManaged
      return application
    }

    do {
      switch try await fetchManifest(from: requestURL) {
      case .upToDate:
        application.applyInstalledRelease()
      case .update(let manifest):
        application.updateConfiguration.homepageURL =
          application.updateConfiguration.homepageURL ?? manifest.releaseURL
          ?? URL(string: "/", relativeTo: requestURL)?.absoluteURL
        let package = manifest.selectedPackage()
        application.applyRemoteRelease(
          version: manifest.version,
          releaseDate: manifest.publicationDate,
          releaseNotes: manifest.notes,
          releaseNotesURL: manifest.releaseURL,
          packageByteCount: package?.size,
          canInstall: package != nil && !application.requiresBundleMigration
        )
      case .notThisProtocol:
        application.updateConfiguration.mechanism = .selfManaged
        application.status = .selfManaged
        application.canAutomaticallyUpdate = false
      }
    } catch is CancellationError {
      return application
    } catch {
      application.status = .unavailable("官网更新接口暂时无法访问。")
    }

    return application
  }

  func upgrade(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    guard let requestURL = Self.feedURL(for: application) else {
      throw ProcessRunnerError.failed(status: 1, message: "此应用没有安全的官网更新接口。")
    }

    guard !application.requiresBundleMigration else {
      throw ProcessRunnerError.failed(status: 1, message: "请打开应用，使用应用自身的更新器完成此更新。")
    }

    progress(.indeterminate("正在检查更新…"))
    guard
      case .update(let manifest) = try await fetchManifest(from: requestURL),
      let package = manifest.selectedPackage()
    else {
      throw ProcessRunnerError.failed(status: 1, message: "更新源中没有兼容此 Mac 的安装包。")
    }

    try await ApplicationPackageInstaller.install(
      from: package.url,
      replacing: application,
      expectedSHA512: package.sha512,
      expectedSHA256: package.sha256,
      requiresValidSignature: requestURL.path.hasPrefix("/api/")
        || ElectronCustomAPIUpdateDetector.usesVersionedFeed(application.updateConfiguration),
      requiresTeamIdentifier: ApplicationCodeSigning.teamIdentifier(at: application.applicationURL)
        != nil,
      progress: progress
    )
  }

  private enum FetchResult {
    case upToDate
    case update(CustomAPIUpdateManifest)
    case notThisProtocol
  }

  private static func feedURL(for application: AppRecord) -> URL? {
    ElectronCustomAPIUpdateDetector.currentFeedURL(for: application)
  }

  private func fetchManifest(from url: URL) async throws -> FetchResult {
    var sawNotFound = false
    var sawOtherFailure = false
    var candidates = [url]
    if let stableURL = CustomAPIUpdateDetector.stableChannelURL(from: url) {
      candidates.append(stableURL)
    }

    for candidate in candidates {
      guard let response = try await fetchResponse(candidate) else {
        sawOtherFailure = true
        continue
      }

      if response.statusCode == 204 { return .upToDate }

      if response.statusCode == 200 {
        guard response.data.count <= 5_000_000,
          var manifest = CustomAPIUpdateManifest.parse(response.data, sourceURL: candidate)
        else {
          sawOtherFailure = true
          continue
        }
        if VersionComparator.isPrerelease(manifest.version) {
          return .upToDate
        }
        if manifest.notes == nil, candidate.path == "/api/release" {
          await supplementNotes(in: &manifest, from: candidate)
        }
        try Task.checkCancellation()
        return .update(manifest)
      }

      if response.statusCode == 404 {
        sawNotFound = true
        continue
      }
      sawOtherFailure = true
    }

    if sawNotFound && !sawOtherFailure {
      return .notThisProtocol
    }
    throw ProcessRunnerError.failed(status: 1, message: "无法读取官网更新清单。")
  }

  private func supplementNotes(in manifest: inout CustomAPIUpdateManifest, from url: URL) async {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
    let channel = components.queryItems?.first(where: { $0.name == "channel" })?.value ?? "stable"
    components.path = "/api/changelog"
    components.queryItems = [
      URLQueryItem(name: "per_page", value: "20"),
      URLQueryItem(name: "channel", value: channel),
    ]
    guard let notesURL = components.url,
      let response = try? await fetchResponse(notesURL), response.statusCode == 200,
      response.data.count <= 2_000_000,
      let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
      let releases = json["releases"] as? [[String: Any]],
      let release = releases.first(where: {
        ($0["version"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
          == manifest.version
      }), let body = (release["body"] as? String)?.nonBlankValue
    else { return }
    manifest.notes = body
    components.path = "/changelog"
    components.queryItems = nil
    manifest.releaseURL = components.url
  }

}
