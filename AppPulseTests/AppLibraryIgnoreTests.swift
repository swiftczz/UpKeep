import Foundation
import XCTest

@testable import AppPulse

@MainActor
final class AppLibraryIgnoreTests: XCTestCase {
  func testIgnoredUpdateMovesOutOfAvailableUpdatesAndPersists() throws {
    let suiteName = "AppPulseTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let application = makeUpdateApplication()
    let library = AppLibrary(applications: [application], userDefaults: defaults)

    XCTAssertEqual(library.availableUpdates.map(\.id), [application.id])
    XCTAssertFalse(library.isUpdateIgnored(application))

    library.ignoreUpdates(for: application.id)

    XCTAssertTrue(library.availableUpdates.isEmpty)
    XCTAssertTrue(library.isUpdateIgnored(application))
    XCTAssertEqual(library.ignoredApplicationIDs, [application.id])

    let restoredLibrary = AppLibrary(applications: [application], userDefaults: defaults)
    XCTAssertTrue(restoredLibrary.isUpdateIgnored(application))
    XCTAssertTrue(restoredLibrary.availableUpdates.isEmpty)

    restoredLibrary.stopIgnoringUpdates(for: application.id)

    XCTAssertFalse(restoredLibrary.isUpdateIgnored(application))
    XCTAssertEqual(restoredLibrary.availableUpdates.map(\.id), [application.id])
  }

  func testIgnoredHomebrewUpdateIsExcludedFromUpdateAll() throws {
    let suiteName = "AppPulseTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let application = makeUpdateApplication(
      source: .homebrew,
      canAutomaticallyUpdate: true
    )
    let library = AppLibrary(applications: [application], userDefaults: defaults)

    XCTAssertEqual(library.automaticUpdates.map(\.id), [application.id])

    library.ignoreUpdates(for: application.id)

    XCTAssertTrue(library.automaticUpdates.isEmpty)
  }

  private func makeUpdateApplication(
    source: UpdateSource = .appStore,
    canAutomaticallyUpdate: Bool = false
  ) -> AppRecord {
    AppRecord(
      name: "Example",
      bundleIdentifier: "com.example.update",
      applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
      currentVersion: "1.0",
      source: source,
      status: .updateAvailable,
      latestVersion: "2.0",
      canAutomaticallyUpdate: canAutomaticallyUpdate
    )
  }
}
