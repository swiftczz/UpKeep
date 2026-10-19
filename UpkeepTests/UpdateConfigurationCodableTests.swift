import Foundation
import XCTest

@testable import Upkeep

final class UpdateConfigurationCodableTests: XCTestCase {
  func testBothLegacyCustomAPINamesRemainReadable() throws {
    for name in ["releaseJSON", "website"] {
      let record = try decodeLegacy([
        "source": name, "sourceURL": "https://example.com/latest.json",
      ])
      XCTAssertEqual(record.updateConfiguration.mechanism, .customAPI)
      XCTAssertEqual(record.updateConfiguration.channel, .website)
    }
  }

  func testLegacyGitHubPrefixBelongsToTheMatchingAlternateConfiguration() throws {
    let record = try decodeLegacy([
      "source": "homebrew", "sourceIdentifier": "example",
      "alternateUpdateSource": "githubReleases",
      "alternateSourceURL": "https://api.github.com/repos/example/app/releases",
      "alternateSourceIdentifier": "example/app", "githubReleaseTagPrefix": "desktop-v",
      "installedSource": "githubReleases",
    ])
    XCTAssertEqual(record.updateConfiguration.channel, .homebrew)
    XCTAssertNil(record.updateConfiguration.githubReleaseTagPrefix)
    XCTAssertEqual(record.alternateUpdateConfiguration?.githubReleaseTagPrefix, "desktop-v")
    XCTAssertEqual(record.installedUpdateConfiguration, record.alternateUpdateConfiguration)
  }

  func testLegacyInstallationWithoutMatchingRouteDoesNotBorrowAnUnrelatedFeed() throws {
    let record = try decodeLegacy([
      "source": "githubReleases", "sourceURL": "https://api.github.com/repos/example/app/releases",
      "installedSource": "sparkle",
    ])
    XCTAssertEqual(record.installedUpdateConfiguration?.mechanism, .sparkle)
    XCTAssertNil(record.installedUpdateConfiguration?.feedURL)
    XCTAssertEqual(record.installedUpdateConfiguration?.channel, .unknown)
  }

  func testNestedConfigurationsRoundTripIndependentlyWithReleaseMetadata() throws {
    var record = try decodeLegacy(["source": "githubReleases"])
    record.updateConfiguration = UpdateConfiguration(
      mechanism: .githubReleases,
      feedURL: URL(string: "https://api.github.com/repos/example/app/releases"),
      identifier: "example/app", githubReleaseTagPrefix: "main-v")
    record.alternateUpdateConfiguration = UpdateConfiguration(
      mechanism: .githubReleases,
      feedURL: URL(string: "https://api.github.com/repos/example/desktop/releases"),
      identifier: "example/desktop", githubReleaseTagPrefix: "desktop-v")
    record.installedUpdateConfiguration = UpdateConfiguration(
      mechanism: .sparkle, feedURL: URL(string: "https://example.com/appcast.xml"))
    record.latestVersion = "2.0"
    record.releaseNotes = "Saved release notes"
    record.lastInstalledAt = Date(timeIntervalSince1970: 100)

    let encoded = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(AppRecord.self, from: encoded)
    XCTAssertEqual(decoded, record)
    XCTAssertEqual(
      decoded.alternateUpdateCheckRecord?.updateConfiguration.githubReleaseTagPrefix, "desktop-v")
    XCTAssertEqual(decoded.updateConfiguration.githubReleaseTagPrefix, "main-v")
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    for key in [
      "source", "sourceURL", "sourceIdentifier", "homepageURL", "githubReleaseTagPrefix",
      "alternateUpdateSource", "alternateSourceURL", "alternateSourceIdentifier",
      "alternateHomepageURL", "installedSource",
    ] {
      XCTAssertNil(json[key], key)
    }
  }

  func testInvalidNewConfigurationDoesNotSilentlyFallBackToLegacyFields() throws {
    XCTAssertThrowsError(
      try decodeLegacy([
        "source": "sparkle", "updateConfiguration": ["mechanism": "unsupported-mechanism"],
      ]))
  }

  func testLegacyCustomAPISourcesDecodeAndWriteNestedConfigurations() throws {
    let legacy = Data(
      #"""
      {
        "name": "Example", "bundleIdentifier": "com.example.app",
        "applicationURL": "file:///Applications/Example.app", "currentVersion": "1.0",
        "source": "releaseJSON", "status": {"upToDate": {}},
        "installedSource": "releaseJSON", "alternateUpdateSource": "releaseJSON",
        "sourceURL": "https://example.com/api/latest",
        "releaseNotes": "Previously fetched notes", "latestVersion": "1.0"
      }
      """#.utf8)
    let application = try JSONDecoder().decode(AppRecord.self, from: legacy)
    XCTAssertEqual(application.updateConfiguration.mechanism, .customAPI)
    XCTAssertEqual(application.installedUpdateConfiguration?.mechanism, .customAPI)
    XCTAssertEqual(application.alternateUpdateConfiguration?.mechanism, .customAPI)
    XCTAssertEqual(application.releaseNotes, "Previously fetched notes")
    XCTAssertEqual(
      application.updateConfiguration.feedURL?.absoluteString, "https://example.com/api/latest")
    XCTAssertEqual(application.latestVersion, "1.0")

    let encoded = try JSONEncoder().encode(application)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    for key in ["source", "sourceURL", "installedSource", "alternateUpdateSource"] {
      XCTAssertNil(json[key], key)
    }
    for key in [
      "updateConfiguration", "installedUpdateConfiguration", "alternateUpdateConfiguration",
    ] {
      let route = try XCTUnwrap(json[key] as? [String: Any])
      XCTAssertEqual(route["mechanism"] as? String, "customAPI", key)
    }
    XCTAssertEqual(try JSONDecoder().decode(AppRecord.self, from: encoded), application)
  }

  func testWebsiteDisplayAndSearchUseTheUserFacingName() {
    let application = AppRecord(
      name: "Example",
      bundleIdentifier: "com.example.app",
      applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
      currentVersion: "1.0",
      updateConfiguration: UpdateConfiguration(
        mechanism: .customAPI, feedURL: URL(string: "https://example.com/api/latest")),
      status: .upToDate
    )
    XCTAssertEqual(application.channelTitle, "Website")
    XCTAssertEqual(application.channelSystemImage, "globe")
    XCTAssertEqual(application.mechanismTitle, "Custom API")
    for query in [
      "Custom API", "Website Updater", "Website Updates", "Website update", "website", "官网更新", "官网",
    ] {
      XCTAssertTrue(application.matchesSearch(query), query)
    }
    XCTAssertFalse(application.matchesSearch("GitHub Releases"))
  }

  func testMechanismDecoderStillRejectsUnknownValues() {
    XCTAssertThrowsError(
      try JSONDecoder().decode(UpdateMechanism.self, from: Data(#""unsupported-source""#.utf8)))
  }

  private func decodeLegacy(_ values: [String: Any]) throws -> AppRecord {
    var record: [String: Any] = [
      "name": "Example", "bundleIdentifier": "com.example.app",
      "applicationURL": "file:///Applications/Example.app", "currentVersion": "1.0",
      "source": "selfManaged", "status": ["upToDate": [String: String]()],
    ]
    record.merge(values) { _, new in new }
    return try JSONDecoder().decode(
      AppRecord.self, from: JSONSerialization.data(withJSONObject: record))
  }
}
