import Foundation
import XCTest

@testable import Upkeep

final class HomebrewInstallationSnapshotTests: XCTestCase {
    func testDevelopmentReceiptRecognizesBuildAndAbbreviatedCommitWithoutAnUpdaterFeed() throws {
        let fixture = try makeFixture(
            currentVersion: "d8619f1bc", buildVersion: "18266",
            caskVersion: "18266,d8619f1bce383090260221dab5f62fc953d1280b", hasSparkleFeed: false)
        XCTAssertEqual(fixture.application.updateConfiguration.mechanism, .sparkle)
        let checked = fixture.snapshot.applying(to: fixture.application)

        XCTAssertEqual(checked.installedUpdateConfiguration?.mechanism, .homebrew)
        XCTAssertEqual(checked.updateConfiguration.mechanism, .homebrew)
        XCTAssertEqual(checked.updateConfiguration.identifier, "example")
        XCTAssertEqual(checked.channelTitle, "Homebrew")
        XCTAssertEqual(checked.mechanismTitle, "Homebrew Cask")
        XCTAssertEqual(checked.alternateUpdateConfiguration?.mechanism, .sparkle)
        XCTAssertNil(checked.alternateUpdateConfiguration?.feedURL)
        XCTAssertEqual(checked.currentVersion, "d8619f1bc")
        XCTAssertEqual(checked.buildVersion, "18266")
        XCTAssertEqual(checked.status, .upToDate)
        XCTAssertEqual(checked.lastInstalledAt, fixture.date)
        XCTAssertFalse(checked.needsUpdate)
    }

    func testDevelopmentReceiptRequiresBothMatchingBuildAndMatchingCommit() throws {
        let fixture = try makeFixture(
            currentVersion: "d8619f1bc", buildVersion: "18266",
            caskVersion: "18266,d8619f1bce383090260221dab5f62fc953d1280b", hasSparkleFeed: false)
        for (version, build) in [
            ("abcdef123", "18266"), ("d8619f1bc", "18267"), ("d8619f1bc", nil),
        ] {
            var application = fixture.application
            application.currentVersion = version
            application.buildVersion = build
            let checked = fixture.snapshot.applying(to: application)
            XCTAssertNil(checked.installedUpdateConfiguration)
            XCTAssertEqual(checked.updateConfiguration.mechanism, .sparkle)
            XCTAssertEqual(checked.channelTitle, "Unknown")
        }
    }

    func testVerifiedReceiptProvidesAHomebrewRouteForAnUnrecognizedUpdater() throws {
        let fixture = try makeFixture(hasSparkleFeed: false)
        var application = fixture.application
        application.updateConfiguration = UpdateConfiguration(mechanism: .selfManaged)
        let checked = fixture.snapshot.applying(to: application)

        XCTAssertEqual(checked.updateConfiguration.mechanism, .homebrew)
        XCTAssertEqual(checked.installedUpdateConfiguration?.mechanism, .homebrew)
        XCTAssertEqual(checked.updateConfiguration.identifier, "example")
        XCTAssertNil(checked.alternateUpdateConfiguration)
    }

    func testVerifiedReceiptDoesNotReplaceAnExistingPendingUpdate() throws {
        let fixture = try makeFixture(hasSparkleFeed: false)
        var application = fixture.application
        application.status = .updateAvailable
        application.latestVersion = "3.0"
        application.releaseNotes = "Pending release notes"
        let checked = fixture.snapshot.applying(to: application)

        XCTAssertEqual(checked.installedUpdateConfiguration?.mechanism, .homebrew)
        XCTAssertEqual(checked.updateConfiguration, application.updateConfiguration)
        XCTAssertTrue(checked.needsUpdate)
        XCTAssertEqual(checked.latestVersion, "3.0")
        XCTAssertEqual(checked.releaseNotes, "Pending release notes")
    }

