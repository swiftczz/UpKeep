import Foundation
import XCTest

@testable import Upkeep

final class UpdateConfigurationTests: XCTestCase {
    func testAlternateChecksSwitchTheWholeRouteWithoutChangingPrimaryOrInstalledHistory() throws {
        let primary = UpdateConfiguration(
            mechanism: .githubReleases,
            feedURL: URL(string: "https://api.github.com/repos/example/app/releases"),
            identifier: "example/app", githubReleaseTagPrefix: "main-v")
        let alternate = UpdateConfiguration(
            mechanism: .githubReleases,
            feedURL: URL(string: "https://api.github.com/repos/example/desktop/releases"),
            identifier: "example/desktop", githubReleaseTagPrefix: "desktop-v")
        var record = makeRecord(primary)
        record.alternateUpdateConfiguration = alternate
        record.installedUpdateConfiguration = primary
        record.latestVersion = "2.0"
        record.releaseNotes = "Primary release notes"
        record.canAutomaticallyUpdate = true

        let checked = try XCTUnwrap(record.alternateUpdateCheckRecord)
        XCTAssertEqual(checked.updateConfiguration, alternate)
        XCTAssertEqual(checked.installedUpdateConfiguration, primary)
        XCTAssertNil(checked.latestVersion)
        XCTAssertNil(checked.releaseNotes)
        XCTAssertFalse(checked.canAutomaticallyUpdate)
        XCTAssertEqual(record.updateConfiguration, primary)
        XCTAssertEqual(record.alternateUpdateConfiguration, alternate)
    }

    func testRememberingAnAlternateDoesNotOverwritePrimaryTagPrefix() {
        let primary = UpdateConfiguration(
            mechanism: .githubReleases, githubReleaseTagPrefix: "main-v")
        let alternate = UpdateConfiguration(
            mechanism: .githubReleases, githubReleaseTagPrefix: "desktop-v")
        var record = makeRecord(primary)
        record.rememberAlternateUpdateConfiguration(from: makeRecord(alternate))
        XCTAssertEqual(record.updateConfiguration, primary)
        XCTAssertEqual(record.alternateUpdateConfiguration, alternate)
    }

    func testFeedChangesImmediatelyUpdateTheChannelWithoutChangingMechanism() {
        var configuration = UpdateConfiguration(
            mechanism: .tauri,
            feedURL: URL(
                string: "https://github.com/example/app/releases/latest/download/latest.json"))
        XCTAssertEqual(configuration.channel, .github)
        configuration.feedURL = URL(string: "https://example.com/latest.json")
        XCTAssertEqual(configuration.channel, .website)
        configuration.feedURL = nil
        XCTAssertEqual(configuration.channel, .unknown)
        XCTAssertEqual(configuration.mechanism, .tauri)
    }

    private func makeRecord(_ configuration: UpdateConfiguration) -> AppRecord {
        AppRecord(
            name: "Example", bundleIdentifier: "com.example.app",
            applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
            currentVersion: "1.0", updateConfiguration: configuration, status: .upToDate)
    }
}
