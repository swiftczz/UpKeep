import Foundation
import XCTest

@testable import AppMint

@MainActor
final class AppLibraryUpdateTests: XCTestCase {
  func testRequiresRelaunchConfirmationWhenUpdatableApplicationIsRunning() throws {
    let application = makeUpdateApplication(name: "Running", bundleIdentifier: "com.example.running")
    let library = try makeLibrary(
      applications: [application],
      runningBundleIdentifiers: ["com.example.running"]
    )

    XCTAssertTrue(library.requiresRelaunchConfirmation(for: application))
    XCTAssertEqual(library.automaticUpdatesRequiringRelaunch().map(\.id), [application.id])
  }

  func testDoesNotRequireRelaunchConfirmationWhenApplicationIsNotRunning() throws {
    let application = makeUpdateApplication(name: "Closed", bundleIdentifier: "com.example.closed")
    let library = try makeLibrary(
      applications: [application],
      runningBundleIdentifiers: []
    )

    XCTAssertFalse(library.requiresRelaunchConfirmation(for: application))
    XCTAssertTrue(library.automaticUpdatesRequiringRelaunch().isEmpty)
  }

  func testDoesNotRequireRelaunchConfirmationWhenPrimaryActionOpensTheApp() throws {
    let application = AppRecord(
      name: "Open",
      bundleIdentifier: "com.example.open",
      applicationURL: URL(fileURLWithPath: "/Applications/Open.app"),
      currentVersion: "1.0",
      source: .sparkle,
      status: .upToDate
    )
    let library = try makeLibrary(
      applications: [application],
      runningBundleIdentifiers: ["com.example.open"]
    )

    XCTAssertFalse(library.requiresRelaunchConfirmation(for: application))
  }

  func testAutomaticUpdatesRequiringRelaunchIgnoresClosedAndIgnoredApps() throws {
    let running = makeUpdateApplication(name: "Running", bundleIdentifier: "com.example.running")
    let closed = makeUpdateApplication(name: "Closed", bundleIdentifier: "com.example.closed")
    let ignored = makeUpdateApplication(name: "Ignored", bundleIdentifier: "com.example.ignored")
    let library = try makeLibrary(
      applications: [running, closed, ignored],
      runningBundleIdentifiers: ["com.example.running", "com.example.ignored"]
    )
    library.ignoreUpdates(for: ignored.id)

    XCTAssertEqual(library.automaticUpdatesRequiringRelaunch().map(\.name), ["Running"])
  }

  private func makeLibrary(
    applications: [AppRecord],
    runningBundleIdentifiers: Set<String>
  ) throws -> AppLibrary {
    let suiteName = "AppMintTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    addTeardownBlock {
      defaults.removePersistentDomain(forName: suiteName)
    }

    return AppLibrary(
      applications: applications,
      process: ApplicationProcessClient(
        isRunning: { runningBundleIdentifiers.contains($0.bundleIdentifier) },
        quit: { _ in },
        launch: { _ in }
      ),
      userDefaults: defaults,
      libraryStore: .memory()
    )
  }

  private func makeUpdateApplication(
    name: String,
    bundleIdentifier: String
  ) -> AppRecord {
    AppRecord(
      name: name,
      bundleIdentifier: bundleIdentifier,
      applicationURL: URL(fileURLWithPath: "/Applications/\(name).app"),
      currentVersion: "1.0",
      source: .sparkle,
      status: .updateAvailable,
      latestVersion: "2.0",
      canAutomaticallyUpdate: true
    )
  }
}
