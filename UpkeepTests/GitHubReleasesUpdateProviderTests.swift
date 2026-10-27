import Foundation
import XCTest

@testable import Upkeep

final class GitHubReleasesUpdateProviderTests: XCTestCase {
    func testDetectsLatestReleaseWebAndAPIURLs() throws {
        let web = try XCTUnwrap(
            GitHubReleasesDetector.metadata(
                in: "https://github.com/l0ng-ai/tty7/releases/latest"
            )
        )
        let api = try XCTUnwrap(
            GitHubReleasesDetector.metadata(
                in: "https://api.github.com/repos/l0ng-ai/tty7/releases/latest"
            )
        )

        XCTAssertEqual(web, api)
        XCTAssertEqual(web.identifier, "l0ng-ai/tty7")
        XCTAssertEqual(
            web.apiURL.absoluteString,
            "https://api.github.com/repos/l0ng-ai/tty7/releases/latest"
        )
        let releasesList = try XCTUnwrap(
            GitHubReleasesDetector.metadata(
                in: "https://api.github.com/repos/wanghongenpin/proxypin/releases"
            )
        )
        XCTAssertEqual(releasesList.identifier, "wanghongenpin/proxypin")
        XCTAssertEqual(
            releasesList.apiURL.absoluteString,
            "https://api.github.com/repos/wanghongenpin/proxypin/releases/latest"
        )
        XCTAssertNil(
            GitHubReleasesDetector.metadata(
                in: "https://github.com/l0ng-ai/tty7/releases/tag/nightly"
            )
        )
        XCTAssertTrue(
            GitHubReleasesDetector.matchesApplication(
                web,
                name: "TTY7",
                bundleIdentifier: "com.github.tty7"
            )
        )
        XCTAssertFalse(
            GitHubReleasesDetector.matchesApplication(
                web,
                name: "Another Terminal",
                bundleIdentifier: "com.example.terminal"
            )
        )
    }

    func testFeedbackRepositoryMatchesApplicationWithoutMatchingOtherApps() throws {
        let metadata = try XCTUnwrap(
            GitHubReleasesDetector.metadata(
                in:
                    "https://github.com/egoist/pulse-feedback/releases/latest/download/update-darwin-arm64.json"
            ))
        XCTAssertEqual(metadata.identifier, "egoist/pulse-feedback")
        XCTAssertTrue(
            GitHubReleasesDetector.matchesApplication(
                metadata,
                name: "Pulse", bundleIdentifier: "com.egoist.pulse"))
        XCTAssertFalse(
            GitHubReleasesDetector.matchesApplication(
                metadata,
                name: "Lorca", bundleIdentifier: "app.lorca"))

        let dependency = try XCTUnwrap(
            GitHubReleasesDetector.metadata(
                in:
                    "https://github.com/example/other-feedback/releases/latest"))
        XCTAssertFalse(
            GitHubReleasesDetector.matchesApplication(
                dependency,
                name: "Pulse", bundleIdentifier: "com.egoist.pulse"))
        let notASuffix = try XCTUnwrap(
            GitHubReleasesDetector.metadata(
                in:
                    "https://github.com/example/pulsefeedback/releases/latest"))
        XCTAssertFalse(
            GitHubReleasesDetector.matchesApplication(
                notASuffix,
                name: "Pulse", bundleIdentifier: "com.egoist.pulse"))
    }

