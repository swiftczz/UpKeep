import Foundation
import XCTest

@testable import Upkeep

final class UpdateConfigurationCodableTests: XCTestCase {
    func testNestedConfigurationsRoundTripIndependentlyWithReleaseMetadata() throws {
        var record = AppRecord(
            name: "Example",
            bundleIdentifier: "com.example.app",
            applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
            currentVersion: "1.0",
            updateConfiguration: UpdateConfiguration(mechanism: .selfManaged),
            status: .upToDate
        )
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
            decoded.alternateUpdateCheckRecord?.updateConfiguration.githubReleaseTagPrefix,
            "desktop-v")
        XCTAssertEqual(decoded.updateConfiguration.githubReleaseTagPrefix, "main-v")
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
            "Custom API", "Website Updater", "Website Updates", "Website update", "website", "官网更新",
            "官网",
        ] {
            XCTAssertTrue(application.matchesSearch(query), query)
        }
        XCTAssertFalse(application.matchesSearch("GitHub Releases"))
    }

    func testMechanismDecoderStillRejectsUnknownValues() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                UpdateMechanism.self, from: Data(#""unsupported-source""#.utf8)))
    }
}
