import XCTest

@testable import AppMint

final class HomebrewUpdateProviderTests: XCTestCase {
  func testOutdatedAutoUpdatesCaskIsUpdateAvailable() {
    let status = HomebrewUpdateProvider.resolvedStatus(
      currentVersion: "1.34493.0",
      remoteVersion: "1.34493.1,255293a41a25d54c5177aa9614fb4cd620e70b78"
    )
    XCTAssertEqual(status, .updateAvailable)
  }

  func testCurrentAutoUpdatesCaskIsUpToDate() {
    let status = HomebrewUpdateProvider.resolvedStatus(
      currentVersion: "1.34493.1",
      remoteVersion: "1.34493.1,255293a41a25d54c5177aa9614fb4cd620e70b78"
    )
    XCTAssertEqual(status, .upToDate)
  }

  func testMashedCaskVersionWithMatchingBuildIsNotAnUpdate() {
    let status = HomebrewUpdateProvider.resolvedStatus(
      currentVersion: "5.80.7",
      remoteVersion: "5.80.7.66659",
      buildVersion: "66659"
    )
    XCTAssertEqual(status, .upToDate)
  }

  func testCaskVersionMatchingBundleVersionIsUpToDate() {
    let status = HomebrewUpdateProvider.resolvedStatus(
      currentVersion: "1.38",
      remoteVersion: "1.38.1",
      buildVersion: "1.38.1"
    )
    XCTAssertEqual(status, .upToDate)
  }

  func testUnversionedLatestCaskStaysSelfManaged() {
    let status = HomebrewUpdateProvider.resolvedStatus(
      currentVersion: "1.0",
      remoteVersion: "latest"
    )
    XCTAssertEqual(status, .selfManaged)
  }

  func testPrefersHomebrewWhenBrewHasUpdate() {
    XCTAssertTrue(claim(.electronBuilder, .updateAvailable, feed: true, brew: true))
    XCTAssertTrue(claim(.vscodeUpdater, .updateAvailable, feed: true, brew: true))
    XCTAssertTrue(claim(.sparkle, .updateAvailable, feed: true, brew: true))
    XCTAssertTrue(claim(.tauri, .upToDate, feed: true, brew: true))
    XCTAssertTrue(claim(.releaseJSON, .checking, feed: true, brew: true))
    XCTAssertTrue(claim(.githubReleases, .upToDate, feed: true, brew: true))
  }

  func testKeepsWorkingFirstPartyProtocolWhenBrewHasNoUpdate() {
    XCTAssertFalse(claim(.electronBuilder, .checking, feed: true, brew: false))
    XCTAssertFalse(claim(.electronBuilder, .updateAvailable, feed: true, brew: false))
    XCTAssertFalse(claim(.vscodeUpdater, .checking, feed: true, brew: false))
    XCTAssertFalse(claim(.vscodeUpdater, .updateAvailable, feed: true, brew: false))
    XCTAssertFalse(claim(.sparkle, .upToDate, feed: true, brew: false))
    XCTAssertFalse(claim(.tauri, .checking, feed: true, brew: false))
    XCTAssertFalse(claim(.releaseJSON, .updateAvailable, feed: true, brew: false))
    XCTAssertFalse(claim(.githubReleases, .checking, feed: true, brew: false))
  }

  func testFallsBackToHomebrewWhenFirstPartyCheckFails() {
    XCTAssertTrue(claim(.vscodeUpdater, .selfManaged, feed: true, brew: false))
    XCTAssertTrue(claim(.electronBuilder, .unavailable("更新源暂时无法访问。"), feed: true, brew: false))
    XCTAssertTrue(claim(.sparkle, .unavailable("更新源暂时无法访问。"), feed: true, brew: false))
    XCTAssertTrue(claim(.tauri, .selfManaged, feed: true, brew: false))
  }

  func testClaimsCasksWithNoFirstPartyProtocol() {
    XCTAssertTrue(claim(.sparkle, .selfManaged, feed: false, brew: false))
    XCTAssertTrue(claim(.selfManaged, .selfManaged, feed: false, brew: false))
    XCTAssertTrue(claim(.homebrew, .selfManaged, feed: false, brew: false))
  }

  func testExtractsApplicationPathsFromPackageReceiptFileList() {
    let paths = HomebrewUpdateProvider.applicationPaths(
      inPackageFileList: """
        Applications
        Applications/SF Symbols Beta.app
        Applications/SF Symbols Beta.app/Contents/MacOS/SF Symbols Beta
        Library/Application Support/Example/config.json
        """
    )

    XCTAssertEqual(paths, ["/Applications/SF Symbols Beta.app"])
  }

  func testExtractsMultipleApplicationsFromPackageReceiptFileList() {
    let paths = HomebrewUpdateProvider.applicationPaths(
      inPackageFileList: """
        Applications/First.app/Contents/Info.plist
        /Applications/Second.app/Contents/Info.plist
        Applications/First.app/Contents/MacOS/First
        """
    )

    XCTAssertEqual(paths, ["/Applications/First.app", "/Applications/Second.app"])
  }

  private func claim(
    _ source: UpdateSource,
    _ status: UpdateStatus,
    feed: Bool,
    brew: Bool
  ) -> Bool {
    HomebrewUpdateProvider.shouldClaimInstalledCask(
      source: source,
      status: status,
      hasCheckableFeed: feed,
      brewHasUpdate: brew
    )
  }

  func testParsesCurlProgressBarPercent() {
    let parser = HomebrewOutputProgressParser()
    let progress = parser.consuming("####                                                                     12.5%\r")
    XCTAssertEqual(progress.status, "正在下载…")
    XCTAssertEqual(progress.fractionCompleted ?? 0, 0.125, accuracy: 0.0001)
  }

  func testParsesPercentSplitAcrossChunks() {
    let parser = HomebrewOutputProgressParser()
    _ = parser.consuming("==> Downloading https://example.com\n##### 4")
    let progress = parser.consuming("2.0%\r")
    XCTAssertEqual(progress.fractionCompleted ?? 0, 0.42, accuracy: 0.0001)
  }

  func testParsesHomebrewDownloadSizeRatio() {
    let parser = HomebrewOutputProgressParser()
    let progress = parser.consuming(
      "\u{001B}[34m⠋\u{001B}[0m cask ###### Downloading  25.0MB/ 50.0MB"
    )
    XCTAssertEqual(progress.status, "正在下载…")
    XCTAssertEqual(progress.fractionCompleted ?? 0, 0.5, accuracy: 0.0001)
  }

  func testCapsDownloadProgressThenSwitchesToInstalling() {
    let parser = HomebrewOutputProgressParser()
    let downloading = parser.consuming("######################################################################## 100.0%\r")
    XCTAssertEqual(downloading.fractionCompleted ?? 0, 0.9, accuracy: 0.0001)

    let installing = parser.consuming("\n==> Installing Cask token\n")
    XCTAssertEqual(installing.status, "正在安装…")
    XCTAssertEqual(installing.fractionCompleted ?? 0, 0.92, accuracy: 0.0001)
  }
}
