import Foundation
import XCTest

@testable import AppPulse

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
    XCTAssertEqual(candidate.releaseNotesURL?.absoluteString, "https://example.com/notes")
  }

  func testUsesCleanVersionTitleWhenShortVersionContainsBuildNumber() throws {
    let candidate = SparkleCandidate(
      title: "Version 2.9.2",
      shortVersion: "2.9.2.1014 release",
      buildVersion: "1014"
    )

    XCTAssertEqual(candidate.displayVersion, "2.9.2")
  }
}
