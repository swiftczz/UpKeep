import Foundation
import XCTest

@testable import Upkeep

final class AppStoreLookupTests: XCTestCase {
  func testIntegratedAppStoreUpdaterIsAvailable() {
    XCTAssertTrue(MacAppStoreUpdateProvider.isAvailable)
  }

  func testLookupURLRequestsDesktopSoftware() throws {
    let url = try XCTUnwrap(
      AppStoreUpdateProvider.lookupURL(
        bundleIdentifier: "com.baidu.netdisk",
        country: "CN"
      )
    )
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let query = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
      }
    )

    XCTAssertEqual(query["bundleId"], "com.baidu.netdisk")
    XCTAssertEqual(query["media"], "software")
    XCTAssertEqual(query["entity"], "desktopSoftware")
    XCTAssertEqual(query["country"], "cn")
  }

  func testLookupURLCanRequestMacDesktopSoftwareByStoreIdentifier() throws {
    let url = try XCTUnwrap(
      AppStoreUpdateProvider.lookupURL(
        bundleIdentifier: "tech.baye.OpenCat",
        storeIdentifier: "6445999201",
        country: "CN",
        platform: .mac
      )
    )
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let query = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
      }
    )

    XCTAssertEqual(query["id"], "6445999201")
    XCTAssertNil(query["bundleId"])
    XCTAssertEqual(query["entity"], "desktopSoftware")
    XCTAssertEqual(query["country"], "cn")
  }

  func testLookupURLCanOmitEntityForGenericFallback() throws {
    let url = try XCTUnwrap(
      AppStoreUpdateProvider.lookupURL(
        bundleIdentifier: "com.tencent.tenvideo",
        country: "CN",
        platform: .mac,
        includesEntity: false
      )
    )
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let query = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
      }
    )

    XCTAssertEqual(query["bundleId"], "com.tencent.tenvideo")
    XCTAssertEqual(query["media"], "software")
    XCTAssertNil(query["entity"])
    XCTAssertEqual(query["country"], "cn")
  }

  func testMacLookupCandidatesPreferBundleIdentifierBeforeStoreIdentifier() {
    XCTAssertEqual(
      AppStoreUpdateProvider.lookupCandidates(
        storeIdentifier: "1231336508",
        platform: .mac
      ),
      [
        AppStoreLookupCandidate(storeIdentifier: nil, includesEntity: true),
        AppStoreLookupCandidate(storeIdentifier: nil, includesEntity: false),
        AppStoreLookupCandidate(storeIdentifier: "1231336508", includesEntity: true),
        AppStoreLookupCandidate(storeIdentifier: "1231336508", includesEntity: false),
      ]
    )
  }

  func testWrappedAppLookupCandidatesStayPlatformSpecific() {
    XCTAssertEqual(
      AppStoreUpdateProvider.lookupCandidates(
        storeIdentifier: "698570469",
        platform: .iPhone
      ),
      [
        AppStoreLookupCandidate(storeIdentifier: nil, includesEntity: true),
        AppStoreLookupCandidate(storeIdentifier: "698570469", includesEntity: true),
      ]
    )
  }

  func testLookupURLRequestsIPhoneSoftwareByStoreIdentifier() throws {
    let url = try XCTUnwrap(
      AppStoreUpdateProvider.lookupURL(
        bundleIdentifier: "cn.com.langeasy.LangEasyLexis",
        storeIdentifier: "698570469",
        country: "CN",
        platform: .iPhone
      )
    )
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let query = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
      }
    )

    XCTAssertEqual(query["id"], "698570469")
    XCTAssertNil(query["bundleId"])
    XCTAssertEqual(query["media"], "software")
    XCTAssertEqual(query["entity"], "software")
    XCTAssertEqual(query["country"], "cn")
  }

  func testCheckSelectsNewestNativeMacResultAcrossLookupVariants() async throws {
    let provider = AppStoreUpdateProvider(
      currentStorefrontCountryCode: { "CHN" },
      lookupData: { url in
        let entity = Self.queryValue("entity", in: url)
        return Self.lookupResponse(
          bundleIdentifier: "com.rainbow.quill",
          trackID: 6_670_330_650,
          version: entity == "desktopSoftware" ? "2.0.0" : "2.0.1",
          kind: entity == "desktopSoftware" ? "software" : "mac-software",
          supportedDevices: entity == "desktopSoftware" ? ["MacDesktop-MacDesktop"] : nil
        )
      }
    )
    let application = AppRecord(
      name: "Arc PDF",
      bundleIdentifier: "com.rainbow.quill",
      applicationURL: URL(fileURLWithPath: "/Applications/Arc PDF.app"),
      currentVersion: "2.0.0",
      source: .appStore,
      appStorePlatform: .mac,
      appStoreCountryCode: "cn",
      status: .checking,
      sourceIdentifier: "6670330650"
    )

    let checked = await provider.check(application)

    XCTAssertEqual(checked.latestVersion, "2.0.1")
    XCTAssertEqual(checked.status, .updateAvailable)
    XCTAssertEqual(checked.appStorePlatform, .mac)
    XCTAssertEqual(checked.appStoreCountryCode, "cn")
    XCTAssertEqual(checked.appStoreAccountCountryCode, "cn")
  }

  func testCheckRejectsNewerMobileReleaseForNativeMacApplication() async throws {
    let provider = AppStoreUpdateProvider(
      currentStorefrontCountryCode: { "CHN" },
      lookupData: { url in
        let entity = Self.queryValue("entity", in: url)
        return Self.lookupResponse(
          bundleIdentifier: "com.baidu.netdisk",
          trackID: 547_166_701,
          version: entity == "desktopSoftware" ? "8.7.9" : "13.32.2",
          kind: "software",
          supportedDevices: entity == "desktopSoftware"
            ? ["MacDesktop-MacDesktop"]
            : ["MacDesktop-MacDesktop", "iPhone17-iPhone17", "iPadA16-iPadA16"]
        )
      }
    )
    let application = AppRecord(
      name: "百度网盘",
      bundleIdentifier: "com.baidu.netdisk",
      applicationURL: URL(fileURLWithPath: "/Applications/BaiduNetdisk.app"),
      currentVersion: "8.7.9",
      source: .appStore,
      appStorePlatform: .mac,
      appStoreCountryCode: "cn",
      status: .checking,
      sourceIdentifier: "547166701"
    )

    let checked = await provider.check(application)

    XCTAssertEqual(checked.latestVersion, "8.7.9")
    XCTAssertEqual(checked.status, .upToDate)
    XCTAssertEqual(checked.appStorePlatform, .mac)
  }

  func testCheckUsesMobileCatalogForInstalledIPhoneApplication() async throws {
    let provider = AppStoreUpdateProvider(
      currentStorefrontCountryCode: { "USA" },
      lookupData: { url in
        XCTAssertEqual(Self.queryValue("entity", in: url), "software")
        return Self.lookupResponse(
          bundleIdentifier: "com.example.mobile",
          trackID: 123_456,
          version: "2.0",
          kind: "software",
          supportedDevices: ["iPhone17-iPhone17", "iPadA16-iPadA16"]
        )
      }
    )
    let application = AppRecord(
      name: "Mobile App",
      bundleIdentifier: "com.example.mobile",
      applicationURL: URL(fileURLWithPath: "/Applications/Mobile App.app"),
      currentVersion: "1.0",
      source: .appStore,
      appStorePlatform: .iPhone,
      appStoreCountryCode: "us",
      status: .checking,
      sourceIdentifier: "123456"
    )

    let checked = await provider.check(application)

    XCTAssertEqual(checked.latestVersion, "2.0")
    XCTAssertEqual(checked.status, .updateAvailable)
    XCTAssertEqual(checked.appStorePlatform, .iPhone)
    XCTAssertFalse(checked.canAutomaticallyUpdate)
  }

  func testCheckFallsBackToNextStorefrontWhenKnownStorefrontHasNoMatch() async throws {
    let provider = AppStoreUpdateProvider(
      currentStorefrontCountryCode: { "USA" },
      lookupData: { url in
        guard Self.queryValue("country", in: url) == "us" else {
          return Data(#"{"results":[]}"#.utf8)
        }
        return Self.lookupResponse(
          bundleIdentifier: "com.example.mac",
          trackID: 789,
          version: "3.0",
          kind: "mac-software",
          supportedDevices: nil
        )
      }
    )
    let application = AppRecord(
      name: "Example",
      bundleIdentifier: "com.example.mac",
      applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
      currentVersion: "2.0",
      source: .appStore,
      appStorePlatform: .mac,
      appStoreCountryCode: "cn",
      status: .checking
    )

    let checked = await provider.check(application)

    XCTAssertEqual(checked.latestVersion, "3.0")
    XCTAssertEqual(checked.status, .updateAvailable)
    XCTAssertEqual(checked.appStoreCountryCode, "us")
  }

  func testCheckContinuesAfterOneLookupVariantFails() async throws {
    let provider = AppStoreUpdateProvider(
      currentStorefrontCountryCode: { "CHN" },
      lookupData: { url in
        if Self.queryValue("entity", in: url) == "desktopSoftware" {
          throw URLError(.timedOut)
        }
        return Self.lookupResponse(
          bundleIdentifier: "com.rainbow.quill",
          trackID: 6_670_330_650,
          version: "2.0.1",
          kind: "mac-software",
          supportedDevices: nil
        )
      }
    )
    let application = AppRecord(
      name: "Arc PDF",
      bundleIdentifier: "com.rainbow.quill",
      applicationURL: URL(fileURLWithPath: "/Applications/Arc PDF.app"),
      currentVersion: "2.0.0",
      source: .appStore,
      appStorePlatform: .mac,
      appStoreCountryCode: "cn",
      status: .checking,
      sourceIdentifier: "6670330650"
    )

    let checked = await provider.check(application)

    XCTAssertEqual(checked.latestVersion, "2.0.1")
    XCTAssertEqual(checked.status, .updateAvailable)
  }

  func testCheckDistinguishesUnreachableCatalogFromMissingApplication() async {
    let application = AppRecord(
      name: "Example",
      bundleIdentifier: "com.example.missing",
      applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
      currentVersion: "1.0",
      source: .appStore,
      appStorePlatform: .mac,
      appStoreCountryCode: "cn",
      status: .checking
    )
    let unreachable = AppStoreUpdateProvider(
      currentStorefrontCountryCode: { "CHN" },
      lookupData: { _ in nil }
    )
    let missing = AppStoreUpdateProvider(
      currentStorefrontCountryCode: { "CHN" },
      lookupData: { _ in Data(#"{"results":[]}"#.utf8) }
    )

    let unreachableResult = await unreachable.check(application)
    let missingResult = await missing.check(application)

    XCTAssertEqual(unreachableResult.status, .unavailable("App Store 暂时无法访问。"))
    XCTAssertEqual(missingResult.status, .unavailable("在 App Store 中找不到对应的平台版本。"))
  }

  func testSelectsMacReleaseWhenBundleIdentifierIsSharedAcrossPlatforms() throws {
    let data = Data(
      """
      {
        "results": [
          {
            "bundleId": "com.baidu.netdisk",
            "version": "13.32.0",
            "supportedDevices": ["iPhone17-iPhone17", "iPadA16-iPadA16"]
          },
          {
            "bundleId": "com.baidu.netdisk",
            "version": "8.7.0",
            "supportedDevices": ["MacDesktop-MacDesktop"],
            "releaseNotes": "Mac release notes",
            "currentVersionReleaseDate": "2026-08-05T14:34:07Z",
            "trackViewUrl": "https://apps.apple.com/cn/app/id547166701"
          }
        ]
      }
      """.utf8
    )

    let response = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)
    let result = try XCTUnwrap(
      response.result(matching: "com.baidu.netdisk", platform: .mac)
    )

    XCTAssertEqual(result.version, "8.7.0")
    XCTAssertTrue(result.supportsMacDesktop)
  }

  func testSelectsNewestReleaseAcrossInconsistentCatalogResponses() throws {
    let staleResponse = try JSONDecoder().decode(
      AppStoreLookupResponse.self,
      from: Data(
        """
        {
          "results": [
            {
              "bundleId": "com.rainbow.quill",
              "trackId": 6670330650,
              "version": "2.0.0",
              "supportedDevices": ["MacDesktop-MacDesktop"]
            }
          ]
        }
        """.utf8
      )
    )
    let currentResponse = try JSONDecoder().decode(
      AppStoreLookupResponse.self,
      from: Data(
        """
        {
          "results": [
            {
              "bundleId": "com.rainbow.quill",
              "trackId": 6670330650,
              "version": "2.0.1",
              "kind": "mac-software",
              "supportedDevices": ["MacDesktop-MacDesktop"]
            }
          ]
        }
        """.utf8
      )
    )

    let stale = try XCTUnwrap(
      staleResponse.result(matching: "com.rainbow.quill", platform: .mac)
    )
    let current = try XCTUnwrap(
      currentResponse.result(
        matching: "com.rainbow.quill",
        platform: .mac,
        includesPlatformEntity: false
      )
    )

    XCTAssertEqual(
      AppStoreUpdateProvider.newestResult(in: [stale, current])?.version,
      "2.0.1"
    )
  }

  func testGenericLookupRejectsIOSReleaseThatAlsoListsMacDesktop() throws {
    let data = Data(
      """
      {
        "results": [
          {
            "bundleId": "com.baidu.netdisk",
            "trackId": 547166701,
            "version": "13.32.2",
            "kind": "software",
            "supportedDevices": [
              "MacDesktop-MacDesktop",
              "iPhone17-iPhone17",
              "iPadA16-iPadA16"
            ]
          }
        ]
      }
      """.utf8
    )

    let response = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)

    XCTAssertNil(
      response.result(
        matching: "com.baidu.netdisk",
        platform: .mac,
        includesPlatformEntity: false
      )
    )
  }

  func testGenericLookupAcceptsNativeMacReleaseWithoutSupportedDevices() throws {
    let data = Data(
      """
      {
        "results": [
          {
            "bundleId": "com.rainbow.quill",
            "trackId": 6670330650,
            "version": "2.0.1",
            "kind": "mac-software"
          }
        ]
      }
      """.utf8
    )

    let response = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)
    let result = response.result(
      matching: "com.rainbow.quill",
      platform: .mac,
      includesPlatformEntity: false
    )

    XCTAssertEqual(result?.version, "2.0.1")
  }

  func testRejectsIOSOnlyResult() throws {
    let data = Data(
      """
      {
        "results": [
          {
            "bundleId": "com.baidu.netdisk",
            "version": "13.32.0",
            "supportedDevices": ["iPhone17-iPhone17", "iPadA16-iPadA16"]
          }
        ]
      }
      """.utf8
    )

    let response = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)

    XCTAssertNil(response.result(matching: "com.baidu.netdisk", platform: .mac))
  }

  func testSelectsMacReleaseWhenSupportedDevicesIsMissing() throws {
    let data = Data(
      """
      {
        "results": [
          {
            "bundleId": "com.sequel-ace.sequel-ace",
            "trackId": 1518036000,
            "version": "5.4.0",
            "currentVersionReleaseDate": "2026-08-15T16:06:07Z",
            "trackViewUrl": "https://apps.apple.com/cn/app/sequel-ace/id1518036000",
            "fileSizeBytes": "88473600"
          }
        ]
      }
      """.utf8
    )

    let response = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)
    let result = try XCTUnwrap(
      response.result(matching: "com.sequel-ace.sequel-ace", platform: .mac)
    )

    XCTAssertEqual(result.version, "5.4.0")
    XCTAssertEqual(result.trackID, 1_518_036_000)
    XCTAssertEqual(result.packageByteCount, 88_473_600)
    XCTAssertTrue(result.supports(.mac))
  }

  func testExtractsAdamIdentifierFromAppStoreURL() {
    let application = AppRecord(
      name: "Sequel Ace",
      bundleIdentifier: "com.sequel-ace.sequel-ace",
      applicationURL: URL(fileURLWithPath: "/Applications/Sequel Ace.app"),
      currentVersion: "5.3.1",
      source: .appStore,
      appStorePlatform: .mac,
      status: .updateAvailable,
      latestVersion: "5.4.0",
      sourceURL: URL(string: "https://apps.apple.com/cn/app/sequel-ace/id1518036000")
    )

    XCTAssertEqual(MacAppStoreUpdateProvider.adamIdentifier(for: application), 1_518_036_000)
  }

  func testLookupCountriesPutsKnownStorefrontFirstAndDeduplicates() {
    let application = AppRecord(
      name: "Clash",
      bundleIdentifier: "com.hako.network",
      applicationURL: URL(fileURLWithPath: "/Applications/Clash.app"),
      currentVersion: "1.0.4",
      source: .appStore,
      appStorePlatform: .mac,
      appStoreCountryCode: "US",
      status: .checking
    )

    let countries = AppStoreUpdateProvider.lookupCountries(for: application)

    XCTAssertEqual(countries.first, "us")
    XCTAssertTrue(countries.contains("cn"))
    XCTAssertEqual(Set(countries).count, countries.count)
    XCTAssertTrue(countries.allSatisfy { $0.count == 2 })
  }

  func testLookupCountriesNormalizesLocaleStyleCodes() {
    let application = AppRecord(
      name: "Clash",
      bundleIdentifier: "com.hako.network",
      applicationURL: URL(fileURLWithPath: "/Applications/Clash.app"),
      currentVersion: "1.0.4",
      source: .appStore,
      appStorePlatform: .mac,
      appStoreCountryCode: "en_US",
      status: .checking
    )

    XCTAssertEqual(AppStoreUpdateProvider.lookupCountries(for: application).first, "us")
  }

  func testAppStoreCountryMismatchUsesUpdatePageHandoff() {
    let application = AppRecord(
      name: "Clash",
      bundleIdentifier: "com.hako.network",
      applicationURL: URL(fileURLWithPath: "/Applications/Clash.app"),
      currentVersion: "1.0.6",
      source: .appStore,
      appStorePlatform: .mac,
      appStoreCountryCode: "us",
      appStoreAccountCountryCode: "CHN",
      status: .updateAvailable,
      latestVersion: "1.0.7",
      sourceIdentifier: "6794257189"
    )

    XCTAssertTrue(application.requiresAppStoreUpdatePageHandoff)
  }

  func testAppStoreCountryMatchDoesNotUseUpdatePageHandoff() {
    let application = AppRecord(
      name: "Sequel Ace",
      bundleIdentifier: "com.sequel-ace.sequel-ace",
      applicationURL: URL(fileURLWithPath: "/Applications/Sequel Ace.app"),
      currentVersion: "5.3.1",
      source: .appStore,
      appStorePlatform: .mac,
      appStoreCountryCode: "us",
      appStoreAccountCountryCode: "USA",
      status: .updateAvailable,
      latestVersion: "5.4.0",
      sourceIdentifier: "1518036000"
    )

    XCTAssertFalse(application.requiresAppStoreUpdatePageHandoff)
  }

  func testNormalizesStoreKitAlpha3CountryCode() {
    XCTAssertEqual(AppStoreCountryCode.normalized("USA"), "us")
    XCTAssertEqual(AppStoreCountryCode.normalized("CHN"), "cn")
  }

  func testStorefrontCacheReadsArrayCountryCode() {
    XCTAssertEqual(
      AppStoreStorefront.countryCode(
        fromStorefrontCountryCodeCache: [143465, "cn"],
        storefrontID: nil
      ),
      "cn"
    )
  }

  func testStorefrontCacheMatchesStorefrontIDWithoutSuffix() {
    XCTAssertEqual(
      AppStoreStorefront.countryCode(
        fromStorefrontCountryCodeCache: ["143441": "us"],
        storefrontID: "143441-1,29"
      ),
      "us"
    )
  }

  func testSelectsIPhoneReleaseForWrappedApplication() throws {
    let data = Data(
      """
      {
        "results": [
          {
            "bundleId": "cn.com.langeasy.LangEasyLexis",
            "version": "5.11.3",
            "supportedDevices": ["iPhone17-iPhone17", "iPadA16-iPadA16"],
            "trackViewUrl": "https://apps.apple.com/cn/app/id698570469"
          }
        ]
      }
      """.utf8
    )

    let response = try JSONDecoder().decode(AppStoreLookupResponse.self, from: data)
    let result = try XCTUnwrap(
      response.result(
        matching: "cn.com.langeasy.LangEasyLexis",
        platform: .iPhone
      )
    )

    XCTAssertEqual(result.version, "5.11.3")
    XCTAssertEqual(result.appStorePlatform, .iPhone)
  }

  private static func queryValue(_ name: String, in url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first(where: { $0.name == name })?.value
  }

  private static func lookupResponse(
    bundleIdentifier: String,
    trackID: UInt64,
    version: String,
    kind: String,
    supportedDevices: [String]?
  ) -> Data {
    var result: [String: Any] = [
      "bundleId": bundleIdentifier,
      "trackId": trackID,
      "version": version,
      "kind": kind,
      "trackViewUrl": "https://apps.apple.com/app/id\(trackID)",
    ]
    result["supportedDevices"] = supportedDevices
    return try! JSONSerialization.data(withJSONObject: ["results": [result]])
  }
}
