import Foundation
import StoreKit

struct AppStoreUpdateProvider: Sendable {
  private let currentStorefrontCountryCode: @Sendable () async -> String?
  private let lookupData: @Sendable (URL) async throws -> Data?

  init(
    currentStorefrontCountryCode: @escaping @Sendable () async -> String? =
      AppStoreStorefront.currentCountryCode,
    lookupData: @escaping @Sendable (URL) async throws -> Data? =
      { try await UpdateHTTP.successfulData(from: $0) }
  ) {
    self.currentStorefrontCountryCode = currentStorefrontCountryCode
    self.lookupData = lookupData
  }

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
        var countryMatches: [AppStoreLookupResult] = []

        for candidate in Self.lookupCandidates(
          storeIdentifier: application.sourceIdentifier,
          platform: platform
        ) {
          guard
            let url = Self.lookupURL(
              bundleIdentifier: application.bundleIdentifier,
              storeIdentifier: candidate.storeIdentifier,
              country: country,
              platform: platform,
              includesEntity: candidate.includesEntity
            )
          else {
            continue
          }

          do {
            guard let data = try await lookupData(url) else {
              sawNetworkFailure = true
              continue
            }

            sawReachableCatalog = true
            let lookup = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)
            if let result = lookup.result(
              matching: application.bundleIdentifier,
              platform: platform,
              includesPlatformEntity: candidate.includesEntity
            ) {
              countryMatches.append(result)
            }
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            sawNetworkFailure = true
            continue
          }
        }

        if let result = Self.newestResult(in: countryMatches) {
          matched = (country, result)
          break
        }
      }

      guard let matched else {
        application.status =
          sawReachableCatalog
          ? .unavailable("在 App Store 中找不到对应的平台版本。")
          : .unavailable(
            sawNetworkFailure ? "App Store 暂时无法访问。" : "无法创建 App Store 查询地址。"
          )
        return application
      }

      let result = matched.result
      application.appStoreAccountCountryCode = AppStoreCountryCode.normalized(
        await currentStorefrontCountryCode()
      )
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
        !application.requiresAppStoreUpdatePageHandoff
        && application.appStorePlatform == .mac
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
      guard let code = AppStoreCountryCode.normalized(raw), seen.insert(code).inserted else {
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

  static func lookupURL(
    bundleIdentifier: String,
    storeIdentifier: String? = nil,
    country: String,
    platform: AppStorePlatform = .mac,
    includesEntity: Bool = true
  ) -> URL? {
    var components = URLComponents(string: "https://itunes.apple.com/lookup")
    var queryItems = [
      URLQueryItem(name: "media", value: "software"),
      URLQueryItem(name: "country", value: country.lowercased()),
    ]
    if includesEntity {
      queryItems.insert(
        URLQueryItem(
          name: "entity",
          value: platform.usesDesktopStoreLookup ? "desktopSoftware" : "software"
        ),
        at: 1
      )
    }
    if let storeIdentifier, !storeIdentifier.isEmpty {
      queryItems.insert(URLQueryItem(name: "id", value: storeIdentifier), at: 0)
    } else {
      queryItems.insert(URLQueryItem(name: "bundleId", value: bundleIdentifier), at: 0)
    }
    components?.queryItems = queryItems
    return components?.url
  }

  static func lookupCandidates(
    storeIdentifier: String?,
    platform: AppStorePlatform
  ) -> [AppStoreLookupCandidate] {
    var candidates: [AppStoreLookupCandidate] = [
      AppStoreLookupCandidate(storeIdentifier: nil, includesEntity: true),
      AppStoreLookupCandidate(storeIdentifier: nil, includesEntity: false),
    ]

    if let storeIdentifier, !storeIdentifier.isEmpty {
      candidates.append(
        AppStoreLookupCandidate(storeIdentifier: storeIdentifier, includesEntity: true)
      )
      candidates.append(
        AppStoreLookupCandidate(storeIdentifier: storeIdentifier, includesEntity: false)
      )
    }

    return platform.usesDesktopStoreLookup
      ? candidates
      : candidates.filter(\.includesEntity)
  }

  static func newestResult(
    in results: [AppStoreLookupResult]
  ) -> AppStoreLookupResult? {
    results.reduce(nil) { newest, candidate in
      guard let newest else { return candidate }
      return VersionComparator.isNewer(candidate.version, than: newest.version)
        ? candidate
        : newest
    }
  }
}

