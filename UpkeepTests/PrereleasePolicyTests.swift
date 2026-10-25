import Foundation
import XCTest

@testable import Upkeep

final class PrereleasePolicyTests: XCTestCase {
    func testAutomaticFollowsTheInstalledVersionAndTheAppsOwnChannel() {
        var stable = record(version: "1.0", mechanism: .sparkle, feed: "https://example.com/appcast.xml")
        XCTAssertFalse(stable.acceptsPrereleases)
        stable.prereleasePolicy = .includePrereleases
        XCTAssertTrue(stable.acceptsPrereleases)

        var preview = record(
            version: "0.2.1-rc.2", mechanism: .electronBuilder,
            feed: "https://example.com/feeds/latest-mac.yml")
        XCTAssertTrue(preview.acceptsPrereleases)
        preview.prereleasePolicy = .stableOnly
        XCTAssertFalse(preview.acceptsPrereleases)

        let nightly = record(
            version: "1.0", mechanism: .electronBuilder,
            feed: "https://example.com/feeds/nightly-mac.yml")
        XCTAssertTrue(nightly.acceptsPrereleases)
    }

    func testStableOnlyReadsTheLatestChannelBesideAPreviewChannel() {
        var nightly = record(
            version: "0.2.1-rc.2", mechanism: .electronBuilder,
            feed: "https://download.example.com/feeds/mac-arm64/nightly-mac.yml")
        XCTAssertEqual(
            ElectronBuilderUpdateProvider.feedURL(for: nightly)?.lastPathComponent,
            "nightly-mac.yml")
        nightly.prereleasePolicy = .stableOnly
        XCTAssertEqual(
            ElectronBuilderUpdateProvider.feedURL(for: nightly)?.absoluteString,
            "https://download.example.com/feeds/mac-arm64/latest-mac.yml")
    }

    func testSparkleOffersABetaOnlyWhenPreviewsAreAccepted() {
        let stable = SparkleCandidate(
            shortVersion: "2.0", downloadURL: URL(string: "https://example.com/App-2.0.zip"))
        let beta = SparkleCandidate(
            shortVersion: "2.1-beta.1", downloadURL: URL(string: "https://example.com/App.zip"))

        XCTAssertEqual(
            SparkleUpdateProvider.bestCandidate(from: [stable, beta])?.shortVersion, "2.0")
        XCTAssertEqual(
            SparkleUpdateProvider.bestCandidate(from: [stable, beta], includesPrereleases: true)?
                .shortVersion,
            "2.1-beta.1")
    }

    func testTauriCatalogAndGitHubIncludePreviewsOnRequest() throws {
        let catalog = try XCTUnwrap(
            TauriUpdateCatalog.parse(
                Data(
                    #"{"versions":[{"version":"v2.0.0","manifest":"https://example.com/2.0.0.json"},{"version":"v2.1.0-rc.1","manifest":"https://example.com/2.1.0-rc.1.json"}]}"#
                        .utf8)))
        XCTAssertEqual(catalog.latestManifestURL()?.lastPathComponent, "2.0.0.json")
        XCTAssertEqual(
            catalog.latestManifestURL(includesPrereleases: true)?.lastPathComponent,
            "2.1.0-rc.1.json")

        let prerelease = Data(
            #"{"tag_name":"v2.1.0-beta.1","prerelease":true,"assets":[]}"#.utf8)
        XCTAssertNil(GitHubReleaseManifest.parse(prerelease))
        XCTAssertEqual(
            GitHubReleaseManifest.parse(prerelease, includesPrereleases: true)?.version,
            "2.1.0-beta.1")
    }

    private func record(version: String, mechanism: UpdateMechanism, feed: String) -> AppRecord {
        AppRecord(
            name: "Example",
            bundleIdentifier: "com.example.app",
            applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
            currentVersion: version,
            updateConfiguration: UpdateConfiguration(mechanism: mechanism, feedURL: URL(string: feed)),
            status: .upToDate
        )
    }
}
