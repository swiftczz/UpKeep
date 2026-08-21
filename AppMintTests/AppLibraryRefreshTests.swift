import Foundation
import XCTest

@testable import AppMint

@MainActor
final class AppLibraryRefreshTests: XCTestCase {
  func testRestoresCachedApplicationsImmediately() throws {
    let suiteName = "AppMintTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let fileManager = FileManager.default
    let applicationURL = fileManager.temporaryDirectory
      .appendingPathComponent("AppMintCached-\(UUID().uuidString).app", isDirectory: true)
    try fileManager.createDirectory(at: applicationURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: applicationURL) }

    let store = ApplicationLibraryStore.memory()
    let cached = AppRecord(
      name: "Cached",
      bundleIdentifier: "com.example.cached",
      applicationURL: applicationURL,
      currentVersion: "1.0",
      source: .sparkle,
      status: .updateAvailable,
      latestVersion: "2.0",
      sourceURL: URL(string: "https://example.com/appcast.xml")
    )
    store.save(
      ApplicationLibrarySnapshot(lastCheckedAt: Date(timeIntervalSince1970: 1), applications: [cached])
    )

    let library = AppLibrary(
      scanner: StubScanner(applications: []),
      coordinator: StubCoordinator(),
      userDefaults: defaults,
      libraryStore: store
    )

    XCTAssertEqual(library.applications.map(\.name), ["Cached"])
    XCTAssertEqual(library.availableUpdates.map(\.name), ["Cached"])
    XCTAssertEqual(library.selectedApplicationID, cached.id)
    XCTAssertFalse(library.isRefreshing)
  }

  func testPublishesAvailableUpdatesAsEachCheckFinishes() async throws {
    let suiteName = "AppMintTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let fast = makeApplication(name: "Fast", status: .checking)
    let slow = makeApplication(name: "Slow", status: .checking)
    let coordinator = StubCoordinator()
    coordinator.checkHandler = { application in
      if application.name == "Slow" {
        try? await Task.sleep(for: .milliseconds(400))
        return application
      }
      var updated = application
      updated.status = .updateAvailable
      updated.latestVersion = "2.0"
      return updated
    }

    let library = AppLibrary(
      applications: [],
      scanner: StubScanner(applications: [fast, slow]),
      coordinator: coordinator,
      userDefaults: defaults,
      libraryStore: .memory()
    )

    let refresh = Task { await library.refresh() }

    var sawIncrementalUpdate = false
    for _ in 0..<40 {
      try await Task.sleep(for: .milliseconds(25))
      if library.availableUpdates.map(\.name) == ["Fast"],
        library.applications.contains(where: { $0.name == "Slow" && $0.status == .checking })
      {
        sawIncrementalUpdate = true
        break
      }
    }

    await refresh.value
    XCTAssertTrue(sawIncrementalUpdate)
    XCTAssertEqual(library.availableUpdates.map(\.name), ["Fast"])
    XCTAssertEqual(library.phase, .idle)
  }

  func testRefreshIfStaleSkipsWhenRecentlyChecked() async throws {
    let suiteName = "AppMintTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let application = makeApplication(name: "Example", status: .upToDate)
    let scanner = CountingScanner(applications: [application])
    let library = AppLibrary(
      applications: [application],
      scanner: scanner,
      coordinator: StubCoordinator(),
      userDefaults: defaults,
      libraryStore: .memory()
    )
    library.lastCheckedAt = .now

    await library.refreshIfStale(after: 60)

    XCTAssertEqual(scanner.scanCount, 0)
  }

  func testRefreshIfStaleRunsWhenLastCheckIsOld() async throws {
    let suiteName = "AppMintTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let application = makeApplication(name: "Example", status: .upToDate)
    let scanner = CountingScanner(applications: [application])
    let library = AppLibrary(
      applications: [application],
      scanner: scanner,
      coordinator: StubCoordinator(),
      userDefaults: defaults,
      libraryStore: .memory()
    )
    library.lastCheckedAt = Date.now.addingTimeInterval(-120)

    await library.refreshIfStale(after: 60)

    XCTAssertEqual(scanner.scanCount, 1)
  }

  private func makeApplication(
    name: String,
    status: UpdateStatus,
    latestVersion: String? = nil
  ) -> AppRecord {
    AppRecord(
      name: name,
      bundleIdentifier: "com.example.\(name.lowercased())",
      applicationURL: URL(fileURLWithPath: "/Applications/\(name).app"),
      currentVersion: "1.0",
      source: .sparkle,
      status: status,
      latestVersion: latestVersion,
      sourceURL: URL(string: "https://example.com/appcast.xml")
    )
  }
}

private struct StubScanner: ApplicationScanning {
  let applications: [AppRecord]

  func scan() async -> [AppRecord] {
    applications
  }
}

private final class CountingScanner: ApplicationScanning, @unchecked Sendable {
  var applications: [AppRecord]
  private(set) var scanCount = 0

  init(applications: [AppRecord]) {
    self.applications = applications
  }

  func scan() async -> [AppRecord] {
    scanCount += 1
    return applications
  }
}

private final class StubCoordinator: UpdateCoordinating, @unchecked Sendable {
  var checkHandler: (@Sendable (AppRecord) async -> AppRecord)?

  func enrich(_ applications: [AppRecord]) async -> [AppRecord] {
    applications
  }

  func check(_ application: AppRecord) async -> AppRecord {
    if let checkHandler {
      return await checkHandler(application)
    }
    return application
  }

  func update(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {}
}
