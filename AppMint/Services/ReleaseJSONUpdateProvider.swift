import Foundation

struct ReleaseJSONManifest: Equatable, Sendable {
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
      return (architectureScore * 10 + platformScore + kindScore, asset)
    }

    return ranked.max(by: { $0.0 < $1.0 })?.1
  }

  static func parse(
    _ data: Data,
    languageCode: String = Locale.current.language.languageCode?.identifier ?? "en"
  ) -> ReleaseJSONManifest? {
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = normalizedVersion(json["version"] as? String),
      let rawAssets = json["assets"] as? [[String: Any]]
    else {
      return nil
    }

    let assets = rawAssets.compactMap { raw -> Asset? in
      let name = (raw["name"] as? String)?.nonBlankValue
      guard
        let urlString = (raw["url"] as? String)?.nonBlankValue ?? name,
        let url = SecureUpdateURL.https(string: urlString)
      else {
        return nil
      }
      return Asset(
        name: name ?? url.lastPathComponent,
        url: url,
        sha256: (raw["sha256"] as? String)?.nonBlankValue,
        sha512: (raw["sha512"] as? String)?.nonBlankValue,
        size: JSONByteCount.parse(raw["size"])
      )
    }

    guard !assets.isEmpty else {
      return nil
    }

    return ReleaseJSONManifest(
      version: version,
      notes: localizedNotes(json, languageCode: languageCode),
      publicationDate: date(from: json["published_at"]) ?? date(from: json["created_at"])
        ?? date(from: json["pub_date"]),
      assets: assets
    )
  }

  static func localizedNotes(
    _ json: [String: Any],
    languageCode: String
  ) -> String? {
    if let notes = (json["notes"] as? String)?.nonBlankValue {
      return notes
    }
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

  private func macPlatformScore(of fileName: String) -> Int {
    let name = fileName.lowercased()
    if name.contains("macos") || name.contains("darwin") || name.contains("osx") {
      return 50
    }
    if name.contains("windows") || name.contains("win32") || name.contains("linux") {
      return 0
    }
    return 10
  }
}

struct ReleaseJSONUpdateProvider: Sendable {
  func check(_ application: AppRecord) async -> AppRecord {
    var application = application

    guard let requestURL = Self.feedURL(for: application) else {
      application.status = .selfManaged
      return application
    }

    do {
      switch try await fetchManifest(from: requestURL) {
      case .upToDate:
        application.latestVersion = application.currentVersion
        application.status = .upToDate
        application.canAutomaticallyUpdate = false
      case .update(let manifest):
        let package = manifest.selectedPackage()
        application.applyRemoteRelease(
          version: manifest.version,
          releaseDate: manifest.publicationDate,
          releaseNotes: manifest.notes,
          packageByteCount: package?.size,
          canInstall: package != nil
        )
      case .notThisProtocol:
        application.source = .selfManaged
        application.status = .selfManaged
        application.canAutomaticallyUpdate = false
      }
    } catch is CancellationError {
      return application
    } catch {
      application.status = .unavailable("JSON release 更新源暂时无法访问。")
    }

    return application
  }

  func upgrade(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    guard let requestURL = Self.feedURL(for: application) else {
      throw ProcessRunnerError.failed(status: 1, message: "此应用没有安全的 JSON release 更新源。")
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
      progress: progress
    )
  }

  private enum FetchResult {
    case upToDate
    case update(ReleaseJSONManifest)
    case notThisProtocol
  }

  private static func feedURL(for application: AppRecord) -> URL? {
    application.sourceURL.flatMap(SecureUpdateURL.https)
  }

  private func fetchManifest(from url: URL) async throws -> FetchResult {
    var sawNotFound = false
    var sawOtherFailure = false
    var candidates = [url]
    if let stableURL = ReleaseJSONDetector.stableChannelURL(from: url) {
      candidates.append(stableURL)
    }

    for candidate in candidates {
      guard let response = try await UpdateHTTP.response(from: candidate) else {
        sawOtherFailure = true
        continue
      }

      if response.statusCode == 200 {
        guard let manifest = ReleaseJSONManifest.parse(response.data) else {
          sawOtherFailure = true
          continue
        }
        if VersionComparator.isPrerelease(manifest.version) {
          return .upToDate
        }
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
    throw ProcessRunnerError.failed(status: 1, message: "无法读取 JSON release 更新清单。")
  }
}
