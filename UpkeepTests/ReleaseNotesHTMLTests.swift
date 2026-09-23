import XCTest
@testable import Upkeep

final class ReleaseNotesHTMLTests: XCTestCase {
  private let page = """
    <html><head><title>Site title</title></head><body>
    <nav>Features Sign in Install</nav><main><aside>Release ledger v1.0 v0.9</aside>
    <article class="release-paper"><header><h1>Reasonix v1.38.11</h1>
    <div class="release-builds">Build metadata</div>
    <p><span class="l-en">Improved sessions.</span><span class="l-zh">改善会话。</span></p></header>
    <section class="release-guides">Read the guides</section>
    <section><div class="release-section__head"><span>01</span><h2><span class="l-en">Fixes</span><span class="l-zh">修复</span></h2></div>
    <article><span class="release-highlight__index">02</span><h3><span class="l-en">Attachments</span><span class="l-zh">附件</span></h3>
    <p><span class="l-en">Preserve <strong>image</strong> history &amp; exports.</span><span class="l-zh">保留<strong>图片</strong>历史记录与导出。</span></p>
    <div class="release-refs">#10558</div></article></section>
    <section class="release-download">Download now</section></article></main>
    <footer>Copyright</footer></body></html>
    """

  func testExtractsReasonixArticleInChinese() {
    XCTAssertEqual(ReleaseNotesHTML.text(page, preferredLanguages: ["zh-Hans"]), """
      Reasonix v1.38.11

      改善会话。

      修复

      附件

      保留图片历史记录与导出。
      """)
  }

  func testExtractsEnglishWithoutDuplicateTranslation() {
    let text = ReleaseNotesHTML.text(page, preferredLanguages: ["en-US"])
    XCTAssertTrue(text?.contains("Preserve image history & exports.") == true)
    XCTAssertFalse(text?.contains("保留") == true)
    XCTAssertFalse(text?.contains("Release ledger") == true)
  }

  func testPreservesAvailableLanguageAndFragmentStructure() {
    XCTAssertEqual(ReleaseNotesHTML.text("<p class='l-en'>Only English</p><ul><li>One</li><li>Two</li></ul>", preferredLanguages: ["zh"]), "Only English\n\n• One\n\n• Two")
  }

  func testOmitsPageChromeAndHiddenElementsInMainFallback() {
    XCTAssertEqual(ReleaseNotesHTML.text("<main><nav>Menu</nav><p>Fix &#38; improve<br>Next line</p><p hidden>Hidden</p><aside>Versions</aside><script>noise()</script></main>"), "Fix & improve\nNext line")
  }

  func testEmptyContent() {
    XCTAssertNil(ReleaseNotesHTML.text("<html><body><script>noise()</script></body></html>"))
  }
}
