import Foundation
import XCTest

@testable import Upkeep

@MainActor
final class HomebrewMetadataMergeTests: XCTestCase {
    func testEveryNativeMechanismFillsMissingFieldsWithoutChangingHomebrewRoute() throws {
        for mechanism in UpdateMechanism.allCases where mechanism.canBeAlternateUpdateMechanism {
            let homebrew = record(mechanism: .homebrew)
            var native = homebrew
            native.updateConfiguration = UpdateConfiguration(
                mechanism: mechanism, feedURL: URL(string: "https://example.com/feed"),
                homepageURL: URL(string: "https://example.com"))
            native.latestVersion = "1.0"
            native.releaseNotes = "Release notes"
            native.releaseNotesURL = URL(string: "https://example.com/v1.0")
            native.releaseDate = Date(timeIntervalSince1970: 100)
            native.packageByteCount = 123

            let merged = HomebrewUpdateProvider.mergeAlternateCheckResult(
                native, intoHomebrew: homebrew)
            XCTAssertEqual(merged.updateConfiguration.mechanism, .homebrew, mechanism.rawValue)
            XCTAssertEqual(merged.status, .upToDate)
            XCTAssertFalse(merged.canAutomaticallyUpdate)
            XCTAssertEqual(merged.latestVersion, "1.0")
            XCTAssertEqual(
                merged.updateConfiguration.homepageURL, native.updateConfiguration.homepageURL)
            XCTAssertEqual(merged.releaseNotes, native.releaseNotes)
            XCTAssertEqual(merged.releaseNotesURL, native.releaseNotesURL)
            XCTAssertEqual(merged.releaseDate, native.releaseDate)
            XCTAssertEqual(merged.packageByteCount, native.packageByteCount)
        }
    }

