import Foundation
import XCTest

@testable import Upkeep

final class AppRecordSearchTests: XCTestCase {
    func testMatchesApplicationNameAndBundleIdentifier() {
        let application = makeApplication(name: "Example", bundleIdentifier: "com.acme.desktop")

        XCTAssertTrue(application.matchesSearch("example"))
        XCTAssertTrue(application.matchesSearch("ACME.DESKTOP"))
    }

    func testMatchesUpdateSourceCaseInsensitively() {
        let homebrew = makeApplication(mechanism: .homebrew)
        let sparkle = makeApplication(mechanism: .sparkle)

        XCTAssertTrue(homebrew.matchesSearch("HoMeBrEw"))
        XCTAssertTrue(sparkle.matchesSearch("SPARKLE"))
        let electron = makeApplication(mechanism: .electronBuilder)
        XCTAssertTrue(electron.matchesSearch("Electron Updater"))
        XCTAssertTrue(electron.matchesSearch("electron-updater"))
    }

    func testExplicitSourceQueryDoesNotMatchAnotherSourcesBundleIdentifier() {
        let ollama = makeApplication(
            name: "Ollama",
            bundleIdentifier: "com.electron.ollama",
            mechanism: .homebrew
        )
        let electronApplication = makeApplication(
            name: "Electron Application",
            bundleIdentifier: "com.example.desktop",
            mechanism: .electronBuilder
        )

        XCTAssertFalse(ollama.matchesSearch("electron"))
        XCTAssertTrue(electronApplication.matchesSearch("electron"))
        XCTAssertFalse(ollama.matchesSearch("elect"))
        XCTAssertTrue(electronApplication.matchesSearch("elect"))
    }

    func testOrdinaryQueryStillMatchesBundleIdentifier() {
        let application = makeApplication(bundleIdentifier: "com.example.special-channel")

        XCTAssertTrue(application.matchesSearch("special"))
    }

    func testMatchesPlatformSpecificAppStoreTitle() {
        let application = makeApplication(mechanism: .appStore, appStorePlatform: .mac)

        XCTAssertTrue(application.matchesSearch("mac app store"))
    }

    func testMatchesLocalizedUnknownSourceAndTrimsWhitespace() {
        let application = makeApplication(mechanism: .selfManaged)

        XCTAssertTrue(application.matchesSearch("  未知  "))
    }

    func testUnknownSearchDoesNotMatchAnUnresolvedBackupChannel() {
        for mechanism in UpdateMechanism.allCases where mechanism != .selfManaged {
            var application = makeApplication(
                name: "Unknown Tool", bundleIdentifier: "com.example.unknown", mechanism: mechanism)
            application.alternateUpdateConfiguration = UpdateConfiguration(mechanism: .sparkle)
            application.alternateUpdateConfiguration?.feedURL = nil
            for query in ["未知", "unknown", "unknow", "  UNKNOWN  "] {
                XCTAssertFalse(application.matchesSearch(query), "\(mechanism): \(query)")
            }
        }
    }

    func testUnknownSearchMatchesCurrentUnknownChannelWithKnownMechanism() {
        var application = makeApplication(mechanism: .sparkle)
        application.updateConfiguration.feedURL = nil
        application.installedUpdateConfiguration = UpdateConfiguration(mechanism: .homebrew)
        application.alternateUpdateConfiguration = UpdateConfiguration(mechanism: .githubReleases)
        for query in ["未知", "unknown", "unknow", "  UNKNOWN  "] {
            XCTAssertTrue(application.matchesSearch(query), query)
        }
        XCTAssertTrue(application.matchesSearch("Sparkle"))
        XCTAssertFalse(application.matchesSearch("Homebrew"))
        XCTAssertFalse(application.matchesSearch("GitHub"))
        XCTAssertFalse(application.matchesSearch("GitHub Releases"))
    }

    func testMechanismSearchOnlyMatchesTheActiveUpdater() {
        var application = makeApplication(mechanism: .homebrew)
        application.alternateUpdateConfiguration = UpdateConfiguration(mechanism: .electronBuilder)
        application.alternateUpdateConfiguration?.feedURL = URL(
            string: "https://github.com/example/app/latest-mac.yml")
        XCTAssertTrue(application.matchesSearch("Homebrew Cask"))
        XCTAssertFalse(application.matchesSearch("Electron Updater"))
        XCTAssertFalse(application.matchesSearch("electron-updater"))
        XCTAssertFalse(application.matchesSearch("GitHub"))
    }

