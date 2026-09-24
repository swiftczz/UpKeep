import Foundation
import Observation
import Synchronization
import XCTest

@testable import Upkeep

@MainActor
final class UpdatePerformanceTests: XCTestCase {
  func testBatchProcessCheckTakesOneSnapshotOffMainThread() async {
    let first = application("First")
    let second = application("Second")
    let prefixCollision = application("First.app-backup")
    let calls = Mutex(0)
    let running = await ApplicationProcess.runningApplicationIDs(in: [first, second, prefixCollision]) {
      XCTAssertFalse(Thread.isMainThread)
      calls.withLock { $0 += 1 }
      return [first.applicationURL.path + "/Contents/MacOS/First", second.applicationURL.path]
    }
    XCTAssertEqual(running, [first.id, second.id])
    XCTAssertEqual(calls.withLock { $0 }, 1)
  }

  func testProcessCheckResolvesApplicationSymlinkAndRejectsSiblingPrefix() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let actual = root.appendingPathComponent("Actual.app")
    let alias = root.appendingPathComponent("Alias.app")
    try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
    let app = application("Alias", url: alias)
    let path = actual.resolvingSymlinksInPath().path
    let running = await ApplicationProcess.runningApplicationIDs(in: [app]) {
      [path + "/Contents/Helpers/Helper"]
    }
    XCTAssertEqual(running, [app.id])
    let siblingOnly = await ApplicationProcess.runningApplicationIDs(in: [app]) {
      [path + "-backup/Contents/MacOS/App"]
    }
    XCTAssertTrue(siblingOnly.isEmpty)
  }

  func testCancelledAndEmptyProcessChecksSkipSnapshot() async {
    let calls = Mutex(0)
    let app = application("Cancelled")
    let empty = await ApplicationProcess.runningApplicationIDs(in: []) {
      calls.withLock { $0 += 1 }; return []
    }
    let task = Task { @MainActor in
      await ApplicationProcess.runningApplicationIDs(in: [app]) {
        calls.withLock { $0 += 1 }; return []
      }
    }
    task.cancel()
    let cancelled = await task.value
    XCTAssertTrue(empty.isEmpty)
    XCTAssertTrue(cancelled.isEmpty)
    XCTAssertEqual(calls.withLock { $0 }, 0)
  }

  func testProgressBurstPublishesAtMostTenTimesPerSecondAndKeepsLatest() {
    var throttle = UpdateProgressThrottle()
    let start = ContinuousClock.now
    var published: [UpdateProgress] = []
    for index in 0..<10_000 {
      let value = progress(Double(index) / 10_000)
      if let output = throttle.receive(value, at: start.advanced(by: .microseconds(index * 100))) {
        published.append(output)
      }
    }
    XCTAssertEqual(published.count, 10)
    XCTAssertEqual(throttle.flush(at: start.advanced(by: .seconds(1))), progress(0.9999))
    XCTAssertNil(throttle.deadline)
  }

  func testProgressPhaseChangesAndCompletionBypassThrottle() {
    var throttle = UpdateProgressThrottle()
    let now = ContinuousClock.now
    XCTAssertNotNil(throttle.receive(progress(0), at: now))
    XCTAssertNil(throttle.receive(progress(0.2), at: now))
    XCTAssertEqual(throttle.receive(progress(1), at: now), progress(1))
    let installing = UpdateProgress.indeterminate("正在安装…")
    XCTAssertEqual(throttle.receive(installing, at: now), installing)
    let determinate = UpdateProgress(fractionCompleted: 0, status: installing.status)
    XCTAssertEqual(throttle.receive(determinate, at: now), determinate)
    XCTAssertNil(throttle.flush(at: now))
  }

  func testDuplicateProgressDoesNotPublishOrLeaveStalePendingValue() {
    var throttle = UpdateProgressThrottle()
    let now = ContinuousClock.now
    XCTAssertNotNil(throttle.receive(progress(0.2), at: now))
    XCTAssertNil(throttle.receive(progress(0.3), at: now))
    XCTAssertNil(throttle.receive(progress(0.2), at: now))
    XCTAssertNil(throttle.deadline)
    XCTAssertNil(throttle.flush(at: now))
  }

  func testRelayFinishFlushesNewestValueAndRejectsLateCallbacks() async {
    let relay = UpdateProgressRelay()
    for index in 0..<10_000 { relay.submit(progress(Double(index) / 10_000)) }
    relay.finish()
    relay.submit(progress(1))
    relay.finish()
    var values: [UpdateProgress] = []
    for await value in relay.stream { values.append(value) }
    XCTAssertEqual(values, [progress(0.9999)])
  }

  func testRelayDeliversTrailingProgressWithoutAnotherCallback() async {
    let relay = UpdateProgressRelay()
    relay.submit(progress(0))
    var iterator = relay.stream.makeAsyncIterator()
    let first = await iterator.next()
    XCTAssertEqual(first, progress(0))
    let delivered = expectation(description: "Trailing progress")
    let latest = progress(0.75)
    let consumer = Task {
      for await value in relay.stream {
        if value == latest { delivered.fulfill(); return }
      }
    }
    relay.submit(latest)
    await fulfillment(of: [delivered], timeout: 2)
    relay.finish()
    await consumer.value
  }

  func testProgressOnlyInvalidatesItsOwnObservableState() throws {
    let first = application("First")
    let second = application("Second")
    let library = try library([first, second])
    let firstState = try XCTUnwrap(library.updateStatesByID[first.id])
    let secondState = try XCTUnwrap(library.updateStatesByID[second.id])
    firstState.begin()
    let parentChanges = Mutex(0)
    let secondChanges = Mutex(0)
    let progressChanges = Mutex(0)
    withObservationTracking {
      _ = library.updateStatesByID
      _ = library.sidebarSections
      _ = firstState.isUpdating
    } onChange: { parentChanges.withLock { $0 += 1 } }
    withObservationTracking { _ = secondState.progress }
      onChange: { secondChanges.withLock { $0 += 1 } }
    withObservationTracking { _ = firstState.progress }
      onChange: { progressChanges.withLock { $0 += 1 } }
    firstState.report(progress(0.5))
    XCTAssertEqual(parentChanges.withLock { $0 }, 0)
    XCTAssertEqual(secondChanges.withLock { $0 }, 0)
    XCTAssertEqual(progressChanges.withLock { $0 }, 1)
    library.applications.reverse()
    XCTAssertTrue(library.updateStatesByID[first.id] === firstState)
    firstState.finish()
    firstState.report(progress(0.9))
    XCTAssertFalse(firstState.isUpdating)
    XCTAssertNil(firstState.progress)
  }

  func testUpdateAllUsesSingleBatchAndRetainsPreparedCandidates() async throws {
    let first = application("First")
    let ignored = application("Ignored")
    let addedLater = application("Later")
    let calls = Mutex([[AppRecord.ID]]())
    let coordinator = BurstUpdateCoordinator()
    let process = ApplicationProcessClient(
      isRunning: { _ in XCTFail("Expected batch scan"); return false },
      quit: { _ in }, launch: { _ in },
      runningApplicationIDs: { apps in
        calls.withLock { $0.append(apps.map(\.id)) }
        return [first.id]
      }
    )
    let library = try library([first, ignored], coordinator: coordinator, process: process)
    library.ignoreUpdates(for: ignored.id)
    let plan = await library.prepareUpdateAll()
    XCTAssertEqual(calls.withLock { $0 }, [[first.id]])
    XCTAssertEqual(plan.runningApplications.map(\.id), [first.id])
    library.applications.append(addedLater)
    await library.updateAll(applicationIDs: plan.applicationIDs)
    let updated = await coordinator.updatedIDs
    XCTAssertEqual(updated, [first.id])
  }

  func testUpdateAllSkipsCandidatesIgnoredAfterPreparation() async throws {
    let app = application("Skip")
    let coordinator = BurstUpdateCoordinator()
    let library = try library([app], coordinator: coordinator)
    let plan = await library.prepareUpdateAll()
    library.ignoreUpdates(for: app.id)
    await library.updateAll(applicationIDs: plan.applicationIDs)
    let updated = await coordinator.updatedIDs
    XCTAssertTrue(updated.isEmpty)
  }

  func testSuccessAndFailureClearProgressAfterBurstAndIgnoreLateCallbacks() async throws {
    for fails in [false, true] {
      let app = application("Burst")
      let coordinator = BurstUpdateCoordinator(fails: fails)
      let library = try library([app], coordinator: coordinator)
      _ = await library.performPrimaryAction(for: app.id)
      let state = try XCTUnwrap(library.updateStatesByID[app.id])
      XCTAssertFalse(state.isUpdating)
      XCTAssertNil(state.progress)
      XCTAssertTrue(library.updatingApplicationIDs.isEmpty)
      XCTAssertEqual(library.alertMessage != nil, fails)
      await coordinator.reportLateProgress()
      await Task.yield()
      XCTAssertNil(state.progress)
    }
  }

  func testFinishingUpdatePreservesNewSelectionAndRejectsDuplicateUpdate() async throws {
    let first = application("First")
    let second = application("Second")
    let started = expectation(description: "Update is paused")
    let coordinator = BurstUpdateCoordinator(onPause: { started.fulfill() })
    let library = try library([first, second], coordinator: coordinator)
    library.selectedApplicationID = first.id
    let task = Task { await library.performPrimaryAction(for: first.id) }
    await fulfillment(of: [started], timeout: 2)
    library.selectedApplicationID = second.id
    _ = await library.performPrimaryAction(for: first.id)
    await coordinator.resume()
    _ = await task.value
    let updated = await coordinator.updatedIDs
    XCTAssertEqual(updated, [first.id])
    XCTAssertEqual(library.selectedApplicationID, second.id)
  }

  private func application(_ name: String, url: URL? = nil) -> AppRecord {
    AppRecord(
      name: name, bundleIdentifier: "com.upkeep.tests.\(name)",
      applicationURL: url ?? URL(fileURLWithPath: "/tmp/upkeep-missing-performance-tests/\(name).app"),
      currentVersion: "1.0", source: .sparkle, status: .updateAvailable,
      latestVersion: "2.0", canAutomaticallyUpdate: true
    )
  }

  private func progress(_ fraction: Double) -> UpdateProgress {
    UpdateProgress(fractionCompleted: fraction, status: "正在下载…")
  }

  private func library(
    _ apps: [AppRecord],
    coordinator: any UpdateCoordinating = BurstUpdateCoordinator(),
    process: ApplicationProcessClient = ApplicationProcessClient(
      isRunning: { _ in false }, quit: { _ in }, launch: { _ in }
    )
  ) throws -> AppLibrary {
    let suite = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    return AppLibrary(
      applications: apps, coordinator: coordinator, process: process,
      userDefaults: defaults, libraryStore: .memory()
    )
  }
}

