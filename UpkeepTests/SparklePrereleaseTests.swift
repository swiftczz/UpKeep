import Foundation
import XCTest

@testable import Upkeep

final class SparklePrereleaseTests: XCTestCase, @unchecked Sendable {
  private let feedURL = URL(string: "https://example.com/appcast.xml")!
  private let prereleaseItem = """
    <item>
      <title>4.0.0-prerelease</title>
      <link>https://github.com/PlayCover/PlayCover/releases/tag/4.0.0-prerelease</link>
      <sparkle:version>1633</sparkle:version>
      <sparkle:shortVersionString>4.0.0</sparkle:shortVersionString>
      <enclosure url="https://github.com/PlayCover/PlayCover/releases/download/4.0.0-prerelease/PlayCover_4.0.0-prerelease.dmg" />
    </item>
    """
  private let stableItem = """
    <item>
      <title>3.1.0</title>
      <sparkle:version>856</sparkle:version>
      <sparkle:shortVersionString>3.1.0</sparkle:shortVersionString>
      <description>Stable release notes</description>
      <enclosure url="https://example.com/PlayCover_3.1.0.dmg" />
    </item>
    """

  private func feed(_ items: String) -> Data {
    Data(
      """
      <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>\(items)</channel></rss>
      """.utf8)
  }

  private func app(build: String = "856") -> AppRecord {
    AppRecord(
      name: "PlayCover",
      bundleIdentifier: "io.playcover.PlayCover",
      applicationURL: URL(fileURLWithPath: "/Applications/PlayCover.app"),
      currentVersion: "3.1.0",
      buildVersion: build,
      updateConfiguration: UpdateConfiguration(mechanism: .sparkle, feedURL: feedURL)
    )
  }

  func testPlayCoverFeedSelectsStableReleaseDespitePlainShortVersion() throws {
    let candidates = try SparkleAppcastParser(data: feed(prereleaseItem + stableItem)).parse()
    let candidate = try XCTUnwrap(SparkleUpdateProvider.bestCandidate(from: candidates))
    XCTAssertEqual(candidate.displayVersion, "3.1.0")
    XCTAssertEqual(candidate.buildVersion, "856")
  }

  func testPrereleaseLabelsInTitleAndReleasePathsAreRecognized() {
    let candidates = [
      SparkleCandidate(title: "4.0.0-prerelease", shortVersion: "4.0.0"),
      SparkleCandidate(title: "PlayCover v4.0.0 Pre-release", shortVersion: "4.0.0"),
      SparkleCandidate(
        shortVersion: "4.0.0",
        releaseNotesURL:
          URL(string: "https://example.com/releases/v4.0.0-rc.1")),
      SparkleCandidate(
        shortVersion: "4.0.0",
        updatePageURL:
          URL(string: "https://example.com/releases/v4.0.0-beta")),
      SparkleCandidate(
        shortVersion: "4.0.0",
        downloadURL:
          URL(string: "https://example.com/PlayCover_4.0.0-prerelease.dmg")),
    ]
    for candidate in candidates {
      XCTAssertTrue(candidate.isPrerelease, "\(candidate)")
      XCTAssertNil(SparkleUpdateProvider.bestCandidate(from: [candidate]))
    }
    let stable = SparkleCandidate(
      title: "BetaApp 4.0.0", shortVersion: "4.0.0",
      downloadURL: URL(string: "https://example.com/beta/PreviewApp_4.0.0.dmg"))
    XCTAssertFalse(stable.isPrerelease)
  }

  func testCheckReplacesCachedPrereleaseMetadataWithStableRelease() async {
    let data = feed(prereleaseItem + stableItem)
    let provider = SparkleUpdateProvider(fetchData: { _ in data })
    for build in ["856", "1633"] {
      var application = app(build: build)
      application.latestVersion = "4.0.0"
      application.latestBuildVersion = "1633"
      application.releaseNotes = "Prerelease notes"
      application.status = .updateAvailable
      let result = await provider.check(application)
      XCTAssertEqual(result.currentVersion, "3.1.0")
      XCTAssertEqual(result.buildVersion, build)
      XCTAssertEqual(result.latestVersion, "3.1.0")
      XCTAssertEqual(result.latestBuildVersion, "856")
      XCTAssertEqual(result.releaseNotes, "Stable release notes")
      XCTAssertEqual(result.status, .upToDate)
      XCTAssertFalse(result.canAutomaticallyUpdate)
    }
  }

  func testPrereleaseOnlyFeedClearsCachedUpdateMetadata() async {
    let data = feed(prereleaseItem)
    let provider = SparkleUpdateProvider(fetchData: { _ in data })
    var application = app()
    application.latestVersion = "4.0.0"
    application.latestBuildVersion = "1633"
    application.releaseNotes = "Prerelease notes"
    application.releaseNotesURL = URL(string: "https://example.com/4.0.0-prerelease")
    application.releaseDate = .now
    application.packageByteCount = 7_031_217
    application.updatePageURL = application.releaseNotesURL
    application.status = .updateAvailable
    application.canAutomaticallyUpdate = true
    let result = await provider.check(application)
    XCTAssertEqual(result.status, .upToDate)
    XCTAssertFalse(result.canAutomaticallyUpdate)
    XCTAssertNil(result.latestVersion)
    XCTAssertNil(result.latestBuildVersion)
    XCTAssertNil(result.releaseNotes)
    XCTAssertNil(result.releaseNotesURL)
    XCTAssertNil(result.releaseDate)
    XCTAssertNil(result.packageByteCount)
    XCTAssertNil(result.updatePageURL)
  }
}
