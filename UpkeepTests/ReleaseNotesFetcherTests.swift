import Foundation
import XCTest

@testable import Upkeep

final class ReleaseNotesFetcherTests: XCTestCase, @unchecked Sendable {
  private let release = URL(string: "https://github.com/esengine/DeepSeek-Reasonix/releases/tag/studio-v2.20.0")!
  private let api = URL(string: "https://api.github.com/repos/esengine/DeepSeek-Reasonix/releases/tags/studio-v2.20.0")!

  // The repository header, tag selector and assets are siblings of the release body.
  private let githubPage = """
    <!doctype html><html><body><nav>Navigation Menu</nav><main>
      <div>esengine / DeepSeek-Reasonix Public</div>
      <ul><li>Notifications You must be signed in</li><li>Fork 2.4k</li><li>Star 35.7k</li></ul>
      <h1>Reasonix Studio v2.20.0</h1><div>Pre-release</div>
      <div>Choose a tag to compare</div><div>Filter</div><div>View all tags</div>
      <div class="markdown-body tmp-my-3" data-test-selector="body-content">
        <p>支持手机配对。</p><h2>新增</h2><ul><li>改进会话同步</li></ul>
      </div>
      <div>Assets 24</div><div>Loading</div><div>All reactions</div>
    </main><footer>Terms Privacy</footer></body></html>
    """

  func testGenericHTMLAndPlainTextChangelogsStillWork() async {
    let url = URL(string: "https://reasonix.io/changelog/v1.39.0/")!
    for (input, expected) in [
      ("<html><nav>Menu</nav><main><h1>更新</h1><p>修复会话恢复</p></main><footer>Legal</footer></html>", "更新\n\n修复会话恢复"),
      ("## 更新\n\n- 修复会话恢复", "## 更新\n\n- 修复会话恢复")
    ] {
      let notes = await ReleaseNotesFetcher.fetch(from: url, fetchData: { requested in
        XCTAssertEqual(requested, url)
        return Data(input.utf8)
      })
      XCTAssertEqual(notes, expected)
    }
  }

  func testWWWGitHubReleaseAlsoUsesScopedFallback() async {
    let url = URL(string: "https://www.github.com/esengine/DeepSeek-Reasonix/releases/tag/studio-v2.20.0")!
    let page = githubPage
    let api = api
    let notes = await ReleaseNotesFetcher.fetch(from: url, fetchData: { requested in
      if requested == api { return nil }
      XCTAssertEqual(requested, url)
      return Data(page.utf8)
    })
    XCTAssertEqual(notes, "支持手机配对。\n\n新增\n\n• 改进会话同步")
  }

  func testCancellationDuringAPIRequestDoesNotFetchPage() async {
    let url = release
    let api = api
    let task = Task {
      await ReleaseNotesFetcher.fetch(from: url, fetchData: { requested in
        XCTAssertEqual(requested, api)
        withUnsafeCurrentTask { $0?.cancel() }
        throw CancellationError()
      })
    }
    let notes = await task.value
    XCTAssertNil(notes)
  }

}

extension ReleaseNotesFetcherTests {
  func testPackageFallbackFetchesReleasePageInsteadOfDownloadingAsset() async {
    let package = URL(string: "https://github.com/esengine/DeepSeek-Reasonix/releases/download/studio-v2.20.0/App.tar.gz")!
    let page = githubPage
    let release = release
    let api = api
    let notes = await ReleaseNotesFetcher.fetch(from: nil, packageURL: package, fetchData: { url in
      if url == api { throw URLError(.cannotConnectToHost) }
      XCTAssertEqual(url, release)
      return Data(page.utf8)
    })
    XCTAssertEqual(notes, "支持手机配对。\n\n新增\n\n• 改进会话同步")
  }

  func testEncodedReleaseTagsAreDecodedOnceForAPIAndPage() async throws {
    for (tag, encoded) in [("v1/beta", "v1%2Fbeta"), ("v1%2Fbeta", "v1%252Fbeta"), ("发布 1", "%E5%8F%91%E5%B8%83%201")] {
      let package = try XCTUnwrap(URL(string: "https://github.com/example/app/releases/download/\(encoded)/App.zip"))
      let api = try XCTUnwrap(GitHubReleaseNotes.apiURL(from: package))
      XCTAssertEqual(api.absoluteString, "https://api.github.com/repos/example/app/releases/tags/\(encoded)", tag)
      let expectedPage = "https://github.com/example/app/releases/tag/\(encoded)"
      let notes = await ReleaseNotesFetcher.fetch(from: nil, packageURL: package, fetchData: { url in
        if url == api { return nil }
        XCTAssertEqual(url.absoluteString, expectedPage)
        return Data("<div data-test-selector='body-content' class='markdown-body'><p>Notes</p></div>".utf8)
      })
      XCTAssertEqual(notes, "Notes")
    }
  }

  func testUnsafeAndUnrecognizedGitHubURLsAreNotFetched() async {
    for raw in ["http://github.com/example/app/releases/tag/v1", "file:///tmp/notes", "https://github.com/example/app", "https://github.com/example/app/issues/123"] {
      let notes = await ReleaseNotesFetcher.fetch(from: URL(string: raw), fetchData: { url in
        XCTFail("Unexpected request: \(url)")
        return nil
      })
      XCTAssertNil(notes)
    }
  }

  func testOversizedAPIResponseFallsBackAndOversizedPageIsRejected() async {
    let api = api
    let oversized = Data(repeating: 32, count: ReleaseNotesFetcher.maximumBytes + 1)
    let page = githubPage
    let notes = await ReleaseNotesFetcher.fetch(from: release, fetchData: { url in
      url == api ? oversized : Data(page.utf8)
    })
    XCTAssertEqual(notes, "支持手机配对。\n\n新增\n\n• 改进会话同步")
    let missing = await ReleaseNotesFetcher.fetch(from: release, fetchData: { _ in oversized })
    XCTAssertNil(missing)
  }

  func testExistingAPIResponseBodyMatchesManifestParsing() throws {
    let data = Data(###"{"tag_name":"v1.0","body":"  ## Notes\n\n- Keep Markdown  ","assets":[]}"###.utf8)
    let manifest = try XCTUnwrap(GitHubReleaseManifest.parse(data))
    XCTAssertEqual(GitHubReleaseNotes.parseAPIResponse(data), manifest.releaseNotes)
    XCTAssertEqual(manifest.releaseNotes, "## Notes\n\n- Keep Markdown")
  }
}
