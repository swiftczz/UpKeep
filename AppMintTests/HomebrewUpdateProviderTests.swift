import XCTest

@testable import AppMint

final class HomebrewUpdateProviderTests: XCTestCase {
  func testOutdatedAutoUpdatesCaskIsUpdateAvailable() {
    let status = HomebrewUpdateProvider.resolvedStatus(
      currentVersion: "1.34493.0",
      remoteVersion: "1.34493.1,255293a41a25d54c5177aa9614fb4cd620e70b78",
      brewReportsOutdated: true,
      autoUpdates: true
    )
    XCTAssertEqual(status, .updateAvailable)
  }

  func testCurrentAutoUpdatesCaskIsSelfManaged() {
    let status = HomebrewUpdateProvider.resolvedStatus(
      currentVersion: "1.34493.1",
      remoteVersion: "1.34493.1,255293a41a25d54c5177aa9614fb4cd620e70b78",
      brewReportsOutdated: false,
      autoUpdates: true
    )
    XCTAssertEqual(status, .selfManaged)
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