    @MainActor
    func testLocalRefreshKeepsVerifiedBrewRouteAfterDevelopmentVersionChanges() async throws {
        let fixture = try makeFixture(
            currentVersion: "d8619f1bc", buildVersion: "18266",
            caskVersion: "18266,d8619f1bce383090260221dab5f62fc953d1280b", hasSparkleFeed: false)
        var previous = fixture.application
        previous.currentVersion = "73e4ff10f"
        previous.buildVersion = "18250"
        previous.status = .upToDate
        let library = AppLibrary(
            applications: [previous],
            scanner: ReceiptScanner(
                application: fixture.snapshot.applying(to: fixture.application)),
            coordinator: NoRemoteChecks(),
            userDefaults: UserDefaults(suiteName: "UpkeepTests.\(UUID().uuidString)")!,
            libraryStore: .memory())

        await library.refreshInstalledApplications()

        let checked = try XCTUnwrap(library.applications.first)
        XCTAssertEqual(checked.currentVersion, "d8619f1bc")
        XCTAssertEqual(checked.updateConfiguration.mechanism, .homebrew)
        XCTAssertEqual(checked.installedUpdateConfiguration?.mechanism, .homebrew)
        XCTAssertEqual(checked.channelTitle, "Homebrew")
        XCTAssertEqual(checked.status, .upToDate)
        XCTAssertTrue(library.availableUpdates.isEmpty)
    }

    func testMatchingReceiptIdentifiesExternalBrewUpdateWithoutChangingCheckChannel() throws {
        let fixture = try makeFixture()
        var application = fixture.application
        application.latestVersion = "3.0"
        application.status = .updateAvailable
        let checked = fixture.snapshot.applying(to: application)

        XCTAssertEqual(checked.installedUpdateConfiguration?.mechanism, .homebrew)
        XCTAssertEqual(checked.channelTitle, "Website")
        XCTAssertEqual(checked.updateConfiguration.mechanism, .sparkle)
        XCTAssertEqual(checked.homebrewCaskToken, "example")
        XCTAssertEqual(checked.lastInstalledAt, fixture.date)
        XCTAssertTrue(checked.needsUpdate)
        XCTAssertEqual(checked.latestVersion, "3.0")
    }

    func testReceiptForOlderVersionDoesNotClaimNativeUpdate() throws {
        let fixture = try makeFixture()
        var application = fixture.application
        application.currentVersion = "3.0"
        let checked = fixture.snapshot.applying(to: application)

        XCTAssertNil(checked.installedUpdateConfiguration?.mechanism)
        XCTAssertEqual(checked.channelTitle, "Website")
        XCTAssertEqual(checked.homebrewCaskToken, "example")
    }

    func testOldReceiptDoesNotOverrideLaterSuccessfulNativeUpdate() throws {
        let fixture = try makeFixture()
        var application = fixture.application
        application.installedUpdateConfiguration = UpdateConfiguration(mechanism: .sparkle)
        application.lastInstalledAt = fixture.date.addingTimeInterval(60)

        XCTAssertEqual(
            fixture.snapshot.applying(to: application).installedUpdateConfiguration?.mechanism,
            .sparkle)
    }

    func testNewBrewReceiptReplacesPreviouslyRecordedNativeChannel() throws {
        let fixture = try makeFixture()
        var application = fixture.application
        application.installedUpdateConfiguration = UpdateConfiguration(mechanism: .sparkle)
        application.lastInstalledAt = fixture.date.addingTimeInterval(-60)

        XCTAssertEqual(
            fixture.snapshot.applying(to: application).installedUpdateConfiguration?.mechanism,
            .homebrew)
    }

