import Foundation
import XCTest

@testable import Upkeep

@MainActor
final class AppLibraryIgnoreTests: XCTestCase {
  func testIgnoredUpdateMovesOutOfAvailableUpdatesAndPersists() throws {
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let application = makeUpdateApplication()
    let library = AppLibrary(
      applications: [application], userDefaults: defaults,
      libraryStore: .memory())

    XCTAssertEqual(library.availableUpdates.map(\.id), [application.id])
    XCTAssertFalse(library.isUpdateIgnored(application))

    library.ignoreUpdates(for: application.id)

    XCTAssertTrue(library.availableUpdates.isEmpty)
    XCTAssertTrue(library.isUpdateIgnored(application))
    XCTAssertEqual(library.ignoredApplicationIDs, [application.id])
    XCTAssertEqual(library.ignoredUpdates.map(\.id), [application.id])

    let restoredLibrary = AppLibrary(
      applications: [application], userDefaults: defaults,
      libraryStore: .memory())
    XCTAssertTrue(restoredLibrary.isUpdateIgnored(application))
    XCTAssertTrue(restoredLibrary.availableUpdates.isEmpty)

    restoredLibrary.stopIgnoringUpdates(for: application.id)

    XCTAssertFalse(restoredLibrary.isUpdateIgnored(application))
    XCTAssertTrue(restoredLibrary.ignoredUpdates.isEmpty)
    XCTAssertEqual(restoredLibrary.availableUpdates.map(\.id), [application.id])
  }

  func testCanIgnoreInstalledApplicationBeforeAnUpdateIsAvailable() throws {
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var application = makeUpdateApplication(mechanism: .sparkle, canAutomaticallyUpdate: true)
    application.status = .upToDate
    application.latestVersion = nil
    let library = AppLibrary(
      applications: [application], userDefaults: defaults,
      libraryStore: .memory())

    library.ignoreUpdates(for: application.id)

    XCTAssertTrue(library.isUpdateIgnored(application))
    XCTAssertTrue(library.sidebarSections.installedApplications.isEmpty)
    XCTAssertEqual(library.sidebarSections.ignoredUpdates.map(\.id), [application.id])
    XCTAssertEqual(library.sidebarSections.ignoredApplicationIDs, [application.id])

    let restored = AppLibrary(
      applications: [application], userDefaults: defaults,
      libraryStore: .memory())
    XCTAssertTrue(restored.isUpdateIgnored(application))
    XCTAssertEqual(restored.sidebarSections.ignoredUpdates.map(\.id), [application.id])
    XCTAssertTrue(restored.sidebarSections.installedApplications.isEmpty)
    restored.applications[0].latestVersion = "2.0"
    restored.applications[0].status = .updateAvailable
    XCTAssertTrue(restored.availableUpdates.isEmpty)
    XCTAssertTrue(restored.automaticUpdates.isEmpty)
    XCTAssertEqual(restored.ignoredUpdates.map(\.id), [application.id])

    restored.stopIgnoringUpdates(for: application.id)
    XCTAssertEqual(restored.availableUpdates.map(\.id), [application.id])
    XCTAssertEqual(restored.automaticUpdates.map(\.id), [application.id])
  }

  func testCanCancelIgnoreAfterPendingReleaseIsDiscarded() throws {
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let application = makeUpdateApplication(mechanism: .selfManaged)
    let library = AppLibrary(
      applications: [application], userDefaults: defaults,
      libraryStore: .memory())
    library.ignoreUpdates(for: application.id)

    library.applications[0].discardRemoteRelease()

    XCTAssertTrue(library.sidebarSections.installedApplications.isEmpty)
    XCTAssertEqual(library.sidebarSections.ignoredUpdates.map(\.id), [application.id])
    XCTAssertEqual(library.sidebarSections.ignoredApplicationIDs, [application.id])
    library.stopIgnoringUpdates(for: application.id)
    XCTAssertTrue(library.sidebarSections.ignoredApplicationIDs.isEmpty)
    XCTAssertTrue(library.sidebarSections.ignoredUpdates.isEmpty)
    XCTAssertEqual(library.sidebarSections.installedApplications.map(\.id), [application.id])
    let restored = AppLibrary(
      applications: library.applications, userDefaults: defaults,
      libraryStore: .memory())
    XCTAssertFalse(restored.isUpdateIgnored(application))
  }

  func testForgetUninstalledRemovesApplicationAndReselects() throws {
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let first = makeUpdateApplication(
      name: "First",
      bundleIdentifier: "com.example.first",
      releaseDate: Date(timeIntervalSince1970: 200)
    )
    let second = makeUpdateApplication(
      name: "Second",
      bundleIdentifier: "com.example.second",
      releaseDate: Date(timeIntervalSince1970: 100)
    )
    let library = AppLibrary(
      applications: [first, second], userDefaults: defaults,
      libraryStore: .memory())
    XCTAssertEqual(library.selectedApplicationID, first.id)

    library.forgetUninstalled(first)

    XCTAssertEqual(library.applications.map(\.id), [second.id])
    XCTAssertEqual(library.selectedApplicationID, second.id)
  }

  func testAvailableUpdatesAreSortedByReleaseDateDescending() throws {
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let older = makeUpdateApplication(
      name: "Older",
      bundleIdentifier: "com.example.older",
      releaseDate: Date(timeIntervalSince1970: 100)
    )
    let newer = makeUpdateApplication(
      name: "Newer",
      bundleIdentifier: "com.example.newer",
      releaseDate: Date(timeIntervalSince1970: 200)
    )
    let library = AppLibrary(
      applications: [older, newer], userDefaults: defaults,
      libraryStore: .memory())

    XCTAssertEqual(library.availableUpdates.map(\.name), ["Newer", "Older"])
    XCTAssertEqual(library.selectedApplicationID, newer.id)
  }

  func testIgnoredHomebrewUpdateIsExcludedFromUpdateAll() throws {
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let application = makeUpdateApplication(
      mechanism: .homebrew,
      canAutomaticallyUpdate: true
    )
    let library = AppLibrary(
      applications: [application], userDefaults: defaults,
      libraryStore: .memory())

    XCTAssertEqual(library.automaticUpdates.map(\.id), [application.id])

    library.ignoreUpdates(for: application.id)

    XCTAssertTrue(library.automaticUpdates.isEmpty)
  }

  private func makeUpdateApplication(
    name: String = "Example",
    bundleIdentifier: String = "com.example.update",
    mechanism: UpdateMechanism = .appStore,
    canAutomaticallyUpdate: Bool = false,
    releaseDate: Date? = nil
  ) -> AppRecord {
    AppRecord(
      name: name,
      bundleIdentifier: bundleIdentifier,
      applicationURL: URL(fileURLWithPath: "/Applications/\(name).app"),
      currentVersion: "1.0",
      updateConfiguration: UpdateConfiguration(mechanism: mechanism),
      status: .updateAvailable,
      latestVersion: "2.0",
      releaseDate: releaseDate,
      canAutomaticallyUpdate: canAutomaticallyUpdate
    )
  }
}