    func testOwnersProductRepositoryMatchesWithoutMatchingDependencies() throws {
        func matches(_ url: String, name: String, bundleIdentifier: String) throws -> Bool {
            let metadata = try XCTUnwrap(GitHubReleasesDetector.metadata(in: url))
            return GitHubReleasesDetector.matchesApplication(
                metadata, name: name, bundleIdentifier: bundleIdentifier)
        }
        // MyGo 云音乐 ships from the owner's repository named after its product.
        let mygo =
            "https://github.com/egoist/mygo-cloudmusic/releases/latest/download/update-darwin-arm64.json"
        XCTAssertTrue(try matches(mygo, name: "MyGo 云音乐", bundleIdentifier: "dev.egoist.cloudmusic"))

        // Another developer's repository, even with the product in its name.
        XCTAssertFalse(
            try matches(
                "https://github.com/someone/cloudmusic-api/releases/latest",
                name: "MyGo 云音乐", bundleIdentifier: "dev.egoist.cloudmusic"))
        // The owner's unrelated repository.
        XCTAssertFalse(
            try matches(
                "https://github.com/egoist/devtools/releases/latest",
                name: "MyGo 云音乐", bundleIdentifier: "dev.egoist.cloudmusic"))
        // Short or generic bundle parts do not count as the product.
        XCTAssertFalse(
            try matches(
                "https://github.com/acme/desktop-kit/releases/latest",
                name: "Acme", bundleIdentifier: "com.acme.desktop"))
        XCTAssertFalse(
            try matches(
                "https://github.com/acme/toolapp/releases/latest",
                name: "Acme", bundleIdentifier: "com.acme.app"))
    }

    func testPulseReleaseSelectsFullMacApplicationInsteadOfManifestOrDelta() async throws {
        let dmg = "Pulse.0.1.28.arm64.dmg"
        let data = releaseData(
            tag: "v0.1.28",
            assets: [
                "pulse-0.1.28-linux-arm64.tar.gz", "pulse-0.1.28-windows-arm64.tar.gz",
                "pulse-0.1.28-darwin-arm64.tar.gz", "pulse-0.1.27-to-0.1.28-darwin-arm64.delta",
                "update-darwin-arm64.json", dmg,
            ])
        let release = try XCTUnwrap(GitHubReleaseManifest.parse(data))
        XCTAssertEqual(release.selectedPackage(architecture: .arm64)?.name, dmg)
        XCTAssertNil(release.selectedPackage(architecture: .x64))

        let apiURL = try XCTUnwrap(
            URL(string: "https://api.github.com/repos/egoist/pulse-feedback/releases/latest"))
        let application = AppRecord(
            name: "Pulse",
            bundleIdentifier: "com.egoist.pulse",
            applicationURL: URL(fileURLWithPath: "/Applications/Pulse.app"),
            currentVersion: "0.1.12",
            updateConfiguration: UpdateConfiguration(mechanism: .githubReleases, feedURL: apiURL),
            status: .checking
        )
        let provider = GitHubReleasesUpdateProvider(fetchResponse: { url in
            XCTAssertEqual(url, apiURL)
            return (200, data)
        })
        let checked = await provider.check(application)
        XCTAssertEqual(checked.updateConfiguration.mechanism, .githubReleases)
        XCTAssertEqual(checked.latestVersion, "0.1.28")
        XCTAssertEqual(checked.status, .updateAvailable)
        XCTAssertEqual(checked.releaseNotes, "Changes")
        XCTAssertTrue(checked.canAutomaticallyUpdate)
    }

    func testCollectsMultipleLatestReleaseCandidatesInTextOrder() {
        let candidates = GitHubReleasesDetector.metadataCandidates(
            in: """
                Dependency: https://github.com/MetaCubeX/mihomo/releases/latest
                Application: https://api.github.com/repos/chen08209/FlClash/releases/latest
                Duplicate: https://github.com/chen08209/FlClash/releases/latest
                """
        )

        XCTAssertEqual(
            candidates.map(\.identifier),
            ["MetaCubeX/mihomo", "chen08209/FlClash"]
        )
    }

    func testRemoteVersionMatchingInstalledBuildIsUpToDate() {
        var application = AppRecord(
            name: "ImHex",
            bundleIdentifier: "net.werwolv.imhex",
            applicationURL: URL(fileURLWithPath: "/Applications/ImHex.app"),
            currentVersion: "1.38",
            buildVersion: "1.38.1",
            updateConfiguration: UpdateConfiguration(mechanism: .selfManaged)
        )

        application.applyRemoteRelease(version: "1.38.1", canInstall: true)

        XCTAssertEqual(application.status, .upToDate)
        XCTAssertFalse(application.canAutomaticallyUpdate)
    }

