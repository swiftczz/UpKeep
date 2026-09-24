import Foundation
import XCTest
@testable import Upkeep

final class SparkleReleaseNotesTests: XCTestCase, @unchecked Sendable {
  private let feed = URL(string: "https://example.com/appcast.xml")!

  private func check(_ fields: String, pages: [String: String], fallback: AppRecord? = nil) async -> AppRecord {
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
      source: .sparkle, sourceURL: feed), fallbackNotes: fallback)
  }

  func testDescriptionTakesPriorityWithoutFetchingPages() async {
    let app = await check("""
      <description><![CDATA[<p>Inline notes</p>]]></description>
      <sparkle:releaseNotesLink>https://example.com/notes</sparkle:releaseNotesLink>
      <link>https://example.com/release</link>
      """, pages: [:])
    XCTAssertEqual(app.releaseNotes, "Inline notes")
  }

  func testInlineHTMLDescriptionRemovesStylesAndPreservesHeadingsAndLists() async {
    let app = await check("""
      <description><![CDATA[<!DOCTYPE html><html><head>
      <style>body { font-family: -apple-system; } h3 { margin: 12px 0; }</style>
      </head><body><h3>Added</h3><ul><li>Element snapping &amp; capture</li></ul>
      <h3>Improved and fixed</h3><ul><li>Recording and export</li></ul>
      <script>tracking()</script></body></html>]]></description>
      """, pages: [:])
    XCTAssertEqual(app.releaseNotes, "Added\n\n• Element snapping & capture\n\nImproved and fixed\n\n• Recording and export")
  }

  func testMacshotEscapedDescriptionRemovesStyleContents() async {
    let app = await check("""
      <description>&lt;style&gt;body { font-size: 13px; }&lt;/style&gt;
      &lt;h3&gt;Added&lt;/h3&gt;&lt;ul&gt;&lt;li&gt;&lt;b&gt;Element snapping&lt;/b&gt; — capture windows&lt;/li&gt;&lt;/ul&gt;</description>
      """, pages: [:])
    XCTAssertEqual(app.releaseNotes, "Added\n\n• Element snapping — capture windows")
  }

  func testHomebrewGitHubFallbackComesBetweenInlineNotesAndWebpage() async {
    var fallback = AppRecord(name: "Example", bundleIdentifier: "com.example.app",
      applicationURL: URL(fileURLWithPath: "/Applications/Example.app"), currentVersion: "1.1.4", source: .homebrew)
    fallback.latestVersion = "1.1.4,10"
    fallback.releaseNotes = "GitHub notes"
    fallback.releaseNotesURL = URL(string: "https://github.com/example/app/releases/tag/v1.1.4")
    let fields = "<link>https://example.com/release</link>"
    let result = await check(fields, pages: [:], fallback: fallback)
    XCTAssertEqual(result.releaseNotes, "GitHub notes")
    XCTAssertEqual(result.releaseNotesURL, fallback.releaseNotesURL)
    let inline = await check("<description>Inline notes</description>" + fields, pages: [:], fallback: fallback)
    XCTAssertEqual(inline.releaseNotes, "Inline notes")
    fallback.latestVersion = "1.1.3"
    let different = await check(fields, pages: ["https://example.com/release": "<p>Correct version</p>"], fallback: fallback)
    XCTAssertEqual(different.releaseNotes, "Correct version")
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

  func testCompositorFallsBackToGitHubPageWhenAPIIsRateLimited() async {
    let link = "https://github.com/robbietilton/Compositor/releases/tag/v1.2.10"
    let api = "https://api.github.com/repos/robbietilton/Compositor/releases/tags/v1.2.10"
    let page = """
      <html><body><nav>Repositories Sign in</nav><main>
        <h1>Compositor releases</h1><aside>Other release 1.2.9</aside>
        <div data-test-selector="body-content" class="markdown-body tmp-my-3">
          <p>SVG files import at canvas size.</p><p>Magic Wand no longer freezes.</p>
        </div><footer>Legal</footer>
      </main></body></html>
      """
    let app = await check("<link>\(link)</link>", pages: [api: "", link: page])
    XCTAssertEqual(app.releaseNotes, "SVG files import at canvas size.\n\nMagic Wand no longer freezes.")
    XCTAssertEqual(app.releaseNotesURL?.absoluteString, link)
  }

  func testGitHubPageWithoutReleaseBodyNeverShowsNavigation() async {
    let link = "https://github.com/example/app/releases/tag/v1.1.4"
    let api = "https://api.github.com/repos/example/app/releases/tags/v1.1.4"
    let app = await check("<link>\(link)</link>", pages: [api: "", link:
      "<html><body><nav>Sign in</nav><main><h1>Repository releases</h1></main></body></html>"])
    XCTAssertNil(app.releaseNotes)
    XCTAssertEqual(app.releaseNotesURL?.absoluteString, link)
  }

  func testUnsafeLinkIsNotFetched() async {
    for link in ["http://example.com/notes", "file:///tmp/notes", "javascript:alert(1)"] {
      let app = await check("<link>\(link)</link>", pages: [:])
      XCTAssertNil(app.releaseNotes)
    }
  }
}