    func testApplicationReplacementAfterReceiptDoesNotClaimBrew() throws {
        let fixture = try makeFixture()
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.date.addingTimeInterval(60)],
            ofItemAtPath: fixture.application.applicationURL.path
        )

        XCTAssertNil(
            fixture.snapshot.applying(to: fixture.application).installedUpdateConfiguration?
                .mechanism)
    }

    func testAppStoreReceiptRemainsAppStore() throws {
        let fixture = try makeFixture()
        var application = fixture.application
        application.updateConfiguration.mechanism = .appStore

        XCTAssertNil(
            fixture.snapshot.applying(to: application).installedUpdateConfiguration?.mechanism)
        XCTAssertEqual(fixture.snapshot.applying(to: application).channelTitle, "App Store")
    }

    @MainActor
    func testLocalRefreshRecordsBrewUpdateWithoutCheckingRemoteSources() async throws {
        let fixture = try makeFixture()
        var old = fixture.application
        old.currentVersion = "1.0"
        old.status = .updateAvailable
        old.latestVersion = "2.0"
        old.installedUpdateConfiguration = UpdateConfiguration(mechanism: .sparkle)
        let library = AppLibrary(
            applications: [old],
            scanner: ReceiptScanner(
                application: fixture.snapshot.applying(to: fixture.application)),
            coordinator: NoRemoteChecks(),
            userDefaults: UserDefaults(suiteName: "UpkeepTests.\(UUID().uuidString)")!,
            libraryStore: .memory()
        )

        await library.refreshInstalledApplications()

        XCTAssertEqual(library.applications.first?.currentVersion, "2.0")
        XCTAssertEqual(library.applications.first?.channelTitle, "Website")
        XCTAssertEqual(
            library.applications.first?.installedUpdateConfiguration?.mechanism, .homebrew)
        XCTAssertTrue(library.availableUpdates.isEmpty)
    }

    private func makeFixture(
        currentVersion: String = "2.0", buildVersion: String? = nil,
        caskVersion: String = "2.0", hasSparkleFeed: Bool = true
    ) throws -> (
        application: AppRecord, snapshot: HomebrewInstallationSnapshot, date: Date
    ) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "UpkeepTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let applicationURL = root.appendingPathComponent("Applications/Example.app")
        let contents = applicationURL.appendingPathComponent("Contents")
        let caskroom = root.appendingPathComponent("Caskroom")
        let cask = caskroom.appendingPathComponent("example")
        try fileManager.createDirectory(at: contents, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: cask.appendingPathComponent(".metadata"), withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: cask.appendingPathComponent(caskVersion), withIntermediateDirectories: true)
        var info: [String: String] = [
            "CFBundleIdentifier": "com.example.receipt", "CFBundleName": "Example",
            "CFBundleShortVersionString": currentVersion, "CFBundlePackageType": "APPL",
        ]
        info["CFBundleVersion"] = buildVersion
        if hasSparkleFeed {
            info["SUFeedURL"] = "https://example.com/appcast.xml"
        } else {
            try fileManager.createDirectory(
                at: contents.appendingPathComponent("Frameworks/Sparkle.framework"),
                withIntermediateDirectories: true)
        }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let date = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970) + 10)
        try JSONSerialization.data(withJSONObject: [
            "time": date.timeIntervalSince1970, "source": ["version": caskVersion],
        ])
        .write(to: cask.appendingPathComponent(".metadata/INSTALL_RECEIPT.json"))
        try fileManager.createSymbolicLink(
            at: cask.appendingPathComponent("\(caskVersion)/Example.app"),
            withDestinationURL: applicationURL
        )
        return (
            try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL)),
            HomebrewInstallationSnapshot(caskroomURLs: [caskroom]), date
        )
    }
}

private struct ReceiptScanner: ApplicationScanning {
    let application: AppRecord
    func scan() async -> [AppRecord] { [application] }
}

private struct NoRemoteChecks: UpdateCoordinating {
    func enrich(_ applications: [AppRecord]) async -> [AppRecord] {
        XCTFail("Local installation refresh must not perform Homebrew update checks")
        return applications
    }
    func check(_ application: AppRecord) async -> AppRecord {
        XCTFail("Local installation refresh must not perform remote update checks")
        return application
    }
    func update(_ application: AppRecord, progress: @escaping @Sendable (UpdateProgress) -> Void)
        async throws
    {
        XCTFail("Local installation refresh must not install applications")
    }
}
