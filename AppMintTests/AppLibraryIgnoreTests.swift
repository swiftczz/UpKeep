import Foundation
import XCTest

@testable import AppMint

@MainActor
final class AppLibraryIgnoreTests: XCTestCase {
  func testIgnoredUpdateMovesOutOfAvailableUpdatesAndPersists() throws {
    let suiteName = "AppMintTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let application = makeUpdateApplication()
    let library = AppLibrary(applications: [application], userDefaults: defaults,
      libraryStore: .memory())

    XCTAssertEqual(library.availableUpdates.map(\.id), [application.id])
    XCTAssertFalse(library.isUpdateIgnored(application))

    library.ignoreUpdates(for: application.id)

    XCTAssertTrue(library.availableUpdates.isEmpty)
    XCTAssertTrue(library.isUpdateIgnored(application))
    XCTAssertEqual(library.ignoredApplicationIDs, [application.id])
    XCTAssertEqual(library.ignoredUpdates.map(\.id), [application.id])

    let restoredLibrary = AppLibrary(applications: [application], userDefaults: defaults,
      libraryStore: .memory())
    XCTAssertTrue(restoredLibrary.isUpdateIgnored(application))
    XCTAssertTrue(restoredLibrary.availableUpdates.isEmpty)

    restoredLibrary.stopIgnoringUpdates(for: application.id)

    XCTAssertFalse(restoredLibrary.isUpdateIgnored(application))
    XCTAssertTrue(restoredLibrary.ignoredUpdates.isEmpty)
    XCTAssertEqual(restoredLibrary.availableUpdates.map(\.id), [application.id])
  }

  func testForgetUninstalledRemovesApplicationAndReselects() throws {
    let suiteName = "AppMintTests.\(UUID().uuidString)"
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
    let library = AppLibrary(applications: [first, second], userDefaults: defaults,
      libraryStore: .memory())
    XCTAssertEqual(library.selectedApplicationID, first.id)

    library.forgetUninstalled(first)

    XCTAssertEqual(library.applications.map(\.id), [second.id])
    XCTAssertEqual(library.selectedApplicationID, second.id)
  }

  func testAvailableUpdatesAreSortedByReleaseDateDescending() throws {
    let suiteName = "AppMintTests.\(UUID().uuidString)"
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
    let library = AppLibrary(applications: [older, newer], userDefaults: defaults,
      libraryStore: .memory())

    XCTAssertEqual(library.availableUpdates.map(\.name), ["Newer", "Older"])
    XCTAssertEqual(library.selectedApplicationID, newer.id)
  }

  func testIgnoredHomebrewUpdateIsExcludedFromUpdateAll() throws {
    let suiteName = "AppMintTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let application = makeUpdateApplication(
      source: .homebrew,
      canAutomaticallyUpdate: true
    )
    let library = AppLibrary(applications: [application], userDefaults: defaults,
      libraryStore: .memory())

    XCTAssertEqual(library.automaticUpdates.map(\.id), [application.id])

    library.ignoreUpdates(for: application.id)

    XCTAssertTrue(library.automaticUpdates.isEmpty)
  }

  private func makeUpdateApplication(
    name: String = "Example",
    bundleIdentifier: String = "com.example.update",
    source: UpdateSource = .appStore,
    canAutomaticallyUpdate: Bool = false,
    releaseDate: Date? = nil
  ) -> AppRecord {
    AppRecord(
      name: name,
      bundleIdentifier: bundleIdentifier,
      applicationURL: URL(fileURLWithPath: "/Applications/\(name).app"),
      currentVersion: "1.0",
      source: source,
      status: .updateAvailable,
      latestVersion: "2.0",
      releaseDate: releaseDate,
      canAutomaticallyUpdate: canAutomaticallyUpdate
    )
  }
}
