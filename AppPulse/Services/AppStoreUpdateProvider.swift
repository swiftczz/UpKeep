import Foundation

struct AppStoreUpdateProvider: Sendable {
  func check(_ application: AppRecord) async -> AppRecord {
    var application = application

    do {
      let platform = application.appStorePlatform ?? .mac
      let country =
        application.appStoreCountryCode?.lowercased()
        ?? Locale.current.region?.identifier.lowercased()
        ?? "us"
      guard
        let url = Self.lookupURL(
          bundleIdentifier: application.bundleIdentifier,
          storeIdentifier: application.sourceIdentifier,
          country: country,
          platform: platform
        )
      else {
        application.status = .unavailable("无法创建 App Store 查询地址。")
        return application
      }

      var request = URLRequest(url: url)
      request.timeoutInterval = 15
      let (data, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse,
        (200..<300).contains(httpResponse.statusCode)
      else {
        application.status = .unavailable("App Store 暂时无法访问。")
        return application
      }

      let lookup = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)
      guard
        let result = lookup.result(
          matching: application.bundleIdentifier,
          platform: platform
        )
      else {
        application.status = .unavailable("当前商店地区找不到对应的平台版本。")
        return application
      }

      application.appStorePlatform = result.appStorePlatform ?? platform
      application.latestVersion = result.version
      application.releaseNotes = result.releaseNotes?.nilIfBlank
      application.releaseDate = result.releaseDate.flatMap(Self.parseISO8601Date)
      application.sourceURL = result.trackViewURL.flatMap(URL.init(string:))
      application.homepageURL = application.sourceURL
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
    if !platform.usesDesktopStoreLookup, let storeIdentifier, !storeIdentifier.isEmpty {
      queryItems.insert(URLQueryItem(name: "id", value: storeIdentifier), at: 0)
    } else {
      queryItems.insert(URLQueryItem(name: "bundleId", value: bundleIdentifier), at: 0)
    }
    components?.queryItems = queryItems
    return components?.url
  }

  private static func parseISO8601Date(_ value: String) -> Date? {
    ISO8601DateFormatter().date(from: value)
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
  let version: String
  let releaseNotes: String?
  let releaseDate: String?
  let trackViewURL: String?
  let supportedDevices: [String]?

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
    case version
    case releaseNotes
    case releaseDate = "currentVersionReleaseDate"
    case trackViewURL = "trackViewUrl"
    case supportedDevices
  }
}

extension String {
  fileprivate var nilIfBlank: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
