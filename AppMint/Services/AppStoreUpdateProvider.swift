import Foundation

struct AppStoreUpdateProvider: Sendable {
  func check(_ application: AppRecord) async -> AppRecord {
    var application = application

    do {
      let platform = application.appStorePlatform ?? .mac
      let countries = Self.lookupCountries(for: application)
      guard !countries.isEmpty else {
        application.status = .unavailable("无法创建 App Store 查询地址。")
        return application
      }

      var matched: (country: String, result: AppStoreLookupResult)?
      var sawReachableCatalog = false
      var sawNetworkFailure = false

      for country in countries {
        guard
          let url = Self.lookupURL(
            bundleIdentifier: application.bundleIdentifier,
            storeIdentifier: application.sourceIdentifier,
            country: country,
            platform: platform
          )
        else {
          continue
        }

        guard let data = try await UpdateHTTP.successfulData(from: url) else {
          sawNetworkFailure = true
          continue
        }

        sawReachableCatalog = true
        let lookup = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)
        if let result = lookup.result(
          matching: application.bundleIdentifier,
          platform: platform
        ) {
          matched = (country, result)
          break
        }
      }

      guard var matched else {
        application.status =
          sawReachableCatalog
          ? .unavailable("在 App Store 中找不到对应的平台版本。")
          : .unavailable(
            sawNetworkFailure ? "App Store 暂时无法访问。" : "无法创建 App Store 查询地址。"
          )
        return application
      }

      // Lookup-by-bundleId can lag hours behind the live catalog that App Store
      // itself uses. Once we have an Adam ID, query again by `id`.
      if (application.sourceIdentifier ?? "").isEmpty, let trackID = matched.result.trackID {
        matched.result =
          try await Self.fetchLookupResult(
            bundleIdentifier: application.bundleIdentifier,
            storeIdentifier: String(trackID),
            country: matched.country,
            platform: platform
          ) ?? matched.result
      }

      let result = matched.result
      application.appStoreCountryCode = matched.country
      application.appStorePlatform = result.appStorePlatform ?? platform
      application.latestVersion = result.version
      application.releaseNotes = result.releaseNotes?.nonBlankValue
      application.releaseDate = result.releaseDate.flatMap(ISO8601Parsing.date(from:))
      application.sourceURL = result.trackViewURL.flatMap(URL.init(string:))
      application.homepageURL = application.sourceURL
      application.sourceIdentifier = result.trackID.map(String.init)
      application.packageByteCount = result.packageByteCount
      application.canAutomaticallyUpdate =
        application.appStorePlatform == .mac
        && MacAppStoreUpdateProvider.isAvailable
        && MacAppStoreUpdateProvider.adamIdentifier(for: application) != nil
      application.status =
        VersionComparator.isNewer(result.version, than: application.currentVersion)
        ? .updateAvailable
        : .upToDate
    } catch is CancellationError {
      return application
    } catch {
      application.status = .unavailable("App Store 信息获取失败。")
    }