    func testParsesStableReleaseAndSelectsMatchingMacAsset() throws {
        let data = releaseData(
            tag: "v26.8.4",
            assets: [
                "tty7-26.8.4-linux-x86_64.tar.gz",
                "tty7-26.8.4-windows-x86_64.zip",
                "tty7-26.8.4-macos-x86_64.dmg",
                "tty7-26.8.4-macos-arm64.dmg",
                "tty7-26.8.4-macos-arm64.zip",
                "checksums.txt",
            ]
        )

        let release = try XCTUnwrap(GitHubReleaseManifest.parse(data))

        XCTAssertEqual(release.version, "26.8.4")
        XCTAssertEqual(release.releaseNotes, "Changes")
        XCTAssertEqual(
            release.selectedPackage(architecture: .arm64)?.name,
            "tty7-26.8.4-macos-arm64.dmg"
        )
        XCTAssertEqual(release.selectedPackage(architecture: .arm64)?.size, 12_345_678)
        XCTAssertEqual(
            release.selectedPackage(architecture: .x64)?.name,
            "tty7-26.8.4-macos-x86_64.dmg"
        )
        XCTAssertEqual(release.checksumsAsset?.name, "checksums.txt")
    }

    func testParsesGitHubReleaseDownloadURL() throws {
        let download = try XCTUnwrap(
            GitHubReleaseDownload.parse(
                "https://github.com/saltpi/Aria.X/releases/download/1.0.7/AriaX.dmg"
            )
        )
        XCTAssertEqual(download.owner, "saltpi")
        XCTAssertEqual(download.repository, "Aria.X")
        XCTAssertEqual(download.tag, "1.0.7")
        XCTAssertEqual(download.fileName, "AriaX.dmg")
        XCTAssertEqual(
            download.apiURL?.absoluteString,
            "https://api.github.com/repos/saltpi/Aria.X/releases/tags/1.0.7"
        )

        let versioned = try XCTUnwrap(
            GitHubReleaseDownload.parse(
                "https://www.github.com/jsattler/BetterCapture/releases/download/v2026.3/BetterCapture-2026.3-arm64.dmg"
            )
        )
        XCTAssertEqual(versioned.tag, "v2026.3")
        XCTAssertEqual(versioned.fileName, "BetterCapture-2026.3-arm64.dmg")

        XCTAssertNil(
            GitHubReleaseDownload.parse(
                "https://github.com/openai/codex/archive/refs/tags/rust-v0.151.0.tar.gz"
            )
        )
        XCTAssertNil(
            GitHubReleaseDownload.parse("https://static.adguard.com/mac/release/AdGuard.dmg")
        )
    }

    func testSelectsCraftUniversalDMGInsteadOfCLIOrOtherPlatforms() throws {
        let package = "photocraft-0.7.0-macos-universal.dmg"
        let release = try XCTUnwrap(
            GitHubReleaseManifest.parse(
                releaseData(
                    tag: "v0.7.0",
                    assets: [
                        "photocraft-0.7.0-linux-aarch64.tar.gz",
                        "photocraft-0.7.0-windows-x64.zip",
                        package,
                        "photocraft-cli-0.7.0-macos-universal.zip",
                        "photocraft-web-0.7.0.zip",
                        "SHA256SUMS.txt",
                    ]
                )))

        XCTAssertEqual(release.selectedPackage(architecture: .arm64)?.name, package)
        XCTAssertEqual(release.selectedPackage(architecture: .x64)?.name, package)
        XCTAssertEqual(release.checksumsAsset?.name, "SHA256SUMS.txt")
    }

    func testSelectsWhatCableAppInsteadOfCLIRegardlessOfAssetOrder() throws {
        for assets in [
            ["whatcable-cli-1.5.0.zip", "WhatCable.zip"],
            ["WhatCable.zip", "whatcable-cli-1.5.0.zip"],
        ] {
            let release = try XCTUnwrap(
                GitHubReleaseManifest.parse(releaseData(tag: "v1.5.0", assets: assets)))
            for architecture in [MacCPUArchitecture.arm64, .x64] {
                XCTAssertEqual(
                    release.selectedPackage(architecture: architecture)?.name, "WhatCable.zip")
            }
        }
    }

