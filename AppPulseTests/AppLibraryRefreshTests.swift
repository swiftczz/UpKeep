import Foundation
import XCTest

@testable import AppPulse

@MainActor
final class AppLibraryRefreshTests: XCTestCase {
  func testRefreshKeepsPublishedListStableUntilChecksFinish() async throws {
    let suiteName = "AppPulseTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let existingApplication = makeApplication(name: "Existing", status: .upToDate)
    let scannedApplication = makeApplication(name: "Scanned", status: .checking)
    let coordinator = ControlledUpdateCoordinator()
    let library = AppLibrary(
      applications: [existingApplication],
      scanner: StaticApplicationScanner(applications: [scannedApplication]),
      coordinator: coordinator,
      userDefaults: defaults
    )

    let refreshTask = Task { await library.refresh() }
    await coordinator.waitUntilCheckStarts()

    XCTAssertEqual(library.applications, [existingApplication])
    XCTAssertEqual(library.selectedApplicationID, existingApplication.id)
    XCTAssertEqual(library.phase, .checking)

    await coordinator.releaseCheck()
    await refreshTask.value

    XCTAssertEqual(library.applications.map(\.id), [scannedApplication.id])
    XCTAssertEqual(library.applications.first?.status, .upToDate)
    XCTAssertEqual(library.selectedApplicationID, scannedApplication.id)
    XCTAssertEqual(library.phase, .idle)
  }

  private func makeApplication(name: String, status: UpdateStatus) -> AppRecord {
    AppRecord(
      name: name,
      bundleIdentifier: "com.example.\(name.lowercased())",
      applicationURL: URL(fileURLWithPath: "/Applications/\(name).app"),
      currentVersion: "1.0",
      status: status
    )
  }
}

private struct StaticApplicationScanner: ApplicationScanning {
  let applications: [AppRecord]

  func scan() async -> [AppRecord] {
    applications
  }
}

private actor ControlledUpdateCoordinator: UpdateCoordinating {
  private var checkStarted = false
  private var checkReleased = false

  func check(_ applications: [AppRecord]) async -> [AppRecord] {
    checkStarted = true
    while !checkReleased {
      await Task.yield()
    }

    return applications.map { application in
      var application = application
      application.status = .upToDate
      return application
    }
  }

  func update(_ application: AppRecord) async throws {}

  func waitUntilCheckStarts() async {
    while !checkStarted {
      await Task.yield()
    }
  }

  func releaseCheck() {
    checkReleased = true
  }
}
