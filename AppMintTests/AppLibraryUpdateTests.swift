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

  func testIPhoneAppStoreUpdateOpensItsStorePage() async throws {
    let application = AppRecord(
      name: "Minis",
      bundleIdentifier: "com.openminis.app",
      applicationURL: URL(fileURLWithPath: "/Applications/Minis.app"),
      currentVersion: "1.12",
      source: .appStore,
      appStorePlatform: .iPhone,
      status: .updateAvailable,
      latestVersion: "1.13",
      sourceURL: URL(string: "https://apps.apple.com/cn/app/minis/id123456789"),
      canAutomaticallyUpdate: false
    )
    let library = try makeLibrary(applications: [application], runningBundleIdentifiers: [])

    let destination = await library.performPrimaryAction(for: application.id)

    XCTAssertEqual(destination?.scheme, "macappstore")
    XCTAssertEqual(destination?.host, "apps.apple.com")
    XCTAssertEqual(destination?.path, "/cn/app/minis/id123456789")
    XCTAssertTrue(library.automaticUpdates.isEmpty)
  }

  func testFailedUpdateKeepsOriginalSelectionAndReportsFailureAfterRefresh() async throws {
    let eudic = makeUpdateApplication(
      name: "欧路词典",
      bundleIdentifier: "com.eusoft.eudic"
    )
    let tencent = makeUpdateApplication(
      name: "腾讯视频",
      bundleIdentifier: "com.tencent.tenvideo"
    )
    let suiteName = "AppMintTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let library = AppLibrary(
      applications: [eudic, tencent],
      scanner: UpdateSelectionScanner(applications: [tencent, eudic]),
      coordinator: FailingUpdateCoordinator(),
      userDefaults: defaults,
      libraryStore: .memory()
    )
    library.selectedApplicationID = eudic.id

    _ = await library.performPrimaryAction(for: eudic.id)

    XCTAssertEqual(library.selectedApplicationID, eudic.id)
    XCTAssertEqual(library.selectedApplication?.name, "欧路词典")
    XCTAssertEqual(library.alertMessage, "模拟更新失败")
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

private struct UpdateSelectionScanner: ApplicationScanning {
  let applications: [AppRecord]

  func scan() async -> [AppRecord] {
    applications
  }
}

private struct FailingUpdateCoordinator: UpdateCoordinating {
  func enrich(_ applications: [AppRecord]) async -> [AppRecord] {
    applications
  }

  func check(_ application: AppRecord) async -> AppRecord {
    application
  }

  func update(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    throw ProcessRunnerError.failed(status: 1, message: "模拟更新失败")
  }
}