    func testMacSpecificCLIIsNotPreferredToGenericApplicationArchive() throws {
        let release = try XCTUnwrap(
            GitHubReleaseManifest.parse(
                releaseData(
                    tag: "v1.0",
                    assets: [
                        "Example.zip", "example-cli-macos-arm64.dmg",
                        "example-command-line-darwin.zip",
                        "example-commandline-macos-universal.zip",
                    ])))
        XCTAssertEqual(release.selectedPackage()?.name, "Example.zip")
    }

    func testCLIOnlyReleaseHasNoDesktopInstallPackage() throws {
        let release = try XCTUnwrap(
            GitHubReleaseManifest.parse(
                releaseData(
                    tag: "v1.0",
                    assets: [
                        "example-cli-macos-arm64.zip", "example_cli_universal.dmg",
                    ])))
        XCTAssertNil(release.selectedPackage())
    }

    func testAppNameContainingCLIIsStillEligible() throws {
        let release = try XCTUnwrap(
            GitHubReleaseManifest.parse(
                releaseData(
                    tag: "v1.0",
                    assets: [
                        "CLion-macos-arm64.dmg"
                    ])))
        XCTAssertEqual(release.selectedPackage()?.name, "CLion-macos-arm64.dmg")
    }

    func testReadsGitHubReleaseAssetSizes() throws {
        let release = try XCTUnwrap(
            GitHubReleaseManifest.parse(
                releaseData(
                    tag: "v2026.3", assets: ["BetterCapture-2026.3-arm64.dmg", "checksums.txt"])))
        XCTAssertEqual(release.selectedPackage()?.name, "BetterCapture-2026.3-arm64.dmg")
        XCTAssertEqual(release.selectedPackage()?.size, 12_345_678)
    }

    func testIgnoresDraftAndPrereleaseResponses() {
        XCTAssertNil(
            GitHubReleaseManifest.parse(releaseData(tag: "v2.0.0-beta.1", prerelease: true))
        )
        XCTAssertNil(GitHubReleaseManifest.parse(releaseData(tag: "v2.0.0", draft: true)))
    }

    func testParsesCommonSHA256ManifestFormats() {
        let digest = String(repeating: "a", count: 64)
        let package = "tty7-26.8.4-macos-arm64.dmg"

        XCTAssertEqual(
            GitHubReleaseManifest.sha256(
                for: package,
                in: Data("\(digest)  *\(package)\n".utf8)
            ),
            digest
        )
        XCTAssertEqual(
            GitHubReleaseManifest.sha256(
                for: package,
                in: Data("SHA256 (\(package)) = \(digest)\n".utf8)
            ),
            digest
        )
        XCTAssertEqual(
            GitHubReleaseManifest.sha256(
                for: package,
                in: Data("\(digest)  ./\(package)\n".utf8)
            ),
            digest
        )
        XCTAssertEqual(
            GitHubReleaseManifest.sha256(
                for: package,
                in: Data("\(digest)  releases/\(package)\n".utf8)
            ),
            digest
        )
    }

    private func releaseData(
        tag: String,
        assets: [String] = [],
        prerelease: Bool = false,
        draft: Bool = false
    ) -> Data {
        let values: [String: Any] = [
            "tag_name": tag,
            "name": tag,
            "body": "Changes",
            "published_at": "2026-08-30T00:00:00Z",
            "html_url": "https://github.com/l0ng-ai/tty7/releases/tag/\(tag)",
            "prerelease": prerelease,
            "draft": draft,
            "assets": assets.map { name in
                [
                    "name": name,
                    "browser_download_url":
                        "https://github.com/l0ng-ai/tty7/releases/download/\(tag)/\(name)",
                    "size": 12_345_678,
                ]
            },
        ]
        return try! JSONSerialization.data(withJSONObject: values)
    }
}
