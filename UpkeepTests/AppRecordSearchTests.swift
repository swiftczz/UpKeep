import Foundation
import XCTest

@testable import Upkeep

final class AppRecordSearchTests: XCTestCase {
  func testMatchesApplicationNameAndBundleIdentifier() {
    let application = makeApplication(name: "Example", bundleIdentifier: "com.acme.desktop")

    XCTAssertTrue(application.matchesSearch("example"))
    XCTAssertTrue(application.matchesSearch("ACME.DESKTOP"))
  }

  func testMatchesUpdateSourceCaseInsensitively() {
    let homebrew = makeApplication(source: .homebrew)
    let sparkle = makeApplication(source: .sparkle)

    XCTAssertTrue(homebrew.matchesSearch("HoMeBrEw"))
    XCTAssertTrue(sparkle.matchesSearch("SPARKLE"))
  }

  func testExplicitSourceQueryDoesNotMatchAnotherSourcesBundleIdentifier() {
    let ollama = makeApplication(
      name: "Ollama",
      bundleIdentifier: "com.electron.ollama",
      source: .homebrew
    )
    let electronApplication = makeApplication(
      name: "Electron Application",
      bundleIdentifier: "com.example.desktop",
      source: .electronBuilder
    )

    XCTAssertFalse(ollama.matchesSearch("electron"))
    XCTAssertTrue(electronApplication.matchesSearch("electron"))
    XCTAssertFalse(ollama.matchesSearch("elect"))
    XCTAssertTrue(electronApplication.matchesSearch("elect"))
  }

  func testOrdinaryQueryStillMatchesBundleIdentifier() {
    let application = makeApplication(bundleIdentifier: "com.example.special-channel")

    XCTAssertTrue(application.matchesSearch("special"))
  }

  func testMatchesPlatformSpecificAppStoreTitle() {
    let application = makeApplication(source: .appStore, appStorePlatform: .mac)

    XCTAssertTrue(application.matchesSearch("mac app store"))
  }

  func testMatchesLocalizedUnknownSourceAndTrimsWhitespace() {
    let application = makeApplication(source: .selfManaged)

    XCTAssertTrue(application.matchesSearch("  未知  "))
  }

  func testRejectsUnrelatedSearchText() {
    let application = makeApplication(source: .homebrew)

    XCTAssertFalse(application.matchesSearch("Sparkle"))
  }

  func testMatchesRecordedInstallationChannelWhenCheckChannelDiffers() {
    var application = makeApplication(source: .sparkle)
    application.installedSource = .homebrew

    XCTAssertEqual(application.sourceTitle, "Homebrew")
    XCTAssertEqual(application.sourceSystemImage, UpdateSource.homebrew.systemImage)
    XCTAssertTrue(application.matchesSearch("homebrew"))
  }

  func testAvailableUpdateDisplaysTheCurrentChannelInsteadOfTheInstalledChannel() {
    for source in UpdateSource.allCases where source != .selfManaged {
      var application = makeApplication(source: source)
      application.installedSource = source == .homebrew ? .sparkle : .homebrew
      application.status = .updateAvailable
      application.latestVersion = "2.0"

      XCTAssertEqual(application.displayedSource, source)
      XCTAssertEqual(application.sourceTitle, source.title)
      XCTAssertEqual(application.sourceSystemImage, source.systemImage)
    }
  }

  func testKnownUpdateKeepsItsActualChannelWhileCheckingOrAfterATemporaryFailure() {
    var application = makeApplication(source: .sparkle)
    application.installedSource = .homebrew
    application.latestVersion = "2.0"
    for status in [UpdateStatus.checking, .unavailable("暂时无法访问更新源")] {
      application.status = status

      XCTAssertTrue(application.needsUpdate)
      XCTAssertEqual(application.sourceTitle, "Sparkle")
      XCTAssertEqual(application.sourceSystemImage, UpdateSource.sparkle.systemImage)
    }
  }

  func testSourceSearchMatchesTheDisplayedAvailableUpdateChannel() {
    var application = makeApplication(source: .sparkle)
    application.installedSource = .homebrew
    application.status = .updateAvailable
    application.latestVersion = "2.0"

    XCTAssertTrue(application.matchesSearch("Sparkle"))
    XCTAssertFalse(application.matchesSearch("Homebrew"))
    application.applyInstalledRelease()
    XCTAssertEqual(application.sourceTitle, "Homebrew")
    XCTAssertTrue(application.matchesSearch("Homebrew"))
  }

  func testOldSnapshotDoesNotInferUpdateChannelFromInstallationDate() throws {
    var application = makeApplication(source: .sparkle)
    application.lastInstalledAt = .now
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(application)) as? [String: Any]
    )
    object.removeValue(forKey: "installedSource")
    let restored = try JSONDecoder().decode(
      AppRecord.self, from: JSONSerialization.data(withJSONObject: object)
    )

    XCTAssertNil(restored.installedSource)
    XCTAssertEqual(restored.sourceTitle, "Sparkle")
  }

  private func makeApplication(
    name: String = "Example",
    bundleIdentifier: String = "com.example.app",
    source: UpdateSource = .selfManaged,
    appStorePlatform: AppStorePlatform? = nil
  ) -> AppRecord {
    AppRecord(
      name: name,
      bundleIdentifier: bundleIdentifier,
      applicationURL: URL(fileURLWithPath: "/Applications/\(name).app"),
      currentVersion: "1.0",
      source: source,
      appStorePlatform: appStorePlatform,
      status: .upToDate
    )
  }
}
