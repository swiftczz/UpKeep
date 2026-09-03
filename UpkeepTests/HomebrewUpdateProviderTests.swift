import XCTest

@testable import Upkeep

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

  func testPrefersCaskHomepageOverExistingUpdaterURL() {
    let existing = URL(
      string: "https://antigravity-hub-auto-updater.example/manifest"
    )
    XCTAssertEqual(
      HomebrewUpdateProvider.homepageURL(
        caskHomepage: "https://antigravity.google/product/antigravity-2",
        existing: existing
      )?.absoluteString,
      "https://antigravity.google/product/antigravity-2"
    )
  }

  func testKeepsExistingHomepageWhenCaskOmitsHomepage() {
    let existing = URL(string: "https://example.com")
    XCTAssertEqual(
      HomebrewUpdateProvider.homepageURL(caskHomepage: nil, existing: existing),
      existing
    )
    XCTAssertEqual(
      HomebrewUpdateProvider.homepageURL(caskHomepage: "  ", existing: existing),
      existing
    )
  }

  func testPrefersHomebrewWhenBrewHasUpdate() {
    XCTAssertTrue(claim(.electronBuilder, .updateAvailable, feed: true, brew: true))
    XCTAssertTrue(claim(.vscodeUpdater, .updateAvailable, feed: true, brew: true))
    XCTAssertTrue(claim(.sparkle, .updateAvailable, feed: true, brew: true))
    XCTAssertTrue(claim(.tauri, .upToDate, feed: true, brew: true))
    XCTAssertTrue(claim(.releaseJSON, .checking, feed: true, brew: true))
    XCTAssertTrue(claim(.githubReleases, .upToDate, feed: true, brew: true))
  }

  func testClaimsInstalledCaskWhenBrewHasNoUpdate() {
    XCTAssertTrue(claim(.electronBuilder, .checking, feed: true, brew: false))
    XCTAssertFalse(claim(.electronBuilder, .updateAvailable, feed: true, brew: false))
    XCTAssertTrue(claim(.vscodeUpdater, .checking, feed: true, brew: false))
    XCTAssertFalse(claim(.vscodeUpdater, .updateAvailable, feed: true, brew: false))
    XCTAssertTrue(claim(.sparkle, .upToDate, feed: true, brew: false))
    XCTAssertTrue(claim(.tauri, .checking, feed: true, brew: false))
    XCTAssertFalse(claim(.releaseJSON, .updateAvailable, feed: true, brew: false))
    XCTAssertTrue(claim(.githubReleases, .checking, feed: true, brew: false))
  }

  func testClaimsCaskAndRetainsSparkleFeedForChecks() throws {
    let info = try JSONDecoder().decode(
      BrewInfoResponse.self,
      from: Data(
        """
        {
          "casks": [
            {
              "token": "screendrop",
              "version": "0.31.3",
              "homepage": "https://example.com/screendrop",
              "url": null,
              "artifacts": [
                {
                  "app": ["Screendrop.app"],
                  "target": "/Applications/Screendrop.app"
                }
              ]
            }
          ]
        }
        """.utf8
      )
    )
    let outdated = try JSONDecoder().decode(
      BrewOutdatedResponse.self,
      from: Data(#"{"casks":[]}"#.utf8)
    )
    let snapshot = HomebrewSnapshot(
      info: info,
      outdated: outdated,
      packageApplicationPaths: [:]
    )
    let application = AppRecord(
      name: "Screendrop",
      bundleIdentifier: "com.fayazahmed.Screendrop",
      applicationURL: URL(fileURLWithPath: "/Applications/Screendrop.app"),
      currentVersion: "0.31.3",
      source: .sparkle,
      status: .upToDate,
      sourceURL: URL(string: "https://example.com/appcast.xml")
    )

    let enriched = snapshot.applying(to: application)

    XCTAssertEqual(enriched.source, .homebrew)
    XCTAssertEqual(enriched.sourceIdentifier, "screendrop")
    XCTAssertEqual(enriched.alternateUpdateSource, .sparkle)
    XCTAssertEqual(enriched.alternateSourceURL, URL(string: "https://example.com/appcast.xml"))
    XCTAssertEqual(enriched.homebrewCaskToken, "screendrop")
  }

  func testKeepsFirstPartyUpdateAvailableWhenBrewHasNoUpdate() throws {
    let info = try JSONDecoder().decode(
      BrewInfoResponse.self,
      from: Data(
        """
        {
          "casks": [
            {
              "token": "screendrop",
              "version": "0.31.3",
              "homepage": "https://example.com/screendrop",
              "url": null,
              "artifacts": [
                {
                  "app": ["Screendrop.app"],
                  "target": "/Applications/Screendrop.app"
                }
              ]
            }
          ]
        }
        """.utf8
      )
    )
    let outdated = try JSONDecoder().decode(
      BrewOutdatedResponse.self,
      from: Data(#"{"casks":[]}"#.utf8)
    )
    let snapshot = HomebrewSnapshot(
      info: info,
      outdated: outdated,
      packageApplicationPaths: [:]
    )
    let application = AppRecord(
      name: "Screendrop",
      bundleIdentifier: "com.fayazahmed.Screendrop",
      applicationURL: URL(fileURLWithPath: "/Applications/Screendrop.app"),
      currentVersion: "0.31.3",
      source: .sparkle,
      status: .updateAvailable,
      latestVersion: "0.32.0",
      sourceURL: URL(string: "https://example.com/appcast.xml")
    )

    let enriched = snapshot.applying(to: application)

    XCTAssertEqual(enriched.source, .sparkle)
    XCTAssertEqual(enriched.latestVersion, "0.32.0")
    XCTAssertEqual(enriched.homebrewCaskToken, "screendrop")
  }

  func testMergesReleaseNotesFromAlternateSourceIntoHomebrewRecord() {
    var homebrew = AppRecord(
      name: "Termio",
      bundleIdentifier: "sh.termio.app",
      applicationURL: URL(fileURLWithPath: "/Applications/termio.app"),
      currentVersion: "0.48.0",
      source: .homebrew,
      status: .upToDate,
      latestVersion: "0.48.0",
      sourceIdentifier: "termio",
      homebrewCaskToken: "termio"
    )
    homebrew.alternateUpdateSource = .sparkle
    homebrew.alternateSourceURL = URL(string: "https://downloads.termio.sh/appcast.xml")

    var checked = homebrew.alternateUpdateCheckRecord!
    checked.status = .upToDate
    checked.latestVersion = "0.48.0"
    checked.releaseNotes = "Termio release notes"
    checked.releaseNotesURL = URL(string: "https://example.com/releases/0.48.0")

    let merged = HomebrewUpdateProvider.mergeAlternateCheckResult(checked, intoHomebrew: homebrew)

    XCTAssertEqual(merged.source, .homebrew)
    XCTAssertEqual(merged.releaseNotes, "Termio release notes")
    XCTAssertEqual(merged.releaseNotesURL, URL(string: "https://example.com/releases/0.48.0"))
    XCTAssertEqual(merged.alternateUpdateSource, .sparkle)
  }

  func testAlternateUpdateWinsWhenBrewIsCurrent() {
    let homebrew = AppRecord(
      name: "Termio",
      bundleIdentifier: "sh.termio.app",
      applicationURL: URL(fileURLWithPath: "/Applications/termio.app"),
      currentVersion: "0.48.0",
      source: .homebrew,
      status: .upToDate,
      latestVersion: "0.48.0",
      sourceIdentifier: "termio",
      homebrewCaskToken: "termio"
    )
    var checked = AppRecord(
      name: "Termio",
      bundleIdentifier: "sh.termio.app",
      applicationURL: URL(fileURLWithPath: "/Applications/termio.app"),
      currentVersion: "0.48.0",
      source: .sparkle,
      status: .updateAvailable,
      latestVersion: "0.49.0",
      sourceURL: URL(string: "https://downloads.termio.sh/appcast.xml"),
      canAutomaticallyUpdate: true
    )
    checked.releaseNotes = "New first-party release"

    let merged = HomebrewUpdateProvider.mergeAlternateCheckResult(checked, intoHomebrew: homebrew)

    XCTAssertEqual(merged.source, .sparkle)
    XCTAssertEqual(merged.latestVersion, "0.49.0")
    XCTAssertEqual(merged.homebrewCaskToken, "termio")
    XCTAssertEqual(merged.releaseNotes, "New first-party release")
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
