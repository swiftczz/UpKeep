import Foundation
import XCTest

@testable import Upkeep

@MainActor
final class InstalledReleaseIdentityTests: XCTestCase {
  func testFullScanDoesNotCarryOldReleaseAfterVersionNumberingRestarts() throws {
    let merged = try XCTUnwrap(
      AppLibrary.mergeKeepingCheckResults(
        [newEdition()], previous: [oldEdition()]
      ).first)
    assertNoOldRelease(merged)
    XCTAssertNil(merged.updateConfiguration.feedURL)
  }

  func testInstalledApplicationMonitorDoesNotRestoreTheOldUpdaterAfterVersionReset() throws {
    let merged = try XCTUnwrap(
      AppLibrary.mergeInstalledApplicationChanges(
        [newEdition()], previous: [oldEdition()]
      ).first)
    assertNoOldRelease(merged)
    XCTAssertNil(merged.updateConfiguration.feedURL)
    XCTAssertNotNil(merged.lastInstalledAt)
  }

  func testCoalescingDoesNotReintroduceReleaseFromThePreviousEdition() {
    let merged = AppLibrary.coalesceCheckResult(newEdition(), over: oldEdition())
    assertNoOldRelease(merged)
  }

  func testAlreadyOrphanedCachedUpdateIsClearedByRescanAndCoalescing() throws {
    var orphan = newEdition()
    orphan.status = .updateAvailable
    orphan.latestVersion = "1.0.17"
    orphan.latestBuildVersion = "1.0.17"
    orphan.releaseNotes = "Old edition's release notes"
    let scanned = try XCTUnwrap(
      AppLibrary.mergeKeepingCheckResults([orphan], previous: [orphan]).first)
    assertNoOldRelease(scanned)
    assertNoOldRelease(AppLibrary.coalesceCheckResult(orphan, over: orphan))
  }

  func testCurrentSnapshotMigrationClearsUnverifiableRemoteReleaseWithoutChangingInstalledVersion()
    throws
  {
    var orphan = newEdition()
    orphan.status = .updateAvailable
    orphan.latestVersion = "1.0.17"
    orphan.latestBuildVersion = "1.0.17"
    var snapshot = ApplicationLibrarySnapshot(applications: [orphan, oldEdition()])
    snapshot = try JSONDecoder().decode(
      ApplicationLibrarySnapshot.self, from: JSONEncoder().encode(snapshot))
    snapshot.migrateReleaseMetadataIfNeeded()
    assertNoOldRelease(snapshot.applications[0])
    XCTAssertEqual(snapshot.applications[0].currentVersion, "0.1.16")
    XCTAssertEqual(snapshot.applications[1].latestVersion, "1.0.17")
    XCTAssertEqual(snapshot.applications[1].releaseNotes, oldEdition().releaseNotes)
  }

  func testForwardVersionWithANewDetectedUpdaterDoesNotInheritOldPendingRelease() throws {
    var previous = oldEdition()
    previous.latestVersion = "3.0.0"
    var current = newEdition()
    current.currentVersion = "1.1.0"
    current.updateConfiguration.mechanism = .tauri
    current.updateConfiguration.feedURL = URL(string: "https://example.com/new-edition/latest.json")
    current.status = .checking

    let merged = try XCTUnwrap(
      AppLibrary.mergeKeepingCheckResults([current], previous: [previous]).first)
    XCTAssertEqual(merged.updateConfiguration.mechanism, .tauri)
    XCTAssertEqual(merged.status, .checking)
    XCTAssertNil(merged.latestVersion)
    XCTAssertNil(merged.releaseNotes)
  }

  func testDifferentApplicationAtTheSamePathDoesNotInheritRelease() throws {
    let current = AppRecord(
      name: "Replacement",
      bundleIdentifier: "com.example.replacement",
      applicationURL: oldEdition().applicationURL,
      currentVersion: "0.1.16",
      updateConfiguration: UpdateConfiguration(mechanism: .selfManaged),
      status: .selfManaged
    )
    let merged = try XCTUnwrap(
      AppLibrary.mergeKeepingCheckResults([current], previous: [oldEdition()]).first)
    XCTAssertNil(merged.latestVersion)
    XCTAssertNil(merged.releaseNotes)
    XCTAssertEqual(merged.bundleIdentifier, current.bundleIdentifier)
  }

  func testNormalForwardInstallationRetainsAnUninstalledNewerRelease() throws {
    var previous = oldEdition()
    previous.latestVersion = "2.0.0"
    previous.latestBuildVersion = "2.0.0"
    var current = previous
    current.currentVersion = "1.5.0"
    current.buildVersion = "1.5.0"
    current.latestVersion = nil
    current.status = .checking

    let merged = try XCTUnwrap(
      AppLibrary.mergeKeepingCheckResults([current], previous: [previous]).first)
    XCTAssertEqual(merged.latestVersion, "2.0.0")
    XCTAssertEqual(merged.status, .updateAvailable)
  }

  func testTemporaryFailureForUnchangedInstalledVersionKeepsVerifiedRelease() {
    let previous = oldEdition()
    var failed = previous
    failed.status = .unavailable("网络暂时不可用")
    failed.latestVersion = nil
    let merged = AppLibrary.coalesceCheckResult(failed, over: previous)
    XCTAssertEqual(merged.latestVersion, "1.0.17")
    XCTAssertEqual(merged.updateConfiguration.feedURL, previous.updateConfiguration.feedURL)
    XCTAssertEqual(merged.status, .updateAvailable)
  }

  private func oldEdition() -> AppRecord {
    AppRecord(
      name: "Lorca",
      bundleIdentifier: "app.lorca",
      applicationURL: URL(fileURLWithPath: "/Applications/Lorca.app"),
      currentVersion: "1.0.16",
      buildVersion: "1.0.16",
      updateConfiguration: UpdateConfiguration(
        mechanism: .sparkle, feedURL: URL(string: "https://mac-releases.lorca.app/appcast.xml")),
      status: .updateAvailable,
      latestVersion: "1.0.17",
      latestBuildVersion: "1.0.17",
      releaseNotes: "Old edition's release notes",
      canAutomaticallyUpdate: true
    )
  }

  private func newEdition() -> AppRecord {
    AppRecord(
      name: "Lorca",
      bundleIdentifier: "app.lorca",
      applicationURL: URL(fileURLWithPath: "/Applications/Lorca.app"),
      currentVersion: "0.1.16",
      buildVersion: "0.1.16",
      updateConfiguration: UpdateConfiguration(mechanism: .selfManaged),
      status: .selfManaged
    )
  }

  private func assertNoOldRelease(
    _ application: AppRecord, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(application.updateConfiguration.mechanism, .selfManaged, file: file, line: line)
    XCTAssertEqual(application.status, .selfManaged, file: file, line: line)
    XCTAssertNil(application.latestVersion, file: file, line: line)
    XCTAssertNil(application.latestBuildVersion, file: file, line: line)
    XCTAssertNil(application.releaseNotes, file: file, line: line)
    XCTAssertFalse(application.canAutomaticallyUpdate, file: file, line: line)
    XCTAssertFalse(application.needsUpdate, file: file, line: line)
  }
}