private actor BurstUpdateCoordinator: UpdateCoordinating {
  var updatedIDs: [AppRecord.ID] = []
  var callback: (@Sendable (UpdateProgress) -> Void)?
  let fails: Bool
  let onPause: (@Sendable () -> Void)?
  var paused: CheckedContinuation<Void, Never>?
  init(fails: Bool = false, onPause: (@Sendable () -> Void)? = nil) {
    self.fails = fails
    self.onPause = onPause
  }
  func enrich(_ applications: [AppRecord]) async -> [AppRecord] { applications }
  func check(_ application: AppRecord) async -> AppRecord { application }
  func update(_ application: AppRecord, progress: @escaping @Sendable (UpdateProgress) -> Void) async throws {
    updatedIDs.append(application.id)
    callback = progress
    for index in 0..<10_000 {
      progress(UpdateProgress(fractionCompleted: Double(index) / 10_000, status: "正在下载…"))
    }
    if let onPause {
      await withCheckedContinuation {
        paused = $0
        onPause()
      }
    }
    if fails { throw ProcessRunnerError.failed(status: 1, message: "模拟更新失败") }
  }
  func resume() {
    paused?.resume()
    paused = nil
  }
  func reportLateProgress() {
    callback?(UpdateProgress(fractionCompleted: 0.9, status: "迟到的回调"))
  }
}
