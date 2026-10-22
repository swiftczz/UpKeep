import XCTest

@testable import Upkeep

final class ReleaseNotesHTMLTests: XCTestCase {
    func testExtractsTheArticleWithAHeadingAndSkipsPageChrome() {
        let page = """
            <html><head><title>Site title</title></head><body>
            <nav>Features Sign in Install</nav><main><aside>Release ledger v1.0 v0.9</aside>
            <article><h1>Editor 2.0</h1>
            <p>Preserve <strong>image</strong> history &amp; exports.</p>
            <button>Download</button></article></main>
            <footer>Copyright</footer></body></html>
            """
        XCTAssertEqual(
            ReleaseNotesHTML.text(page), "Editor 2.0\n\nPreserve image history & exports.")
    }

    func testPreservesFragmentStructure() {
        XCTAssertEqual(
            ReleaseNotesHTML.text("<p>Fixes</p><ul><li>One</li><li>Two</li></ul>"),
            "Fixes\n\n• One\n\n• Two")
    }

    func testOmitsPageChromeAndHiddenElementsInMainFallback() {
        XCTAssertEqual(
            ReleaseNotesHTML.text(
                "<main><nav>Menu</nav><p>Fix &#38; improve<br>Next line</p><p hidden>Hidden</p><aside>Versions</aside><script>noise()</script></main>"
            ), "Fix & improve\nNext line")
    }

    func testEmptyContent() {
        XCTAssertNil(ReleaseNotesHTML.text("<html><body><script>noise()</script></body></html>"))
    }
}