    func testWebsiteAndGitHubSearchFollowFeedHostingRatherThanProtocolAliases() {
        var application = makeApplication(mechanism: .customAPI)
        application.updateConfiguration.feedURL = URL(
            string: "https://github.com/example/app/releases/latest/download/latest.json")
        for query in ["Website", "官网", "官网更新"] {
            XCTAssertFalse(application.matchesSearch(query), query)
        }
        XCTAssertTrue(application.matchesSearch("GitHub"))
        XCTAssertTrue(application.matchesSearch("Custom API"))
        XCTAssertFalse(application.matchesSearch("GitHub Releases"))
    }

    func testRejectsUnrelatedSearchText() {
        let application = makeApplication(mechanism: .homebrew)

        XCTAssertFalse(application.matchesSearch("Sparkle"))
    }

    func testInstallationHistoryDoesNotChangeTheDisplayedUpdateSource() {
        var application = makeApplication(mechanism: .sparkle)
        application.installedUpdateConfiguration = UpdateConfiguration(mechanism: .homebrew)

        XCTAssertEqual(application.channelTitle, "Website")
        XCTAssertEqual(application.channelSystemImage, UpdateChannel.website.systemImage)
        XCTAssertFalse(application.matchesSearch("homebrew"))
    }

    func testAvailableUpdateDisplaysTheCurrentChannelInsteadOfTheInstalledChannel() {
        for mechanism in UpdateMechanism.allCases where mechanism != .selfManaged {
            var application = makeApplication(mechanism: mechanism)
            application.installedUpdateConfiguration = UpdateConfiguration(
                mechanism: mechanism == .homebrew ? .sparkle : .homebrew)
            application.status = .updateAvailable
            application.latestVersion = "2.0"

            XCTAssertEqual(application.updateConfiguration.mechanism, mechanism)
            XCTAssertEqual(application.channelTitle, application.updateConfiguration.channel.title)
            XCTAssertEqual(
                application.channelSystemImage, application.updateConfiguration.channel.systemImage)
        }
    }

    func testKnownUpdateKeepsItsActualChannelWhileCheckingOrAfterATemporaryFailure() {
        var application = makeApplication(mechanism: .sparkle)
        application.installedUpdateConfiguration = UpdateConfiguration(mechanism: .homebrew)
        application.latestVersion = "2.0"
        for status in [UpdateStatus.checking, .unavailable("暂时无法访问更新源")] {
            application.status = status

            XCTAssertTrue(application.needsUpdate)
            XCTAssertEqual(application.channelTitle, "Website")
            XCTAssertEqual(application.channelSystemImage, UpdateChannel.website.systemImage)
        }
    }

    func testSourceSearchMatchesTheDisplayedAvailableUpdateChannel() {
        var application = makeApplication(mechanism: .sparkle)
        application.installedUpdateConfiguration = UpdateConfiguration(mechanism: .homebrew)
        application.status = .updateAvailable
        application.latestVersion = "2.0"

        XCTAssertTrue(application.matchesSearch("Sparkle"))
        XCTAssertFalse(application.matchesSearch("Homebrew"))
        application.applyInstalledRelease()
        XCTAssertEqual(application.channelTitle, "Website")
        XCTAssertFalse(application.matchesSearch("Homebrew"))
    }

    func testRecordWithoutInstalledRouteDoesNotInferChannelFromInstallationDate() throws {
        var application = makeApplication(mechanism: .sparkle)
        application.lastInstalledAt = .now
        let restored = try JSONDecoder().decode(
            AppRecord.self, from: JSONEncoder().encode(application)
        )

        XCTAssertNil(restored.installedUpdateConfiguration?.mechanism)
        XCTAssertEqual(restored.channelTitle, "Website")
    }

    private func makeApplication(
        name: String = "Example",
        bundleIdentifier: String = "com.example.app",
        mechanism: UpdateMechanism = .selfManaged,
        appStorePlatform: AppStorePlatform? = nil
    ) -> AppRecord {
        AppRecord(
            name: name,
            bundleIdentifier: bundleIdentifier,
            applicationURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            currentVersion: "1.0",
            updateConfiguration: UpdateConfiguration(
                mechanism: mechanism, feedURL: URL(string: "https://example.com/updates")),
            appStorePlatform: appStorePlatform,
            status: .upToDate
        )
    }
}
