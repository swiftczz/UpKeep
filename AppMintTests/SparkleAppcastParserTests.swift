import Foundation
import XCTest

@testable import AppMint

final class SparkleAppcastParserTests: XCTestCase {
  func testParsesVersionAndReleaseNotesMetadata() throws {
    let xml = """
      <?xml version="1.0" encoding="utf-8"?>
      <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
        <channel>
          <item>
            <title>Version 2.4</title>
            <pubDate>Thu, 20 Aug 2026 12:00:00 +0000</pubDate>
            <description><![CDATA[<p>Faster update checks.</p>]]></description>
            <sparkle:releaseNotesLink>https://example.com/notes</sparkle:releaseNotesLink>
            <enclosure
              url="https://example.com/App.zip"
              sparkle:version="240"
              sparkle:shortVersionString="2.4"
              sparkle:minimumSystemVersion="26.0"
              sparkle:os="macos"
            />
          </item>
        </channel>
      </rss>
      """

    let parser = SparkleAppcastParser(data: Data(xml.utf8))
    let candidate = try XCTUnwrap(parser.parse().first)

    XCTAssertEqual(candidate.shortVersion, "2.4")
    XCTAssertEqual(candidate.displayVersion, "2.4")
    XCTAssertEqual(candidate.buildVersion, "240")
    XCTAssertEqual(candidate.minimumSystemVersion, "26.0")
    XCTAssertEqual(candidate.operatingSystem, "macos")
    XCTAssertEqual(candidate.downloadURL?.absoluteString, "https://example.com/App.zip")
    XCTAssertEqual(candidate.releaseNotesURL?.absoluteString, "https://example.com/notes")
    XCTAssertEqual(candidate.publicationDate, "Thu, 20 Aug 2026 12:00:00 +0000")
  }

  func testParsesUnixTimestampPublicationDate() throws {
    let date = try XCTUnwrap(SparkleUpdateProvider.parsePublicationDate("1786372688"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    XCTAssertEqual(components.year, 2026)
    XCTAssertEqual(components.month, 8)
    XCTAssertEqual(components.day, 10)
    XCTAssertEqual(components.hour, 14)
    XCTAssertEqual(components.minute, 38)
  }

  func testParsesJavaScriptStyleGMTOffsetPublicationDate() throws {
    let date = try XCTUnwrap(
      SparkleUpdateProvider.parsePublicationDate("Wed, 12 Aug 2026 22:08:10 GMT+0200")
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    XCTAssertEqual(components.year, 2026)
    XCTAssertEqual(components.month, 8)
    XCTAssertEqual(components.day, 12)
    XCTAssertEqual(components.hour, 20)
    XCTAssertEqual(components.minute, 8)
  }

  func testParsesCTimeStylePublicationDateWithNamedTimeZone() throws {
    let date = try XCTUnwrap(
      SparkleUpdateProvider.parsePublicationDate("Mon Aug 3 18:18:39 CEST 2026")
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    let components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute],
      from: date
    )
    XCTAssertEqual(components.year, 2026)
    XCTAssertEqual(components.month, 8)
    XCTAssertEqual(components.day, 3)
    XCTAssertEqual(components.hour, 16)
    XCTAssertEqual(components.minute, 18)
  }

  func testParsesCTimeStylePublicationDateWithTwoDigitDay() throws {
    let date = try XCTUnwrap(
      SparkleUpdateProvider.parsePublicationDate("Tue Jun 23 15:23:58 CEST 2026")
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
    XCTAssertEqual(components.year, 2026)
    XCTAssertEqual(components.month, 6)
    XCTAssertEqual(components.day, 23)
    XCTAssertEqual(components.hour, 13)
  }

  func testParsesGMTPublicationDate() throws {
    let date = try XCTUnwrap(
      SparkleUpdateProvider.parsePublicationDate("Thu, 20 Aug 2026 12:00:00 GMT")
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
    XCTAssertEqual(components.year, 2026)
    XCTAssertEqual(components.month, 8)
    XCTAssertEqual(components.day, 20)
    XCTAssertEqual(components.hour, 12)
  }

  func testUsesCleanVersionTitleWhenShortVersionContainsBuildNumber() throws {
    let candidate = SparkleCandidate(
      title: "Version 2.9.2",
      shortVersion: "2.9.2.1014 release",
      buildVersion: "1014"
    )

    XCTAssertEqual(candidate.displayVersion, "2.9.2")
  }

  func testOnlySecureDownloadPayloadEnablesDirectUpdate() throws {
    let feedURL = try XCTUnwrap(URL(string: "https://example.com/releases/appcast.xml"))
    let relativeCandidate = SparkleCandidate(downloadURL: URL(string: "App.zip"))
    let insecureCandidate = SparkleCandidate(
      downloadURL: URL(string: "http://example.com/App.zip")
    )
    let informationOnlyCandidate = SparkleCandidate()

    XCTAssertTrue(relativeCandidate.hasSecureDownload(relativeTo: feedURL))
    XCTAssertFalse(insecureCandidate.hasSecureDownload(relativeTo: feedURL))
    XCTAssertFalse(informationOnlyCandidate.hasSecureDownload(relativeTo: feedURL))
  }

  func testPrefersHigherBuildWhenMarketingVersionsMatch() {
    let older = SparkleCandidate(shortVersion: "2.4.1", buildVersion: "108")
    let newer = SparkleCandidate(shortVersion: "2.4.1", buildVersion: "110")

    let candidate = SparkleUpdateProvider.bestCandidate(from: [older, newer])

    XCTAssertEqual(candidate?.buildVersion, "110")
    XCTAssertEqual(candidate?.shortVersion, "2.4.1")
  }

  func testShowsBuildWhenSparkleMarketingVersionIsUnchanged() {
    let application = AppRecord(
      name: "ExcalidrawZ",
      bundleIdentifier: "com.chocoford.excalidraw",
      applicationURL: URL(fileURLWithPath: "/Applications/ExcalidrawZ.app"),
      currentVersion: "2.4.1",
      buildVersion: "108",
      source: .sparkle,
      status: .updateAvailable,
      latestVersion: "2.4.1",
      latestBuildVersion: "110"
    )

    XCTAssertEqual(application.versionSummary, "2.4.1 (108)")
    XCTAssertEqual(application.latestVersionSummary, "2.4.1 (110)")
    XCTAssertEqual(application.updateVersionSummary, "2.4.1 (108) → 2.4.1 (110)")
  }

  func testOmitsBuildWhenMarketingVersionsAlreadyDiffer() {
    let application = AppRecord(
      name: "macshot",
      bundleIdentifier: "com.sw33tlie.macshot.macshot",
      applicationURL: URL(fileURLWithPath: "/Applications/macshot.app"),
      currentVersion: "4.2.1",
      buildVersion: "99",
      source: .sparkle,
      status: .updateAvailable,
      latestVersion: "4.2.2-beta.2",
      latestBuildVersion: "101"
    )

    XCTAssertEqual(application.versionSummary, "4.2.1")
    XCTAssertEqual(application.latestVersionSummary, "4.2.2-beta.2")
    XCTAssertEqual(application.updateVersionSummary, "4.2.1 → 4.2.2-beta.2")
  }
}
