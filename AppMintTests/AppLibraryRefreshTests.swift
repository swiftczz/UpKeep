import Foundation
import XCTest

@testable import AppMint

extension ApplicationLibraryStore {
  static func memory() -> ApplicationLibraryStore {
    let box = TestSnapshotBox()
    return ApplicationLibraryStore(
      load: { box.snapshot },
      save: { box.snapshot = $0 }
    )
  }
}

private final class TestSnapshotBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: ApplicationLibrarySnapshot?

  var snapshot: ApplicationLibrarySnapshot? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
    set {
      lock.lock()
      storage = newValue
      lock.unlock()
    }
  }
}

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
      ApplicationLibrarySnapshot(
        lastCheckedAt: Date(timeIntervalSince1970: 1),
        applications: [cached]
      )
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
        XCTAssertEqual(library.checkingApplicationIDs, [slow.id])
        sawIncrementalUpdate = true
        break
      }
    }

    await refresh.value
    XCTAssertTrue(sawIncrementalUpdate)
    XCTAssertEqual(library.availableUpdates.map(\.name), ["Fast"])
    XCTAssertTrue(library.checkingApplicationIDs.isEmpty)
    XCTAssertEqual(library.phase, .idle)
  }

  func testRefreshLimitsConcurrentUpdateChecks() async throws {
    let suiteName = "AppMintTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let applications = (0..<24).map {
      makeApplication(name: "Application \($0)", status: .checking)
    }
    let probe = CheckConcurrencyProbe()
    let library = AppLibrary(
      applications: [],
      scanner: StubScanner(applications: applications),
      coordinator: ConcurrencyTrackingCoordinator(probe: probe),
      userDefaults: defaults,
      libraryStore: .memory()
    )

    await library.refresh()

    let observation = await probe.observation
    XCTAssertEqual(observation.maximum, 10)
    XCTAssertEqual(observation.current, 0)
    XCTAssertTrue(library.checkingApplicationIDs.isEmpty)
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

  func testMergeKeepsKnownUpdateWhenScanReturnsChecking() {
    let previous = makeApplication(name: "Example", status: .updateAvailable, latestVersion: "2.0")
    let scanned = makeApplication(name: "Example", status: .checking)

    let merged = AppLibrary.mergeKeepingCheckResults([scanned], previous: [previous])

    XCTAssertEqual(merged.first?.status, .updateAvailable)
    XCTAssertEqual(merged.first?.latestVersion, "2.0")
    XCTAssertEqual(merged.availableUpdates(ignoredIDs: []).map(\.name), ["Example"])
  }

  func testMergeDoesNotReuseHomebrewHomepageAsSparkleFeed() {
    var previous = makeApplication(
      name: "Thunder",
      status: .updateAvailable,
      latestVersion: "5.80.7.66659"
    )
    previous.source = .homebrew
    previous.sourceURL = URL(string: "https://www.xunlei.com/")
    previous.canAutomaticallyUpdate = true

    var scanned = makeApplication(name: "Thunder", status: .selfManaged)
    scanned.source = .sparkle
    scanned.sourceURL = nil

    let merged = AppLibrary.mergeKeepingCheckResults([scanned], previous: [previous])

    XCTAssertNil(merged.first?.sourceURL)
    XCTAssertEqual(merged.first?.source, .sparkle)
    XCTAssertEqual(merged.first?.status, .updateAvailable)
    XCTAssertEqual(merged.first?.latestVersion, "5.80.7.66659")
    XCTAssertEqual(merged.availableUpdates(ignoredIDs: []).map(\.name), ["Thunder"])
    XCTAssertEqual(merged.first?.canAutomaticallyUpdate, false)
  }

  func testMergeKeepsLastInstalledAtAcrossRescan() {
    let installedAt = Date(timeIntervalSince1970: 1_777_000_000)
    var previous = makeApplication(name: "Example", status: .upToDate)
    previous.lastInstalledAt = installedAt
    let scanned = makeApplication(name: "Example", status: .checking)

    let merged = AppLibrary.mergeKeepingCheckResults([scanned], previous: [previous])

    XCTAssertEqual(merged.first?.lastInstalledAt, installedAt)
  }

  func testMergeKeepsLastInstalledAtForHomebrewUpdate() {
    let installedAt = Date(timeIntervalSince1970: 1_777_000_000)
    var previous = makeApplication(name: "Cask", status: .upToDate)
    previous.source = .homebrew
    previous.lastInstalledAt = installedAt

    var scanned = makeApplication(name: "Cask", status: .updateAvailable, latestVersion: "2.0")
    scanned.source = .homebrew

    let merged = AppLibrary.mergeKeepingCheckResults([scanned], previous: [previous])

    XCTAssertEqual(merged.first?.lastInstalledAt, installedAt)
    XCTAssertEqual(merged.first?.status, .updateAvailable)
  }

  func testMergeDoesNotCopyStatusAcrossSources() {
    var previous = makeApplication(name: "Cursor", status: .selfManaged)
    previous.source = .homebrew

    var scanned = makeApplication(name: "Cursor", status: .checking)
    scanned.source = .vscodeUpdater
    scanned.sourceURL = URL(string: "https://api2.cursor.sh/updates")

    let merged = AppLibrary.mergeKeepingCheckResults([scanned], previous: [previous])

    XCTAssertEqual(merged.first?.source, .vscodeUpdater)
    XCTAssertEqual(merged.first?.status, .checking)
  }

  func testMergeCopiesReleaseNotesOntoHomebrewUpdate() {
    var previous = makeApplication(name: "Notes", status: .updateAvailable, latestVersion: "2.0")
    previous.source = .sparkle
    previous.releaseNotes = "Sparkle notes"
    previous.releaseNotesURL = URL(string: "https://example.com/notes")

    var current = makeApplication(name: "Notes", status: .updateAvailable, latestVersion: "2.0")
    current.source = .homebrew
    current.releaseNotes = nil

    let merged = AppLibrary.mergeKeepingCheckResults([current], previous: [previous])

    XCTAssertEqual(merged.first?.source, .homebrew)
    XCTAssertEqual(merged.first?.releaseNotes, "Sparkle notes")
    XCTAssertEqual(merged.first?.releaseNotesURL?.absoluteString, "https://example.com/notes")
  }

  func testCoalesceKeepsLastInstalledAt() {
    let installedAt = Date(timeIntervalSince1970: 1_777_000_000)
    var existing = makeApplication(name: "Example", status: .upToDate)
    existing.lastInstalledAt = installedAt
    var incoming = makeApplication(name: "Example", status: .upToDate)
    incoming.lastInstalledAt = nil

    let coalesced = AppLibrary.coalesceCheckResult(incoming, over: existing)

    XCTAssertEqual(coalesced.lastInstalledAt, installedAt)
  }

  func testFailedRecheckDoesNotDropKnownUpdate() {
    let existing = makeApplication(name: "Example", status: .updateAvailable, latestVersion: "2.0")
    var failed = existing
    failed.status = .unavailable("更新源暂时无法访问。")

    let coalesced = AppLibrary.coalesceCheckResult(failed, over: existing)

    XCTAssertEqual(coalesced.status, .updateAvailable)
    XCTAssertEqual(coalesced.latestVersion, "2.0")
  }

  func testSelfManagedRecheckDoesNotDropKnownUpdate() {
    let existing = makeApplication(name: "Example", status: .updateAvailable, latestVersion: "2.0")
    var unchecked = existing
    unchecked.status = .selfManaged
    unchecked.latestVersion = nil
    unchecked.canAutomaticallyUpdate = false

    let coalesced = AppLibrary.coalesceCheckResult(unchecked, over: existing)

    XCTAssertEqual(coalesced.status, .updateAvailable)
    XCTAssertEqual(coalesced.latestVersion, "2.0")
  }

  func testSuccessfulUpToDateRecheckDropsKnownUpdate() {
    let existing = makeApplication(name: "Example", status: .updateAvailable, latestVersion: "2.0")
    var current = existing
    current.status = .upToDate
    current.latestVersion = "1.0"
    current.canAutomaticallyUpdate = false

    let coalesced = AppLibrary.coalesceCheckResult(current, over: existing)

    XCTAssertEqual(coalesced.status, .upToDate)
    XCTAssertTrue([coalesced].availableUpdates(ignoredIDs: []).isEmpty)
  }

  func testRefreshKeepsAvailableUpdateWhenRecheckFails() async throws {
    let suiteName = "AppMintTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let known = makeApplication(name: "Example", status: .updateAvailable, latestVersion: "2.0")
    let scanned = makeApplication(name: "Example", status: .checking)
    let coordinator = StubCoordinator()
    coordinator.checkHandler = { application in
      var failed = application
      failed.status = .unavailable("更新源暂时无法访问。")
      return failed
    }

    let library = AppLibrary(
      applications: [known],
      scanner: StubScanner(applications: [scanned]),
      coordinator: coordinator,
      userDefaults: defaults,
      libraryStore: .memory()
    )

    XCTAssertEqual(library.availableUpdates.map(\.name), ["Example"])
    await library.refresh()

    XCTAssertEqual(library.availableUpdates.map(\.name), ["Example"])
    XCTAssertEqual(library.applications.first?.status, .updateAvailable)
    XCTAssertTrue(library.applications.installedApplications().isEmpty)
  }

  func testRefreshKeepsAvailableUpdateWhenRecheckBecomesSelfManaged() async throws {
    let suiteName = "AppMintTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let known = makeApplication(name: "Example", status: .updateAvailable, latestVersion: "2.0")
    let scanned = makeApplication(name: "Example", status: .checking)
    let coordinator = StubCoordinator()
    coordinator.checkHandler = { application in
      var unchecked = application
      unchecked.status = .selfManaged
      unchecked.latestVersion = nil
      unchecked.canAutomaticallyUpdate = false
      return unchecked
    }

    let library = AppLibrary(
      applications: [known],
      scanner: StubScanner(applications: [scanned]),
      coordinator: coordinator,
      userDefaults: defaults,
      libraryStore: .memory()
    )

    XCTAssertEqual(library.availableUpdates.map(\.name), ["Example"])
    await library.refresh()

    XCTAssertEqual(library.availableUpdates.map(\.name), ["Example"])
    XCTAssertEqual(library.applications.first?.status, .updateAvailable)
  }

  func testRefreshesMissingReleaseNotesForSelectedUpdate() async throws {
    let suiteName = "AppMintTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var dbx = makeApplication(
      name: "DBX",
      status: .updateAvailable,
      latestVersion: "0.5.95"
    )
    dbx.source = .tauri
    dbx.sourceURL = URL(
      string: "https://example.com/releases/latest/latest.json"
    )
    let other = makeApplication(
      name: "Other",
      status: .updateAvailable,
      latestVersion: "2.0"
    )
    let dbxID = dbx.id

    let coordinator = StubCoordinator()
    coordinator.checkHandler = { application in
      var checked = application
      if checked.id == dbxID {
        checked.releaseNotes = "### 修复\n\n- DBX 更新说明"
      }
      return checked
    }

    let library = AppLibrary(
      applications: [dbx, other],
      coordinator: coordinator,
      userDefaults: defaults,
      libraryStore: .memory()
    )

    await library.refreshReleaseMetadataIfNeeded(for: dbxID)

    XCTAssertEqual(
      library.applications.first(where: { $0.id == dbxID })?.releaseNotes,
      "### 修复\n\n- DBX 更新说明"
    )
    XCTAssertNil(library.applications.first(where: { $0.id == other.id })?.releaseNotes)
  }

  func testRefreshesMissingReleaseNotesForUpToDateApplication() async throws {
    let suiteName = "AppMintTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var reasonix = makeApplication(name: "Reasonix Studio", status: .upToDate)
    reasonix.source = .tauri
    reasonix.latestVersion = reasonix.currentVersion
    reasonix.sourceURL = URL(string: "https://example.com/studio/versions.json")
    reasonix.releaseNotesURL = URL(
      string: "https://github.com/example/reasonix/releases/tag/studio-v2.7.0"
    )
    let reasonixID = reasonix.id

    let coordinator = StubCoordinator()
    coordinator.checkHandler = { application in
      var checked = application
      if checked.id == reasonixID {
        checked.releaseNotes = "已安装版本的发行说明"
      }
      return checked
    }

    let library = AppLibrary(
      applications: [reasonix],
      coordinator: coordinator,
      userDefaults: defaults,
      libraryStore: .memory()
    )

    await library.refreshReleaseMetadataIfNeeded(for: reasonixID)

    XCTAssertEqual(library.applications.first?.releaseNotes, "已安装版本的发行说明")
    XCTAssertEqual(library.applications.first?.status, .upToDate)
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

private actor CheckConcurrencyProbe {
  private var currentCount = 0
  private var maximumCount = 0

  var observation: (current: Int, maximum: Int) {
    (currentCount, maximumCount)
  }

  func started() {
    currentCount += 1
    maximumCount = max(maximumCount, currentCount)
  }

  func finished() {
    currentCount -= 1
  }
}

private struct ConcurrencyTrackingCoordinator: UpdateCoordinating {
  let probe: CheckConcurrencyProbe

  func enrich(_ applications: [AppRecord]) async -> [AppRecord] {
    applications
  }

  func check(_ application: AppRecord) async -> AppRecord {
    await probe.started()
    try? await Task.sleep(for: .milliseconds(50))
    await probe.finished()
    return application
  }

  func update(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {}
}
