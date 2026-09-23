import Foundation
import XCTest
@testable import Upkeep

final class SparkleReleaseNotesTests: XCTestCase, @unchecked Sendable {
  private let feed = URL(string: "https://example.com/appcast.xml")!

  private func check(_ fields: String, pages: [String: String]) async -> AppRecord {
    let xml = """
      <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
      <item><sparkle:version>10</sparkle:version><sparkle:shortVersionString>1.1.4</sparkle:shortVersionString>
      \(fields)<enclosure url="https://example.com/App.dmg" /></item></channel></rss>
      """
    let feed = feed
    let provider = SparkleUpdateProvider(fetchData: { url in
      if url == feed { return Data(xml.utf8) }
      guard let page = pages[url.absoluteString] else {
        XCTFail("Unexpected request: \(url)")
        return nil
      }
      return Data(page.utf8)
    })
    return await provider.check(AppRecord(name: "Example", bundleIdentifier: "com.example.app",
      applicationURL: URL(fileURLWithPath: "/Applications/Example.app"), currentVersion: "1.1.4",
      source: .sparkle, sourceURL: feed))
  }

  func testDescriptionTakesPriorityWithoutFetchingPages() async {
    let app = await check("""
      <description><![CDATA[<p>Inline notes</p>]]></description>
      <sparkle:releaseNotesLink>https://example.com/notes</sparkle:releaseNotesLink>
      <link>https://example.com/release</link>
      """, pages: [:])
    XCTAssertEqual(app.releaseNotes, "Inline notes")
  }

  func testDedicatedLinkTakesPriority() async {
    let app = await check("""
      <sparkle:releaseNotesLink>https://example.com/notes</sparkle:releaseNotesLink>
      <link>https://example.com/release</link>
      """, pages: ["https://example.com/notes": "<p>Dedicated notes</p>"])
    XCTAssertEqual(app.releaseNotes, "Dedicated notes")
  }

  func testEmptyDedicatedNotesFallBackToRelativeItemLinkAndRemoveChrome() async {
    let app = await check("""
      <sparkle:releaseNotesLink>notes</sparkle:releaseNotesLink><link>release</link>
      """, pages: ["https://example.com/notes": " ", "https://example.com/release":
        "<head><title>Site</title></head><nav>Menu</nav><script>code()</script><main><p>Fixed bugs</p></main><footer>Legal</footer>"])
    XCTAssertEqual(app.releaseNotes, "Fixed bugs")
    XCTAssertEqual(app.releaseNotesURL?.absoluteString, "https://example.com/release")
    XCTAssertEqual(app.status, .upToDate)
    XCTAssertNil(app.updatePageURL) // Downloadable Sparkle updates remain installable.
  }

  func testCompositorItemLinkFetchesExactGitHubReleaseBody() async {
    let link = "https://github.com/robbietilton/Compositor/releases/tag/v1.1.4"
    let app = await check("<link>\(link)</link>", pages: [
      "https://api.github.com/repos/robbietilton/Compositor/releases/tags/v1.1.4":
        #"{"body":"Compositor 1.1.4"}"#])
    XCTAssertEqual(app.releaseNotes, "Compositor 1.1.4")
    XCTAssertEqual(app.releaseNotesURL?.absoluteString, link)
  }

  func testUnsafeLinkIsNotFetched() async {
    for link in ["http://example.com/notes", "file:///tmp/notes", "javascript:alert(1)"] {
      let app = await check("<link>\(link)</link>", pages: [:])
      XCTAssertNil(app.releaseNotes)
    }
  }
}
