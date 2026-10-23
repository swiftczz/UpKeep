import Foundation
import XCTest

@testable import Upkeep

final class UpdateConfigurationPresentationTests: XCTestCase {
    func testWebsiteFeedKeepsItsChannelWhenPackagesAndHomepageUseGitHub() {
        var application = makeApplication(.customAPI, feed: "https://example.com/api/latest")
        application.updateConfiguration.homepageURL = URL(string: "https://github.com/example/app")
        application.updatePageURL = URL(
            string: "https://github.com/example/app/releases/download/v2/app.dmg")

        XCTAssertEqual(application.channelTitle, "Website")
        XCTAssertEqual(application.mechanismTitle, "Custom API")
        XCTAssertTrue(application.matchesSearch("Website"))
        XCTAssertTrue(application.matchesSearch("Custom API"))
        XCTAssertFalse(application.matchesSearch("GitHub"))
    }

    func testGitHubHostedManifestsKeepTheirOwnMechanism() {
        let cases: [(UpdateMechanism, String, String)] = [
            (.sparkle, "https://raw.githubusercontent.com/example/app/main/appcast.xml", "Sparkle"),
            (
                .electronBuilder,
                "https://github.com/example/app/releases/latest/download/latest-mac.yml",
                "Electron Updater"
            ),
            (
                .tauri, "https://github.com/example/app/releases/latest/download/latest.json",
                "Tauri Updater"
            ),
            (.customAPI, "https://api.github.com/repos/example/app/releases/latest", "Custom API"),
        ]
        for (mechanism, feed, expectedTitle) in cases {
            let application = makeApplication(mechanism, feed: feed)
            XCTAssertEqual(application.channelTitle, "GitHub")
            XCTAssertEqual(application.mechanismTitle, expectedTitle)
            XCTAssertTrue(application.matchesSearch("GitHub"))
            XCTAssertTrue(application.matchesSearch(expectedTitle))
        }
    }

    func testPendingUpdateShowsItsRouteAndInstalledCopyShowsHowItWasInstalled() {
        var application = makeApplication(
            .vscodeUpdater, feed: "https://update.code.visualstudio.com")
        application.installedUpdateConfiguration = UpdateConfiguration(mechanism: .homebrew)
        application.latestVersion = "2.0"
        for status in [UpdateStatus.updateAvailable, .checking, .unavailable("Offline")] {
            application.status = status
            XCTAssertTrue(application.needsUpdate)
            XCTAssertEqual(application.channelTitle, "Website")
            XCTAssertEqual(application.mechanismTitle, "VS Code Updater")
        }

        application.status = .upToDate
        XCTAssertEqual(application.channelTitle, "Homebrew")
        XCTAssertEqual(application.mechanismTitle, UpdateMechanism.homebrew.title)
        XCTAssertEqual(application.installedUpdateConfiguration?.mechanism, .homebrew)
    }

    func testRecognizingAFrameworkWithoutAFeedDoesNotInventAChannel() {
        let application = makeApplication(.sparkle)
        XCTAssertEqual(application.channelTitle, "Unknown")
        XCTAssertEqual(application.mechanismTitle, "Sparkle")
    }

    func testGitHubLookalikeHostIsNotClassifiedAsGitHub() {
        let application = makeApplication(
            .tauri, feed: "https://github.com.example.com/latest.json")
        XCTAssertEqual(application.channelTitle, "Website")
        XCTAssertFalse(application.matchesSearch("GitHub"))
    }

    func testStorePackageManagerAndUnknownNames() {
        for (mechanism, channel, expectedTitle) in [
            (UpdateMechanism.appStore, "App Store", "App Store"),
            (.homebrew, "Homebrew", "Homebrew Cask"),
            (.githubReleases, "GitHub", "GitHub Releases"),
            (.selfManaged, "Unknown", "Unknown"),
        ] {
            let application = makeApplication(mechanism)
            XCTAssertEqual(application.channelTitle, channel)
            XCTAssertEqual(application.mechanismTitle, expectedTitle)
        }
    }

    private func makeApplication(_ mechanism: UpdateMechanism, feed: String? = nil) -> AppRecord {
        AppRecord(
            name: "Example",
            bundleIdentifier: "com.example.app",
            applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
            currentVersion: "1.0",
            updateConfiguration: UpdateConfiguration(
                mechanism: mechanism, feedURL: feed.flatMap(URL.init(string:))),
            status: .upToDate
        )
    }
}
