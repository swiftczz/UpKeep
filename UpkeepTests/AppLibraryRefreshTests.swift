import Foundation
import XCTest

@testable import Upkeep

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
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let fileManager = FileManager.default
    let applicationURL = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepCached-\(UUID().uuidString).app", isDirectory: true)
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

  func testLoadIfNeededPublishesInstalledApplicationsBeforeFullScanFinishes() async throws {
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let quick = AppRecord(
      name: "Listed",
      bundleIdentifier: "com.example.listed",
      applicationURL: URL(fileURLWithPath: "/Applications/Listed.app"),
      currentVersion: "1.0",
      source: .selfManaged,
      status: .selfManaged
    )
    let scanned = AppRecord(
      name: "Listed",
      bundleIdentifier: "com.example.listed",
      applicationURL: URL(fileURLWithPath: "/Applications/Listed.app"),
      currentVersion: "1.0",
      source: .sparkle,
      status: .checking,
      sourceURL: URL(string: "https://example.com/appcast.xml")
    )
    let gate = AsyncGate()
    let library = AppLibrary(
      scanner: TwoStageScanner(
        installedApplications: [quick],
        scannedApplications: [scanned],
        gate: gate
      ),
      coordinator: StubCoordinator(),
      userDefaults: defaults,
      libraryStore: .memory()
    )

    let load = Task { await library.loadIfNeeded() }

    var sawQuickList = false
    for _ in 0..<40 {
      try await Task.sleep(for: .milliseconds(10))
      if library.applications == [quick], library.phase == .scanning {
        sawQuickList = true
        break
      }
    }

    XCTAssertTrue(sawQuickList)
    await gate.open()
    await load.value
    XCTAssertEqual(library.applications.map(\.source), [.sparkle])
    XCTAssertEqual(library.phase, .idle)
  }

  func testRestartRefreshSupersedesInFlightAutomaticRefresh() async throws {
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let seed = AppRecord(
      name: "Seed",
      bundleIdentifier: "com.example.seed",
      applicationURL: URL(fileURLWithPath: "/Applications/Seed.app"),
      currentVersion: "1.0",
      source: .selfManaged,
      status: .selfManaged
    )
    let stale = AppRecord(
      name: "Stale",
      bundleIdentifier: "com.example.stale",
      applicationURL: URL(fileURLWithPath: "/Applications/Stale.app"),
      currentVersion: "1.0",
      source: .selfManaged,
      status: .selfManaged
    )
    let fresh = AppRecord(
      name: "Fresh",
      bundleIdentifier: "com.example.fresh",
      applicationURL: URL(fileURLWithPath: "/Applications/Fresh.app"),
      currentVersion: "1.0",
      source: .selfManaged,
      status: .selfManaged
    )
    let firstScanGate = AsyncGate()
    let scanner = RestartingScanner(
      firstResult: [stale],
      restartedResult: [fresh],
      firstScanGate: firstScanGate
    )
    let library = AppLibrary(
      applications: [seed],
      scanner: scanner,
      coordinator: StubCoordinator(),
      userDefaults: defaults,
      libraryStore: .memory()
    )

    let automaticRefresh = Task {
      await library.refreshIfStale(after: 0)
    }

    for _ in 0..<40 {
      try await Task.sleep(for: .milliseconds(10))
      if scanner.startedScanCount == 1, library.phase == .scanning {
        break
      }
    }
    XCTAssertEqual(scanner.startedScanCount, 1)
    XCTAssertEqual(library.phase, .scanning)

    await library.restartRefresh()

    XCTAssertEqual(library.applications.map(\.name), ["Fresh"])
    XCTAssertEqual(library.phase, .idle)

    await firstScanGate.open()
    await automaticRefresh.value

    XCTAssertEqual(library.applications.map(\.name), ["Fresh"])
    XCTAssertEqual(library.phase, .idle)
  }

  func testPublishesAvailableUpdatesAsEachCheckFinishes() async throws {
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
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
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let applications = (0..<64).map {
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
    XCTAssertEqual(observation.maximum, 30)
    XCTAssertEqual(observation.current, 0)
    XCTAssertTrue(library.checkingApplicationIDs.isEmpty)
  }

  func testRefreshOnlyChecksApplicationsWithCheckableSources() async throws {
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var sparkle = makeApplication(name: "Sparkle", status: .checking)
    sparkle.source = .sparkle
    sparkle.sourceURL = URL(string: "https://example.com/appcast.xml")
    var appStore = makeApplication(name: "Store", status: .checking)
    appStore.source = .appStore
    appStore.appStorePlatform = .mac
    var homebrew = makeApplication(name: "Brew", status: .upToDate)
    homebrew.source = .homebrew
    homebrew.sourceIdentifier = "brew"
    var selfManaged = makeApplication(name: "Manual", status: .selfManaged)
    selfManaged.source = .selfManaged
    var sparkleWithoutFeed = makeApplication(name: "Sparkle No Feed", status: .selfManaged)
    sparkleWithoutFeed.source = .sparkle
    sparkleWithoutFeed.sourceURL = nil

    let recorder = CheckedApplicationRecorder()
    let library = AppLibrary(
      applications: [],
      scanner: StubScanner(
        applications: [sparkle, appStore, homebrew, selfManaged, sparkleWithoutFeed]
      ),
      coordinator: RecordingCoordinator(recorder: recorder),
      userDefaults: defaults,
      libraryStore: .memory()
    )

    await library.refresh()

    let checkedNames = await recorder.names()
    XCTAssertEqual(Set(checkedNames), ["Sparkle", "Store"])
    XCTAssertEqual(checkedNames.count, 2)
    XCTAssertTrue(library.checkingApplicationIDs.isEmpty)
  }

  func testRefreshIfStaleSkipsWhenRecentlyChecked() async throws {
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
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
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
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

  func testCancelledLocalScanReturnsToIdleAndAllowsNextScan() async {
    let seed = makeApplication(name: "Example", status: .upToDate)
    var updated = seed
    updated.currentVersion = "2.0"
    let step = ControlledScan(result: [updated])
    let scanner = ControlledRefreshScanner(local: [step], fallback: [seed])
    let library = makeScanLibrary(seed: seed, scanner: scanner)
    let task = Task { await library.refreshInstalledApplications() }
    await step.started.wait()
    task.cancel()
    await step.release.open()
    await task.value

    XCTAssertEqual(library.phase, .idle)
    XCTAssertEqual(library.applications.first?.currentVersion, "1.0")
    await library.refreshInstalledApplications()
    let counts = await scanner.counts
    XCTAssertEqual(counts.local, 2)
    XCTAssertEqual(counts.full, 0)
    XCTAssertEqual(library.phase, .idle)
  }

  func testLocalChangesDuringScanCoalesceAndNeverCheckUpdates() async {
    let seed = makeApplication(name: "Example", status: .upToDate)
    var updated = seed
    updated.currentVersion = "2.0"
    let first = ControlledScan(result: [seed])
    let second = ControlledScan(result: [updated])
    let scanner = ControlledRefreshScanner(local: [first, second], fallback: [updated])
    let recorder = CheckedApplicationRecorder()
    let library = makeScanLibrary(
      seed: seed, scanner: scanner, coordinator: RecordingCoordinator(recorder: recorder)
    )
    let lastCheckedAt = library.lastCheckedAt
    let task = Task { await library.refreshInstalledApplications() }
    await first.started.wait()
    for _ in 0..<5 { await library.refreshInstalledApplications() }
    await first.release.open()
    await second.started.wait()
    XCTAssertEqual(library.phase, .scanning)
    await second.release.open()
    await task.value

    let counts = await scanner.counts
    let names = await recorder.names()
    XCTAssertEqual(counts.local, 2)
    XCTAssertEqual(counts.full, 0)
    XCTAssertTrue(names.isEmpty)
    XCTAssertEqual(library.lastCheckedAt, lastCheckedAt)
    XCTAssertEqual(library.applications.first?.currentVersion, "2.0")
    XCTAssertEqual(library.phase, .idle)
  }

  func testManualScanTakesOverLocalScanAndPreservesLaterChanges() async {
    let seed = makeApplication(name: "Example", status: .upToDate)
    var updated = seed
    updated.currentVersion = "2.0"
    let local = ControlledScan(result: [])
    let full = ControlledScan(result: [seed])
    let scanner = ControlledRefreshScanner(local: [local], full: [full], fallback: [updated])
    let library = makeScanLibrary(seed: seed, scanner: scanner)
    let oldTask = Task { await library.refreshInstalledApplications() }
    await local.started.wait()
    // This pending request is covered by the manual scan.
    await library.refreshInstalledApplications()
    let manualTask = Task { await library.restartRefresh() }
    await full.started.wait()
    await local.release.open()
    await oldTask.value
    XCTAssertEqual(library.phase, .scanning)
    XCTAssertFalse(library.applications.isEmpty)
    // Changes arriving after the manual scan starts still need a local follow-up.
    for _ in 0..<3 { await library.refreshInstalledApplications() }
    await full.release.open()
    await manualTask.value

    let counts = await scanner.counts
    XCTAssertEqual(counts.local, 2)
    XCTAssertEqual(counts.full, 1)
    XCTAssertEqual(library.applications.first?.currentVersion, "2.0")
    XCTAssertEqual(library.phase, .idle)
  }

  func testManualScanAbsorbsPreviouslyQueuedLocalScan() async {
    let seed = makeApplication(name: "Example", status: .upToDate)
    let local = ControlledScan(result: [])
    let scanner = ControlledRefreshScanner(local: [local], fallback: [seed])
    let library = makeScanLibrary(seed: seed, scanner: scanner)
    let oldTask = Task { await library.refreshInstalledApplications() }
    await local.started.wait()
    await library.refreshInstalledApplications()
    await library.restartRefresh()
    await local.release.open()
    await oldTask.value

    let counts = await scanner.counts
    XCTAssertEqual(counts.local, 1)
    XCTAssertEqual(counts.full, 1)
    XCTAssertEqual(library.phase, .idle)
    XCTAssertFalse(library.applications.isEmpty)
  }

  func testCancelledFullScanReturnsToIdle() async {
    let seed = makeApplication(name: "Example", status: .upToDate)
    let full = ControlledScan(result: [])
    let scanner = ControlledRefreshScanner(full: [full], fallback: [seed])
    let library = makeScanLibrary(seed: seed, scanner: scanner)
    let task = Task { await library.restartRefresh() }
    await full.started.wait()
    task.cancel()
    await full.release.open()
    await task.value
    XCTAssertEqual(library.phase, .idle)
    XCTAssertFalse(library.applications.isEmpty)
    await library.refreshInstalledApplications()
    let counts = await scanner.counts
    XCTAssertEqual(counts.local, 1)
  }

  func testCancelledUpdateCheckClearsBusyState() async {
    let seed = makeApplication(name: "Example", status: .upToDate)
    let started = AsyncGate()
    let release = AsyncGate()
    let coordinator = StubCoordinator()
    coordinator.checkHandler = { application in
      await started.open()
      await release.wait()
      return application
    }
    let scanner = ControlledRefreshScanner(fallback: [seed])
    let library = makeScanLibrary(seed: seed, scanner: scanner, coordinator: coordinator)
    let task = Task { await library.restartRefresh() }
    await started.wait()
    XCTAssertEqual(library.phase, .checking)
    task.cancel()
    await release.open()
    await task.value
    XCTAssertEqual(library.phase, .idle)
    XCTAssertTrue(library.checkingApplicationIDs.isEmpty)
  }

  func testAutomaticFullRefreshReplaysLocalChangesWithoutExtraUpdateChecks() async {
    let seed = makeApplication(name: "Example", status: .upToDate)
    let full = ControlledScan(result: [seed])
    let scanner = ControlledRefreshScanner(full: [full], fallback: [seed])
    let recorder = CheckedApplicationRecorder()
    let library = makeScanLibrary(
      seed: seed, scanner: scanner, coordinator: RecordingCoordinator(recorder: recorder)
    )
    let task = Task { await library.refreshIfStale(after: 0) }
    await full.started.wait()
    for _ in 0..<3 { await library.refreshInstalledApplications() }
    await full.release.open()
    await task.value

    let counts = await scanner.counts
    let names = await recorder.names()
    XCTAssertEqual(counts.local, 1)
    XCTAssertEqual(counts.full, 1)
    XCTAssertEqual(names, ["Example"])
    XCTAssertEqual(library.phase, .idle)
  }

  func testAlreadyCancelledManualRefreshDoesNotInvalidateActiveScan() async {
    let seed = makeApplication(name: "Example", status: .upToDate)
    let local = ControlledScan(result: [seed])
    let scanner = ControlledRefreshScanner(local: [local], fallback: [seed])
    let library = makeScanLibrary(seed: seed, scanner: scanner)
    let task = Task { await library.refreshInstalledApplications() }
    await local.started.wait()
    let release = AsyncGate()
    let cancelledTask = Task {
      await release.wait()
      await library.restartRefresh()
    }
    cancelledTask.cancel()
    await release.open()
    await cancelledTask.value
    XCTAssertEqual(library.phase, .scanning)
    await local.release.open()
    await task.value
    let counts = await scanner.counts
    XCTAssertEqual(counts.full, 0)
    XCTAssertEqual(library.phase, .idle)
  }

  private func makeScanLibrary(
    seed: AppRecord,
    scanner: any ApplicationScanning,
    coordinator: any UpdateCoordinating = StubCoordinator()
  ) -> AppLibrary {
    AppLibrary(
      applications: [seed], scanner: scanner, coordinator: coordinator,
      userDefaults: UserDefaults(suiteName: "UpkeepTests.\(UUID().uuidString)")!,
      libraryStore: .memory()
    )
  }

  func testInstalledApplicationRefreshMovesExternalUpdateWithoutCheckingSources() async throws {
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let known = makeApplication(
      name: "Example",
      status: .updateAvailable,
      latestVersion: "2.0"
    )
    var installed = makeApplication(name: "Example", status: .selfManaged)
    installed.currentVersion = "2.0"
    installed.source = .selfManaged
    installed.sourceURL = nil
    installed.latestVersion = nil
    let scanner = InstalledOnlyCountingScanner(installedApplications: [installed])
    let recorder = CheckedApplicationRecorder()
    let lastCheckedAt = Date(timeIntervalSince1970: 1_777_000_000)
    let library = AppLibrary(
      applications: [known],
      scanner: scanner,
      coordinator: RecordingCoordinator(recorder: recorder),
      userDefaults: defaults,
      libraryStore: .memory()
    )
    library.lastCheckedAt = lastCheckedAt

    await library.refreshInstalledApplications()

    let checkedNames = await recorder.names()
    XCTAssertEqual(scanner.installedScanCount, 1)
    XCTAssertEqual(scanner.fullScanCount, 0)
    XCTAssertEqual(checkedNames, [])
    XCTAssertEqual(library.lastCheckedAt, lastCheckedAt)
    XCTAssertEqual(library.applications.first?.currentVersion, "2.0")
    XCTAssertEqual(library.applications.first?.latestVersion, "2.0")
    XCTAssertEqual(library.applications.first?.source, .sparkle)
    XCTAssertEqual(library.applications.first?.status, .upToDate)
    XCTAssertNotNil(library.applications.first?.lastInstalledAt)
    XCTAssertTrue(library.availableUpdates.isEmpty)
    XCTAssertTrue(library.checkingApplicationIDs.isEmpty)
    XCTAssertEqual(library.phase, .idle)
  }

  func testInstalledApplicationRefreshKeepsUpdateWhenExternalVersionIsStillBehind() async throws {
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let known = makeApplication(
      name: "Example",
      status: .updateAvailable,
      latestVersion: "3.0"
    )
    var installed = makeApplication(name: "Example", status: .selfManaged)
    installed.currentVersion = "2.0"
    installed.source = .selfManaged
    installed.sourceURL = nil
    installed.latestVersion = nil
    let scanner = InstalledOnlyCountingScanner(installedApplications: [installed])
    let recorder = CheckedApplicationRecorder()
    let library = AppLibrary(
      applications: [known],
      scanner: scanner,
      coordinator: RecordingCoordinator(recorder: recorder),
      userDefaults: defaults,
      libraryStore: .memory()
    )

    await library.refreshInstalledApplications()

    let checkedNames = await recorder.names()
    XCTAssertEqual(scanner.installedScanCount, 1)
    XCTAssertEqual(scanner.fullScanCount, 0)
    XCTAssertEqual(checkedNames, [])
    XCTAssertEqual(library.applications.first?.currentVersion, "2.0")
    XCTAssertEqual(library.applications.first?.latestVersion, "3.0")
    XCTAssertEqual(library.applications.first?.status, .updateAvailable)
    XCTAssertEqual(library.availableUpdates.map(\.name), ["Example"])
    XCTAssertTrue(library.checkingApplicationIDs.isEmpty)
  }

  func testInstalledApplicationMergeRefreshesDetectedVSCodeCommit() {
    var previous = makeApplication(
      name: "Code",
      status: .updateAvailable,
      latestVersion: "1.136.1"
    )
    previous.source = .vscodeUpdater
    previous.currentVersion = "1.136.0"
    previous.buildVersion = "520fb30"
    previous.latestBuildVersion = "a44adf7"
    previous.sourceIdentifier = "stable/520fb30b2d3d324b4cb2342f6e88e2cd93751de1"

    var installed = previous
    installed.currentVersion = "1.136.1"
    installed.buildVersion = "a44adf7"
    installed.sourceIdentifier = "stable/a44adf7f53e00964ab890f9f8758a334f1fc15bc"

    let merged = AppLibrary.mergeInstalledApplicationChanges([installed], previous: [previous])

    XCTAssertEqual(
      merged.first?.sourceIdentifier,
      "stable/a44adf7f53e00964ab890f9f8758a334f1fc15bc"
    )
    XCTAssertEqual(merged.first?.status, .upToDate)
  }

  func testInstalledApplicationMergeAcceptsNewlyDetectedAppStoreSource() {
    var previous = makeApplication(name: "TestFlight", status: .selfManaged)
    previous.source = .selfManaged
    previous.sourceURL = nil

    var detected = previous
    detected.source = .appStore
    detected.appStorePlatform = .mac
    detected.sourceIdentifier = "899247664"
    detected.status = .upToDate

    let merged = AppLibrary.mergeInstalledApplicationChanges(
      [detected],
      previous: [previous]
    )

    XCTAssertEqual(merged.first?.source, .appStore)
    XCTAssertEqual(merged.first?.appStorePlatform, .mac)
    XCTAssertEqual(merged.first?.sourceIdentifier, "899247664")
    XCTAssertEqual(merged.first?.status, .upToDate)
  }

  func testMergeKeepsKnownUpdateWhenScanReturnsChecking() {
    let previous = makeApplication(name: "Example", status: .updateAvailable, latestVersion: "2.0")
    let scanned = makeApplication(name: "Example", status: .checking)

    let merged = AppLibrary.mergeKeepingCheckResults([scanned], previous: [previous])

    XCTAssertEqual(merged.first?.status, .updateAvailable)
    XCTAssertEqual(merged.first?.latestVersion, "2.0")
    XCTAssertEqual(merged.availableUpdates(ignoredIDs: []).map(\.name), ["Example"])
  }

  func testMergeDropsStaleGhosttyTipUpdateAfterHomebrewInstall() {
    let applicationURL = URL(fileURLWithPath: "/Applications/Ghostty.app")
    let previous = AppRecord(
      name: "Ghostty",
      bundleIdentifier: "com.mitchellh.ghostty",
      applicationURL: applicationURL,
      currentVersion: "3baff3a06",
      buildVersion: "17574",
      source: .sparkle,
      status: .updateAvailable,
      latestVersion: "17574,3baff3a069cb64a9d3739c2ff25423524b3b80ee"
    )
    let scanned = AppRecord(
      name: "Ghostty",
      bundleIdentifier: "com.mitchellh.ghostty",
      applicationURL: applicationURL,
      currentVersion: "3baff3a06",
      buildVersion: "17574",
      source: .sparkle,
      status: .checking,
      sourceURL: URL(string: "https://tip.files.ghostty.org/appcast.xml")
    )

    let merged = AppLibrary.mergeKeepingCheckResults([scanned], previous: [previous])

    XCTAssertEqual(merged.first?.status, .checking)
    XCTAssertNil(merged.first?.latestVersion)
    XCTAssertTrue(merged.availableUpdates(ignoredIDs: []).isEmpty)
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

  func testMergeKeepsHomebrewTokenForNonAppStoreApplication() {
    var previous = makeApplication(name: "Screendrop", status: .upToDate)
    previous.source = .sparkle
    previous.homebrewCaskToken = "screendrop"

    var scanned = makeApplication(name: "Screendrop", status: .checking)
    scanned.source = .sparkle
    scanned.homebrewCaskToken = nil

    let merged = AppLibrary.mergeKeepingCheckResults([scanned], previous: [previous])

    XCTAssertEqual(merged.first?.homebrewCaskToken, "screendrop")
  }

  func testMergeDoesNotCarryHomebrewTokenOntoAppStoreApplication() {
    var previous = makeApplication(name: "Example", status: .upToDate)
    previous.source = .sparkle
    previous.homebrewCaskToken = "example"

    var scanned = makeApplication(name: "Example", status: .checking)
    scanned.source = .appStore
    scanned.appStorePlatform = .mac
    scanned.homebrewCaskToken = nil

    let merged = AppLibrary.mergeKeepingCheckResults([scanned], previous: [previous])

    XCTAssertNil(merged.first?.homebrewCaskToken)
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

  func testMergeDropsGitHubUpdateWhenRepositoryNoLongerMatchesApplication() {
    var previous = makeApplication(
      name: "FlClash",
      status: .updateAvailable,
      latestVersion: "1.19.30"
    )
    previous.source = .githubReleases
    previous.sourceIdentifier = "MetaCubeX/mihomo"

    var scanned = makeApplication(name: "FlClash", status: .selfManaged)
    scanned.source = .selfManaged
    scanned.sourceURL = nil

    let merged = AppLibrary.mergeKeepingCheckResults([scanned], previous: [previous])

    XCTAssertEqual(merged.first?.source, .selfManaged)
    XCTAssertEqual(merged.first?.status, .selfManaged)
    XCTAssertNil(merged.first?.latestVersion)
    XCTAssertTrue(merged.availableUpdates(ignoredIDs: []).isEmpty)
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
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
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
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
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
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
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
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
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

  func testLateReleaseMetadataDoesNotUndoExternalVersionUpdate() async throws {
    try await assertLateReleaseMetadataPreservesExternalUpdate(installedVersion: "2.0")
  }

  func testLateReleaseMetadataDoesNotUndoExternalBuildUpdate() async throws {
    try await assertLateReleaseMetadataPreservesExternalUpdate(installedVersion: "1.0")
  }

  func testCancelledReleaseMetadataRequestDoesNotPublishResult() async throws {
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let application = makeApplication(name: "Example", status: .upToDate)
    let requestStarted = AsyncGate()
    let responseReady = AsyncGate()
    let coordinator = StubCoordinator()
    coordinator.checkHandler = { application in
      await requestStarted.open()
      await responseReady.wait()
      var checked = application
      checked.releaseNotes = "已取消请求的更新说明"
      return checked
    }
    let library = AppLibrary(
      applications: [application],
      coordinator: coordinator,
      userDefaults: defaults,
      libraryStore: .memory()
    )

    let metadataTask = Task {
      await library.refreshReleaseMetadataIfNeeded(for: application.id)
    }
    await requestStarted.wait()
    metadataTask.cancel()
    await responseReady.open()
    await metadataTask.value

    XCTAssertEqual(library.applications, [application])
  }

  private func assertLateReleaseMetadataPreservesExternalUpdate(
    installedVersion: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    var application = makeApplication(
      name: "Example",
      status: .updateAvailable,
      latestVersion: installedVersion
    )
    application.buildVersion = "100"
    application.latestBuildVersion = "200"
    application.canAutomaticallyUpdate = true
    var installed = application
    installed.currentVersion = installedVersion
    installed.buildVersion = "200"

    let requestStarted = AsyncGate()
    let responseReady = AsyncGate()
    let coordinator = StubCoordinator()
    coordinator.checkHandler = { application in
      await requestStarted.open()
      await responseReady.wait()
      var checked = application
      checked.releaseNotes = "迟到的更新说明"
      return checked
    }
    let library = AppLibrary(
      applications: [application],
      scanner: StubScanner(applications: [installed]),
      coordinator: coordinator,
      userDefaults: defaults,
      libraryStore: .memory()
    )
    let applicationID = application.id

    let metadataTask = Task {
      await library.refreshReleaseMetadataIfNeeded(for: applicationID)
    }
    await requestStarted.wait()
    await library.refreshInstalledApplications()
    let current = try XCTUnwrap(library.applications.first, file: file, line: line)
    XCTAssertEqual(current.currentVersion, installedVersion, file: file, line: line)
    XCTAssertEqual(current.buildVersion, "200", file: file, line: line)
    XCTAssertEqual(current.status, .upToDate, file: file, line: line)
    XCTAssertFalse(current.canAutomaticallyUpdate, file: file, line: line)

    await responseReady.open()
    await metadataTask.value

    XCTAssertEqual(library.applications, [current], file: file, line: line)
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

private struct TwoStageScanner: ApplicationScanning {
  let installedApplications: [AppRecord]
  let scannedApplications: [AppRecord]
  let gate: AsyncGate

  func scanInstalledApplications(reusing previousApplications: [AppRecord]) async -> [AppRecord] {
    installedApplications
  }

  func scan() async -> [AppRecord] {
    await gate.wait()
    return scannedApplications
  }
}

private final class RestartingScanner: ApplicationScanning, @unchecked Sendable {
  let firstResult: [AppRecord]
  let restartedResult: [AppRecord]
  let firstScanGate: AsyncGate

  private let lock = NSLock()
  private var startedScans = 0

  init(
    firstResult: [AppRecord],
    restartedResult: [AppRecord],
    firstScanGate: AsyncGate
  ) {
    self.firstResult = firstResult
    self.restartedResult = restartedResult
    self.firstScanGate = firstScanGate
  }

  var startedScanCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return startedScans
  }

  func scan() async -> [AppRecord] {
    let scanNumber = nextScanNumber()
    if scanNumber == 1 {
      await firstScanGate.wait()
      return firstResult
    }
    return restartedResult
  }

  private func nextScanNumber() -> Int {
    lock.lock()
    defer { lock.unlock() }
    startedScans += 1
    return startedScans
  }
}

private actor AsyncGate {
  private var isOpen = false
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen {
      return
    }
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func open() {
    isOpen = true
    let pending = continuations
    continuations.removeAll()
    pending.forEach { $0.resume() }
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

private final class InstalledOnlyCountingScanner: ApplicationScanning, @unchecked Sendable {
  let installedApplications: [AppRecord]
  private(set) var installedScanCount = 0
  private(set) var fullScanCount = 0

  init(installedApplications: [AppRecord]) {
    self.installedApplications = installedApplications
  }

  func scanInstalledApplications(reusing previousApplications: [AppRecord]) async -> [AppRecord] {
    installedScanCount += 1
    return installedApplications
  }

  func scan() async -> [AppRecord] {
    fullScanCount += 1
    return installedApplications
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

private actor CheckedApplicationRecorder {
  private var storage: [String] = []

  func append(_ name: String) {
    storage.append(name)
  }

  func names() -> [String] {
    storage
  }
}

private struct RecordingCoordinator: UpdateCoordinating {
  let recorder: CheckedApplicationRecorder

  func enrich(_ applications: [AppRecord]) async -> [AppRecord] {
    applications
  }

  func check(_ application: AppRecord) async -> AppRecord {
    await recorder.append(application.name)
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

private struct ControlledScan: Sendable {
  let result: [AppRecord]
  let started = AsyncGate()
  let release = AsyncGate()

  func run() async -> [AppRecord] {
    await started.open()
    await release.wait()
    return result
  }
}

private actor ControlledRefreshScanner: ApplicationScanning {
  let local: [ControlledScan]
  let full: [ControlledScan]
  let fallback: [AppRecord]
  private(set) var counts = (local: 0, full: 0)

  init(local: [ControlledScan] = [], full: [ControlledScan] = [], fallback: [AppRecord]) {
    self.local = local
    self.full = full
    self.fallback = fallback
  }

  func scanInstalledApplications(reusing previousApplications: [AppRecord]) async -> [AppRecord] {
    let index = counts.local
    counts.local += 1
    guard index < local.count else { return fallback }
    return await local[index].run()
  }

  func scan() async -> [AppRecord] {
    let index = counts.full
    counts.full += 1
    guard index < full.count else { return fallback }
    return await full[index].run()
  }
}
