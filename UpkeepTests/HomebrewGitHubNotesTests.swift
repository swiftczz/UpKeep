import XCTest
@testable import Upkeep

final class HomebrewGitHubNotesTests: XCTestCase, @unchecked Sendable {
  private let download = GitHubReleaseDownload(owner: "example", repository: "app", tag: "v1.2.0", fileName: "App.dmg")
  private var data: Data {
    Data(#"{"tag_name":"v1.2.0","body":"Fixed export","assets":[{"name":"App.dmg","browser_download_url":"https://github.com/example/app/releases/download/v1.2.0/App.dmg","size":1234}]}"#.utf8)
  }
  private func app(version: String = "1.2.0", notes: String? = nil) -> AppRecord {
    var app = AppRecord(name: "App", bundleIdentifier: "example.app", applicationURL: URL(fileURLWithPath: "/Applications/App.app"), currentVersion: "1.1.0", source: .homebrew, sourceIdentifier: "app")
    app.latestVersion = version
    app.releaseNotes = notes
    app.status = .updateAvailable
    return app
  }

  func testExactReleaseFillsNotesAndSizeWithoutChangingUpdateSource() {
    let result = HomebrewUpdateProvider.applyingGitHubRelease(data, download: download, to: app())
    XCTAssertEqual(result.releaseNotes, "Fixed export")
    XCTAssertEqual(result.releaseNotesURL?.absoluteString, "https://github.com/example/app/releases/tag/v1.2.0")
    XCTAssertEqual(result.packageByteCount, 1234)
    XCTAssertEqual(result.source, .homebrew)
    XCTAssertEqual(result.status, .updateAvailable)
  }

  func testPreservesFirstPartyNotesAndLink() {
    var original = app(notes: "Official notes")
    original.releaseNotesURL = URL(string: "https://example.com/notes")
    let result = HomebrewUpdateProvider.applyingGitHubRelease(data, download: download, to: original)
    XCTAssertEqual(result.releaseNotes, original.releaseNotes)
    XCTAssertEqual(result.releaseNotesURL, original.releaseNotesURL)
  }

  func testRejectsDifferentVersionAndUnrelatedAsset() {
    XCTAssertNil(HomebrewUpdateProvider.applyingGitHubRelease(data, download: download, to: app(version: "1.3.0")).releaseNotes)
    let other = GitHubReleaseDownload(owner: "other", repository: "app", tag: "v1.2.0", fileName: "App.dmg")
    XCTAssertNil(HomebrewUpdateProvider.applyingGitHubRelease(data, download: other, to: app()).releaseNotes)
  }

  func testSupportsCaskVersionWithBuildSuffixAndEmptyExistingNotes() {
    XCTAssertEqual(HomebrewUpdateProvider.applyingGitHubRelease(data, download: download, to: app(version: "1.2.0,123", notes: " ")).releaseNotes, "Fixed export")
  }

  func testUnavailableOrEmptyBodyDoesNotFabricateNotes() {
    XCTAssertNil(HomebrewUpdateProvider.applyingGitHubRelease(Data("{}".utf8), download: download, to: app()).releaseNotes)
    let empty = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "Fixed export", with: " ").utf8)
    XCTAssertNil(HomebrewUpdateProvider.applyingGitHubRelease(empty, download: download, to: app()).releaseNotes)
  }

  func testMissingAlternateNotesDoesNotReplaceGitHubSourceLink() {
    let original = HomebrewUpdateProvider.applyingGitHubRelease(data, download: download, to: app())
    var checked = app()
    checked.source = .sparkle
    checked.releaseNotesURL = URL(string: "https://example.com/empty-notes")
    let result = HomebrewUpdateProvider.mergeAlternateCheckResult(checked, intoHomebrew: original)
    XCTAssertEqual(result.releaseNotesURL, original.releaseNotesURL)
  }

  func testReleaseResponseIsReusedWhenPackageSizeAlreadyKnown() async throws {
    let info = try JSONDecoder().decode(BrewInfoResponse.self, from: Data(#"{"casks":[{"token":"app","version":"1.2.0","url":"https://github.com/example/app/releases/download/v1.2.0/App.dmg","artifacts":[]}]}"#.utf8))
    let snapshot = HomebrewSnapshot(info: info, outdated: BrewOutdatedResponse(casks: []), packageApplicationPaths: [:])
    let calls = Counter()
    let data = data
    let provider = HomebrewUpdateProvider(fetchData: { url in
      XCTAssertEqual(url.absoluteString, "https://api.github.com/repos/example/app/releases/tags/v1.2.0")
      await calls.increment()
      return data
    })
    var original = app()
    original.packageByteCount = 999
    for _ in 0..<2 {
      let result = await provider.fillingGitHubReleaseMetadata([original, original], snapshot: snapshot)
      XCTAssertEqual(result.first?.releaseNotes, "Fixed export")
      XCTAssertEqual(result.first?.packageByteCount, 999)
    }
    let count = await calls.value
    XCTAssertEqual(count, 1)
  }
}

private actor Counter {
  var value = 0
  func increment() { value += 1 }
}