struct AppStoreLookupCandidate: Equatable, Sendable {
  let storeIdentifier: String?
  let includesEntity: Bool
}

enum AppStoreStorefront {
  static func currentCountryCode() async -> String? {
    if #available(macOS 12.0, *),
      let storefront = await Storefront.current
    {
      if let countryCode = AppStoreCountryCode.normalized(storefront.countryCode) {
        return countryCode
      }
      if let countryCode = cachedCountryCode(forStorefrontID: storefront.id) {
        return countryCode
      }
    }

    return cachedCountryCode(forStorefrontID: nil)
  }

  static func cachedCountryCode(forStorefrontID storefrontID: String?) -> String? {
    let cacheURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Caches/com.apple.appstoreagent", isDirectory: true)
      .appendingPathComponent("storefront-to-country-code.plist")

    guard
      let data = try? Data(contentsOf: cacheURL),
      let propertyList = try? PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      )
    else {
      return nil
    }

    return countryCode(fromStorefrontCountryCodeCache: propertyList, storefrontID: storefrontID)
  }

  static func countryCode(
    fromStorefrontCountryCodeCache propertyList: Any,
    storefrontID: String?
  ) -> String? {
    if let array = propertyList as? [Any] {
      guard let storefrontID else {
        return firstCountryCode(in: array)
      }
      return arrayContainsStorefrontID(array, storefrontID)
        ? firstCountryCode(in: array)
        : nil
    }

    if let dictionary = propertyList as? [String: Any] {
      if let storefrontID,
        let value = dictionary[storefrontID] ?? dictionary[normalizedStorefrontID(storefrontID)]
      {
        return AppStoreCountryCode.normalized(value as? String)
      }
      return firstCountryCode(in: Array(dictionary.values))
    }

    return nil
  }

  private static func firstCountryCode(in values: [Any]) -> String? {
    values.lazy.compactMap { AppStoreCountryCode.normalized($0 as? String) }.first
  }

  private static func arrayContainsStorefrontID(_ values: [Any], _ storefrontID: String) -> Bool {
    let normalized = normalizedStorefrontID(storefrontID)
    return values.contains {
      if let string = $0 as? String {
        return normalizedStorefrontID(string) == normalized
      }
      if let number = $0 as? NSNumber {
        return number.stringValue == normalized
      }
      return false
    }
  }

  private static func normalizedStorefrontID(_ storefrontID: String) -> String {
    storefrontID.split(separator: "-").first.map(String.init) ?? storefrontID
  }
}

struct AppStoreLookupResponse: Decodable, Sendable {
  let results: [AppStoreLookupResult]

  func result(
    matching bundleIdentifier: String,
    platform: AppStorePlatform,
    includesPlatformEntity: Bool = true
  ) -> AppStoreLookupResult? {
    AppStoreUpdateProvider.newestResult(in: results.filter {
      $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        && $0.supports(platform, includesPlatformEntity: includesPlatformEntity)
    })
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
  let kind: String?

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
    kind = try container.decodeIfPresent(String.self, forKey: .kind)
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

  func supports(
    _ platform: AppStorePlatform,
    includesPlatformEntity: Bool = true
  ) -> Bool {
    switch platform {
    case .mac:
      if !includesPlatformEntity {
        if kind?.caseInsensitiveCompare("mac-software") == .orderedSame {
          return true
        }
        return supportsMacDesktop && !supportsIPhone && !supportsIPad
      }

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
    case kind
  }
}
