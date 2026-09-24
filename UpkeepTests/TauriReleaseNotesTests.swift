import Foundation
import XCTest

@testable import Upkeep

final class TauriReleaseNotesTests: XCTestCase, @unchecked Sendable {
  private let catalog = URL(string: "https://dl.reasonix.io/studio/versions.json")!
  private let manifest = URL(string: "https://dl.reasonix.io/studio/test-latest.json")!
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

  func testReasonixStudioUsesAPIReleaseBodyWithoutFetchingPage() async {
    let app = await check(pages: [api: ###"{"body":"## 新增\n\n- 改进会话同步"}"###])
    XCTAssertEqual(app.releaseNotes, "## 新增\n\n- 改进会话同步")
    XCTAssertEqual(app.releaseNotesURL, release)
    XCTAssertEqual(app.latestVersion, "2.20.0")
    XCTAssertEqual(app.status, .updateAvailable)
    XCTAssertTrue(app.canAutomaticallyUpdate)
  }

  func testReasonixStudioRateLimitFallbackExcludesRepositoryControlsAndAssets() async {
    let app = await check(pages: [release: githubPage], failingURLs: [api])
    XCTAssertEqual(app.releaseNotes, "支持手机配对。\n\n新增\n\n• 改进会话同步")
    XCTAssertEqual(app.releaseNotesURL, release)
    XCTAssertEqual(app.status, .updateAvailable)
  }

  func testEmptyAPIBodyAlsoUsesScopedPageFallback() async {
    let app = await check(pages: [api: #"{"body":" "}"#, release: githubPage])
    XCTAssertEqual(app.releaseNotes, "支持手机配对。\n\n新增\n\n• 改进会话同步")
  }

  func testMissingReleaseBodyDoesNotReturnPageOrRetrySameAPIFromPackage() async {
    let app = await check(pages: [release:
      "<html><main><h1>Repository</h1><div>Choose a tag to compare</div><div>Assets 24</div></main></html>"
    ], failingURLs: [api])
    XCTAssertNil(app.releaseNotes)
    XCTAssertEqual(app.releaseNotesURL, release)
    XCTAssertEqual(app.status, .updateAvailable)
    XCTAssertTrue(app.canAutomaticallyUpdate)
  }

  private func check(pages: [URL: String], failingURLs: Set<URL> = []) async -> AppRecord {
    let catalog = catalog
    let manifest = manifest
    let release = release
    let api = api
    let requests = RequestCounts()
    let provider = TauriUpdateProvider(fetchData: { url in
      await requests.record(url)
      if url == catalog {
        return Data("""
          {"versions":[{"version":"2.20.0","manifest":"\(manifest.absoluteString)"}]}
          """.utf8)
      }
      if url == manifest {
        return Data("""
          {"version":"2.20.0","release_notes_url":"\(release.absoluteString)","platforms":{
            "darwin-universal":{"url":"https://github.com/esengine/DeepSeek-Reasonix/releases/download/studio-v2.20.0/Studio.app.tar.gz"}
          }}
          """.utf8)
      }
      if failingURLs.contains(url) { throw UpdateHTTPError.statusCode(403, retryAfter: nil) }
      guard let page = pages[url] else {
        XCTFail("Unexpected request: \(url)")
        return nil
      }
      return Data(page.utf8)
    })
    let checked = await provider.check(AppRecord(
      name: "Reasonix Studio", bundleIdentifier: "io.reasonix.studio",
      applicationURL: URL(fileURLWithPath: "/Applications/ReasonixStudio.app"),
      currentVersion: "2.19.0", source: .tauri,
      releaseNotes: "Notifications Star Choose a tag to compare", sourceURL: catalog
    ))
    let apiRequests = await requests.count(for: api)
    XCTAssertEqual(apiRequests, 1)
    return checked
  }
}

private actor RequestCounts {
  private var counts: [URL: Int] = [:]
  func record(_ url: URL) { counts[url, default: 0] += 1 }
  func count(for url: URL) -> Int { counts[url, default: 0] }
}
