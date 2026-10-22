import XCTest

@testable import Upkeep

@MainActor
final class ReleaseMetadataConsistencyTests: XCTestCase {
    private func app(mechanism: UpdateMechanism = .homebrew, version: String = "1.14.0")
        -> AppRecord
    {
        AppRecord(
            name: "Folo",
            bundleIdentifier: "is.follow",
            applicationURL: URL(fileURLWithPath: "/Applications/Folo.app"),
            currentVersion: "1.14.0",
            updateConfiguration: UpdateConfiguration(mechanism: mechanism),
            status: .updateAvailable,
            latestVersion: version,
            releaseNotes: "Old notes",
            releaseDate: Date(timeIntervalSince1970: 100),
            releaseNotesURL: URL(string: "https://example.com/v1.14.0"),
            packageByteCount: 123
        )
    }

    func testHomebrewDoesNotInheritOlderNotesFromAnySource() {
        let sources: [UpdateMechanism] = [
            .homebrew, .sparkle, .electronBuilder, .tauri,
            .vscodeUpdater, .customAPI, .githubReleases, .appStore, .selfManaged,
        ]
        for mechanism in sources {
            let previous = app(mechanism: mechanism)
            var current = app(version: "1.15.0")
            current.clearReleaseMetadata()
            let result = AppLibrary.mergeKeepingCheckResults([current], previous: [previous])[0]
            XCTAssertEqual(result.latestVersion, "1.15.0")
            XCTAssertNil(result.releaseNotes, "\(mechanism)")
            XCTAssertNil(result.releaseNotesURL)
            XCTAssertNil(result.releaseDate)
            XCTAssertNil(result.packageByteCount)
        }
    }

    // Kero 2.0.8 shipped with build "53"; 2.0.9 uses its version as the build.
    func testRemoteReleaseDropsTheInstalledBuildSoAnUpdatedAppSettles() throws {
        var record = AppRecord(
            name: "Kero",
            bundleIdentifier: "sh.kero",
            applicationURL: URL(fileURLWithPath: "/Applications/Kero.app"),
            currentVersion: "2.0.8",
            buildVersion: "53",
            updateConfiguration: UpdateConfiguration(
                mechanism: .githubReleases,
                feedURL: URL(string: "https://api.github.com/repos/egoist/kero/releases/latest"),
                identifier: "egoist/kero"),
            status: .checking
        )
        record.applyInstalledRelease()
        XCTAssertEqual(record.latestBuildVersion, "53")

        record.applyRemoteRelease(version: "2.0.9", canInstall: true)
        XCTAssertNil(record.latestBuildVersion)
        XCTAssertEqual(record.latestVersionSummary, "2.0.9")
        XCTAssertEqual(record.status, .updateAvailable)

        let installed = AppRecord(
            name: "Kero",
            bundleIdentifier: "sh.kero",
            applicationURL: record.applicationURL,
            currentVersion: "2.0.9",
            buildVersion: "2.0.9",
            updateConfiguration: record.updateConfiguration,
            status: .checking
        )
        let settled = try XCTUnwrap(
            AppLibrary.mergeInstalledApplicationChanges([installed], previous: [record]).first)
        XCTAssertEqual(settled.status, .upToDate)
        XCTAssertFalse(settled.needsUpdate)
        XCTAssertFalse(settled.canAutomaticallyUpdate)
    }

    func testSameVersionDifferentBuildDoesNotReuseMetadata() {
        var previous = app()
        previous.latestBuildVersion = "100"
        var current = app()
        current.latestBuildVersion = "101"
        current.clearReleaseMetadata()
        let result = AppLibrary.mergeKeepingCheckResults([current], previous: [previous])[0]
        XCTAssertNil(result.releaseNotes)
        XCTAssertEqual(result.latestBuildVersion, "101")
    }

    func testRemoteReleaseDoesNotKeepPreviousLink() {
        var application = app()
        application.applyRemoteRelease(
            version: "1.15.0", releaseNotes: "New notes", canInstall: true)
        XCTAssertEqual(application.releaseNotes, "New notes")
        XCTAssertNil(application.releaseNotesURL)
    }

    func testInstalledReleaseDropsNotesForDifferentVersionOrBuild() {
        for mechanism in [UpdateMechanism.vscodeUpdater, .customAPI] {
            var application = app(mechanism: mechanism, version: "1.15.0")
            application.applyInstalledRelease()
            XCTAssertNil(application.releaseNotes)
            XCTAssertNil(application.releaseNotesURL)
            XCTAssertEqual(application.latestVersion, application.currentVersion)
            XCTAssertEqual(application.status, .upToDate)
        }
        var application = app(mechanism: .vscodeUpdater)
        application.buildVersion = "new"
        application.latestBuildVersion = "old"
        application.applyInstalledRelease()
        XCTAssertNil(application.releaseNotes)
    }

    func testAlternateCheckDoesNotCarryUnattributedNotes() throws {
        var original = app()
        original.alternateUpdateConfiguration = UpdateConfiguration(mechanism: .sparkle)
        original.alternateUpdateConfiguration?.feedURL = URL(
            string: "https://example.com/appcast.xml")
        let alternate = try XCTUnwrap(original.alternateUpdateCheckRecord)
        XCTAssertNil(alternate.releaseNotes)
        XCTAssertNil(alternate.releaseNotesURL)
        XCTAssertNil(alternate.releaseDate)
    }

    func testDifferentAlternateVersionDoesNotSupplySizeOrBuild() {
        var original = app(version: "1.15.0")
        original.clearReleaseMetadata()
        var checked = app(mechanism: .tauri)
        checked.latestBuildVersion = "100"
        let result = HomebrewUpdateProvider.mergeAlternateCheckResult(
            checked, intoHomebrew: original)
        XCTAssertNil(result.releaseNotes)
        XCTAssertNil(result.packageByteCount)
        XCTAssertNil(result.latestBuildVersion)
    }
}
