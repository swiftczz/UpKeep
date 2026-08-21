import Foundation
import XCTest

@testable import AppPulse

final class AppStoreLookupTests: XCTestCase {
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
}