    func testFieldMergeKeepsExistingValuesAndFillsBlankNotes() {
        var primary = record()
        primary.latestVersion = "1.0"
        primary.releaseNotes = "Primary notes"
        primary.releaseDate = Date(timeIntervalSince1970: 100)
        primary.packageByteCount = 999
        var secondary = primary
        secondary.releaseNotes = "Secondary notes"
        secondary.releaseNotesURL = URL(string: "https://example.com/notes")
        secondary.releaseDate = Date(timeIntervalSince1970: 200)
        secondary.packageByteCount = 123
        primary.mergeReleaseMetadata(from: secondary)
        XCTAssertEqual(primary.releaseNotes, "Primary notes")
        XCTAssertEqual(primary.releaseDate, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(primary.packageByteCount, 999)
        XCTAssertEqual(primary.releaseNotesURL, secondary.releaseNotesURL)
        primary.releaseNotes = "  \n "
        primary.packageByteCount = 0
        primary.mergeReleaseMetadata(from: secondary)
        XCTAssertEqual(primary.releaseNotes, "Secondary notes")
        XCTAssertEqual(primary.packageByteCount, 123)
    }

    func testPartialChecksKeepSameReleaseFieldsAndCanStillRequestMissingMetadata() throws {
        var previous = record()
        previous.latestVersion = "1.0"
        previous.releaseNotes = "Existing notes"
        previous.updateConfiguration.homepageURL = URL(string: "https://example.com")
        var partial = record()
        partial.latestVersion = "1.0"
        partial.releaseDate = .now
        let merged = AppLibrary.coalesceCheckResult(partial, over: previous)
        XCTAssertEqual(merged.releaseNotes, previous.releaseNotes)
        XCTAssertEqual(merged.releaseDate, partial.releaseDate)
        XCTAssertEqual(
            merged.updateConfiguration.homepageURL, previous.updateConfiguration.homepageURL)
        XCTAssertTrue(merged.hasIncompleteReleaseMetadata)
        var complete = merged
        complete.packageByteCount = 123
        XCTAssertFalse(complete.hasIncompleteReleaseMetadata)
    }

    func testReleaseFieldsDoNotCrossVersionBuildOrApplicationIdentity() {
        let original = record()
        for variant in 0..<3 {
            var secondary = original
            secondary.releaseNotes = "Other release"
            secondary.releaseDate = .now
            secondary.packageByteCount = 100
            if variant == 0 { secondary.latestVersion = "2.0" }
            if variant == 1 { secondary.latestBuildVersion = "other-build" }
            if variant == 2 {
                secondary = AppRecord(
                    name: "Different", bundleIdentifier: "com.example.different",
                    applicationURL: original.applicationURL, currentVersion: "1.0",
                    releaseNotes: "Different app")
            }
            var merged = original
            merged.mergeReleaseMetadata(from: secondary)
            XCTAssertNil(merged.releaseNotes)
            XCTAssertNil(merged.releaseDate)
            XCTAssertNil(merged.packageByteCount)
        }
    }

    func testBrewInstallationKeepsTargetReleaseMetadataAndNewNativeUpdater() throws {
        var previous = record()
        previous.status = .updateAvailable
        previous.latestVersion = "2.0"
        previous.latestBuildVersion = "2"
        previous.releaseNotes = "Version 2 notes"
        previous.releaseDate = Date(timeIntervalSince1970: 100)
        previous.packageByteCount = 123
        previous.updateConfiguration.homepageURL = URL(string: "https://example.com")
        previous.canAutomaticallyUpdate = true
        var disk = record(mechanism: .tauri)
        disk.currentVersion = "2.0"
        disk.buildVersion = "2"
        disk.updateConfiguration.feedURL = URL(string: "https://example.com/new/latest.json")
        disk.status = .checking

        let installed = try XCTUnwrap(
            AppLibrary.mergeInstalledApplicationChanges([disk], previous: [previous]).first)
        XCTAssertEqual(installed.updateConfiguration.mechanism, .homebrew)
        XCTAssertEqual(installed.alternateUpdateConfiguration, disk.updateConfiguration)
        XCTAssertEqual(installed.currentVersion, "2.0")
        XCTAssertEqual(installed.latestVersion, "2.0")
        XCTAssertEqual(installed.status, .upToDate)
        XCTAssertFalse(installed.canAutomaticallyUpdate)
        XCTAssertEqual(installed.releaseNotes, previous.releaseNotes)
        XCTAssertEqual(installed.releaseDate, previous.releaseDate)
        XCTAssertEqual(installed.packageByteCount, previous.packageByteCount)
        XCTAssertEqual(
            installed.updateConfiguration.homepageURL, previous.updateConfiguration.homepageURL)

        var cheapScan = disk
        cheapScan.updateConfiguration = UpdateConfiguration(mechanism: .selfManaged)
        let refreshed = try XCTUnwrap(
            AppLibrary.mergeInstalledApplicationChanges([cheapScan], previous: [installed]).first)
        XCTAssertEqual(refreshed.updateConfiguration.mechanism, .homebrew)
        XCTAssertEqual(
            refreshed.alternateUpdateConfiguration, installed.alternateUpdateConfiguration)
        XCTAssertEqual(refreshed.releaseNotes, previous.releaseNotes)

        disk.currentVersion = "2.1"
        disk.buildVersion = "3"
        let different = try XCTUnwrap(
            AppLibrary.mergeInstalledApplicationChanges([disk], previous: [previous]).first)
        XCTAssertEqual(different.latestVersion, "2.1")
        XCTAssertNil(different.releaseNotes)
        XCTAssertNil(different.releaseDate)
        XCTAssertNil(different.packageByteCount)
    }

    func testHomebrewEnrichmentMergesAlreadyCheckedNativeInformationAndCachesAbsentProtocol() throws
    {
        var native = record(mechanism: .tauri)
        native.latestVersion = "1.0"
        native.releaseNotes = "Same release notes"
        native.releaseDate = .now
        native.packageByteCount = 123
        let snapshot = try snapshot(version: "1.0")
        let result = snapshot.applying(to: native)
        XCTAssertEqual(result.updateConfiguration.mechanism, .homebrew)
        XCTAssertEqual(result.releaseNotes, native.releaseNotes)
        XCTAssertEqual(result.releaseDate, native.releaseDate)
        XCTAssertEqual(result.packageByteCount, native.packageByteCount)
        let unsupported = snapshot.applying(to: record(mechanism: .selfManaged))
        XCTAssertEqual(unsupported.alternateUpdateConfiguration?.mechanism, .selfManaged)
        XCTAssertFalse(unsupported.isCheckable)
        let locallyClaimed = snapshot.applying(to: record(mechanism: .homebrew))
        XCTAssertEqual(locallyClaimed.alternateUpdateConfiguration?.mechanism, .selfManaged)
    }

    func testFullScanRecoversLostNativeRouteAndCachesCompletedDetection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Example.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.example.app", "CFBundleName": "Example",
                "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
                "CFBundlePackageType": "APPL",
            ], format: .xml, options: 0
        ).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("provider: generic\nurl: https://example.com/updates".utf8)
            .write(to: resources.appendingPathComponent("app-update.yml"))
        var cached = try XCTUnwrap(ApplicationScanner.makeRecord(from: app))
        cached.updateConfiguration = UpdateConfiguration(
            mechanism: .homebrew, identifier: "example")
        cached.status = .upToDate
        XCTAssertEqual(
            ApplicationScanner.makeRecord(from: app, sourceDetection: .installedOnly)?.updateConfiguration
                .mechanism,
            .selfManaged)
        let scanned = try XCTUnwrap(ApplicationScanner.makeRecord(from: app, reusing: cached))
        XCTAssertEqual(scanned.updateConfiguration.mechanism, .electronBuilder)
        cached.alternateUpdateConfiguration = UpdateConfiguration(mechanism: .selfManaged)
        XCTAssertEqual(
            ApplicationScanner.makeRecord(from: app, reusing: cached)?.updateConfiguration
                .mechanism,
            .homebrew)
    }

    func testGitHubMetadataIncludesPublicationDateEvenWithoutReleaseBody() throws {
        let data = Data(
            #"{"tag_name":"v1.0","body":"","published_at":"2026-10-19T00:00:00Z","assets":[{"name":"App.dmg","browser_download_url":"https://github.com/example/app/releases/download/v1.0/App.dmg","size":123}]}"#
                .utf8)
        var app = record()
        app.latestVersion = "1.0"
        let result = HomebrewUpdateProvider.applyingGitHubRelease(
            data,
            download: GitHubReleaseDownload(
                owner: "example", repository: "app", tag: "v1.0", fileName: "App.dmg"), to: app)
        XCTAssertNotNil(result.releaseDate)
        XCTAssertEqual(result.packageByteCount, 123)
        XCTAssertNil(result.releaseNotes)
    }

    private func record(mechanism: UpdateMechanism = .homebrew) -> AppRecord {
        AppRecord(
            name: "Example", bundleIdentifier: "com.example.app",
            applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
            currentVersion: "1.0",
            buildVersion: "1",
            updateConfiguration: UpdateConfiguration(mechanism: mechanism, identifier: "example"),
            status: .upToDate)
    }

    private func snapshot(version: String) throws -> HomebrewSnapshot {
        let info = try JSONDecoder().decode(
            BrewInfoResponse.self,
            from: Data(
                """
                {"casks":[{"token":"example","version":"\(version)","artifacts":[{"app":["Example.app"],"target":"/Applications/Example.app"}]}]}
                """.utf8))
        return HomebrewSnapshot(
            info: info, outdated: BrewOutdatedResponse(casks: []), packageApplicationPaths: [:])
    }
}
