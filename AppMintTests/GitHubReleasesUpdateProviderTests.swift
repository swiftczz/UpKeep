import Foundation
import XCTest

@testable import AppMint

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
      buildVersion: "1.38.1"
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
    XCTAssertEqual(
      release.selectedPackage(architecture: .x64)?.name,
      "tty7-26.8.4-macos-x86_64.dmg"
    )
    XCTAssertEqual(release.checksumsAsset?.name, "checksums.txt")
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
        ]
      },
    ]
    return try! JSONSerialization.data(withJSONObject: values)
  }
}
