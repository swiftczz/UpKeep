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
