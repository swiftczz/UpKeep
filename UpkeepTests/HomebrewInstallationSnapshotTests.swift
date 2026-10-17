import Foundation
import XCTest

@testable import Upkeep

final class HomebrewInstallationSnapshotTests: XCTestCase {
  func testMatchingReceiptIdentifiesExternalBrewUpdateWithoutChangingCheckChannel() throws {
    let fixture = try makeFixture()
    var application = fixture.application
    application.latestVersion = "3.0"
    application.status = .updateAvailable
    let checked = fixture.snapshot.applying(to: application)

    XCTAssertEqual(checked.installedSource, .homebrew)
    XCTAssertEqual(checked.sourceTitle, "Homebrew")
    XCTAssertEqual(checked.source, .sparkle)
    XCTAssertEqual(checked.homebrewCaskToken, "example")
    XCTAssertEqual(checked.lastInstalledAt, fixture.date)
    XCTAssertTrue(checked.needsUpdate)
    XCTAssertEqual(checked.latestVersion, "3.0")
  }

  func testReceiptForOlderVersionDoesNotClaimNativeUpdate() throws {
    let fixture = try makeFixture()
    var application = fixture.application
    application.currentVersion = "3.0"
    let checked = fixture.snapshot.applying(to: application)

    XCTAssertNil(checked.installedSource)
    XCTAssertEqual(checked.sourceTitle, "Sparkle")
    XCTAssertEqual(checked.homebrewCaskToken, "example")
  }

  func testOldReceiptDoesNotOverrideLaterSuccessfulNativeUpdate() throws {
    let fixture = try makeFixture()
    var application = fixture.application
    application.installedSource = .sparkle
    application.lastInstalledAt = fixture.date.addingTimeInterval(60)

    XCTAssertEqual(fixture.snapshot.applying(to: application).installedSource, .sparkle)
  }

  func testNewBrewReceiptReplacesPreviouslyRecordedNativeChannel() throws {
    let fixture = try makeFixture()
    var application = fixture.application
    application.installedSource = .sparkle
    application.lastInstalledAt = fixture.date.addingTimeInterval(-60)

    XCTAssertEqual(fixture.snapshot.applying(to: application).installedSource, .homebrew)
  }

  func testApplicationReplacementAfterReceiptDoesNotClaimBrew() throws {
    let fixture = try makeFixture()
    try FileManager.default.setAttributes(
      [.modificationDate: fixture.date.addingTimeInterval(60)],
      ofItemAtPath: fixture.application.applicationURL.path
    )

    XCTAssertNil(fixture.snapshot.applying(to: fixture.application).installedSource)
  }

  func testAppStoreReceiptRemainsAppStore() throws {
    let fixture = try makeFixture()
    var application = fixture.application
    application.source = .appStore

    XCTAssertNil(fixture.snapshot.applying(to: application).installedSource)
    XCTAssertEqual(fixture.snapshot.applying(to: application).sourceTitle, "App Store")
  }

  @MainActor
  func testLocalRefreshRecordsBrewUpdateWithoutCheckingRemoteSources() async throws {
    let fixture = try makeFixture()
    var old = fixture.application
    old.currentVersion = "1.0"
    old.status = .updateAvailable
    old.latestVersion = "2.0"
    old.installedSource = .sparkle
    let library = AppLibrary(
      applications: [old],
      scanner: ReceiptScanner(application: fixture.snapshot.applying(to: fixture.application)),
      coordinator: NoRemoteChecks(),
      userDefaults: UserDefaults(suiteName: "UpkeepTests.\(UUID().uuidString)")!,
      libraryStore: .memory()
    )

    await library.refreshInstalledApplications()

    XCTAssertEqual(library.applications.first?.currentVersion, "2.0")
    XCTAssertEqual(library.applications.first?.sourceTitle, "Homebrew")
    XCTAssertEqual(library.applications.first?.installedSource, .homebrew)
    XCTAssertTrue(library.availableUpdates.isEmpty)
  }

  private func makeFixture() throws -> (
    application: AppRecord, snapshot: HomebrewInstallationSnapshot, date: Date
  ) {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("UpkeepTests-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let applicationURL = root.appendingPathComponent("Applications/Example.app")
    let contents = applicationURL.appendingPathComponent("Contents")
    let caskroom = root.appendingPathComponent("Caskroom")
    let cask = caskroom.appendingPathComponent("example")
    try fileManager.createDirectory(at: contents, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: cask.appendingPathComponent(".metadata"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: cask.appendingPathComponent("2.0"), withIntermediateDirectories: true)
    let info: [String: String] = [
      "CFBundleIdentifier": "com.example.receipt", "CFBundleName": "Example",
      "CFBundleShortVersionString": "2.0", "CFBundlePackageType": "APPL",
      "SUFeedURL": "https://example.com/appcast.xml",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: contents.appendingPathComponent("Info.plist"))
    let date = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970) + 10)
    try JSONSerialization.data(withJSONObject: ["time": date.timeIntervalSince1970, "source": ["version": "2.0"]])
      .write(to: cask.appendingPathComponent(".metadata/INSTALL_RECEIPT.json"))
    try fileManager.createSymbolicLink(
      at: cask.appendingPathComponent("2.0/Example.app"), withDestinationURL: applicationURL
    )
    return (
      try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL)),
      HomebrewInstallationSnapshot(caskroomURLs: [caskroom]), date
    )
  }
}

private struct ReceiptScanner: ApplicationScanning {
  let application: AppRecord
  func scan() async -> [AppRecord] { [application] }
}

private struct NoRemoteChecks: UpdateCoordinating {
  func enrich(_ applications: [AppRecord]) async -> [AppRecord] {
    XCTFail("Local installation refresh must not perform Homebrew update checks")
    return applications
  }
  func check(_ application: AppRecord) async -> AppRecord {
    XCTFail("Local installation refresh must not perform remote update checks")
    return application
  }
  func update(_ application: AppRecord, progress: @escaping @Sendable (UpdateProgress) -> Void) async throws {
    XCTFail("Local installation refresh must not install applications")
  }
}