    return application
  }

  static func lookupCountries(for application: AppRecord) -> [String] {
    var countries: [String] = []
    var seen = Set<String>()

    func add(_ raw: String?) {
      guard let code = normalizedCountryCode(raw), seen.insert(code).inserted else {
        return
      }
      countries.append(code)
    }

    add(application.appStoreCountryCode)
    add(Locale.current.region?.identifier)
    for code in ["us", "cn", "hk", "tw", "mo", "jp", "sg", "gb", "au", "ca", "de", "kr"] {
      add(code)
    }
    return countries
  }

  private static func normalizedCountryCode(_ raw: String?) -> String? {
    guard let raw else { return nil }
    var code = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let separator = code.firstIndex(where: { $0 == "-" || $0 == "_" }) {
      let suffix = String(code[code.index(after: separator)...])
      code = suffix.count == 2 ? suffix : String(code[..<separator])
    }
    guard code.count == 2, code.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) })
    else {
      return nil
    }
    return code
  }

  static func lookupURL(
    bundleIdentifier: String,
    storeIdentifier: String? = nil,
    country: String,
    platform: AppStorePlatform = .mac
  ) -> URL? {
    var components = URLComponents(string: "https://itunes.apple.com/lookup")
    var queryItems = [
      URLQueryItem(name: "media", value: "software"),
      URLQueryItem(
        name: "entity",
        value: platform.usesDesktopStoreLookup ? "desktopSoftware" : "software"
      ),
      URLQueryItem(name: "country", value: country.lowercased()),
    ]
    if let storeIdentifier, !storeIdentifier.isEmpty {
      queryItems.insert(URLQueryItem(name: "id", value: storeIdentifier), at: 0)
    } else {
      queryItems.insert(URLQueryItem(name: "bundleId", value: bundleIdentifier), at: 0)
    }
    components?.queryItems = queryItems
    return components?.url
  }

  private static func fetchLookupResult(
    bundleIdentifier: String,
    storeIdentifier: String,
    country: String,
    platform: AppStorePlatform
  ) async throws -> AppStoreLookupResult? {
    guard
      let url = lookupURL(
        bundleIdentifier: bundleIdentifier,
        storeIdentifier: storeIdentifier,
        country: country,
        platform: platform
      )
    else {
      return nil
    }

    guard let data = try await UpdateHTTP.successfulData(from: url) else {
      return nil
    }

    let lookup = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)
    return lookup.result(matching: bundleIdentifier, platform: platform)
  }
}

struct AppStoreLookupResponse: Decodable, Sendable {
  let results: [AppStoreLookupResult]

  func result(
    matching bundleIdentifier: String,
    platform: AppStorePlatform
  ) -> AppStoreLookupResult? {
    results.first {
      $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        && $0.supports(platform)
    }
  }
}

struct AppStoreLookupResult: Decodable, Sendable {
  let bundleIdentifier: String
  let trackID: UInt64?
  let version: String
  let releaseNotes: String?
  let releaseDate: String?
  let trackViewURL: String?
  let supportedDevices: [String]?
  let packageByteCount: Int64?

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
    trackID = try container.decodeIfPresent(UInt64.self, forKey: .trackID)
    version = try container.decode(String.self, forKey: .version)
    releaseNotes = try container.decodeIfPresent(String.self, forKey: .releaseNotes)
    releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
    trackViewURL = try container.decodeIfPresent(String.self, forKey: .trackViewURL)
    supportedDevices = try container.decodeIfPresent([String].self, forKey: .supportedDevices)
    packageByteCount = JSONByteCount.decode(container, forKey: .fileSizeBytes)
  }

  var supportsMacDesktop: Bool {
    supportedDevices?.contains("MacDesktop-MacDesktop") == true
  }

  var supportsIPhone: Bool {
    supportedDevices?.contains { $0.hasPrefix("iPhone") } == true
  }

  var supportsIPad: Bool {
    supportedDevices?.contains { $0.hasPrefix("iPad") } == true
  }

  var appStorePlatform: AppStorePlatform? {
    if supportsMacDesktop {
      return .mac
    }

    if supportsIPhone {
      return .iPhone
    }
    return supportsIPad ? .iPad : nil
  }

  func supports(_ platform: AppStorePlatform) -> Bool {
    switch platform {
    case .mac:
      // The desktopSoftware lookup occasionally omits supportedDevices entirely.
      // Its exact Bundle ID match is still safe to use unless Apple explicitly
      // identifies the result as belonging to another platform.
      guard let supportedDevices, !supportedDevices.isEmpty else {
        return true
      }
      return supportsMacDesktop
    case .iPhone: return supportsIPhone
    case .iPad: return supportsIPad
    }
  }

  enum CodingKeys: String, CodingKey {
    case bundleIdentifier = "bundleId"
    case trackID = "trackId"
    case version
    case releaseNotes
    case releaseDate = "currentVersionReleaseDate"
    case trackViewURL = "trackViewUrl"
    case supportedDevices
    case fileSizeBytes
  }
}
