import Darwin
import Foundation
import XCTest

@testable import AppMint

final class UpdateRelaunchTests: XCTestCase {
  func testDoesNotRelaunchWhenApplicationWasNotRunning() async throws {
    let recorder = ProcessRecorder(isRunning: false)
    try await UpdateRelaunch.perform(
      makeApplication(source: .tauri),
      process: recorder.client,
      progress: { _ in }
    ) {}

    let events = recorder.events()
    XCTAssertEqual(events, [])
  }

  func testRelaunchesWhenApplicationWasRunning() async throws {
    let recorder = ProcessRecorder(isRunning: true)
    let application = makeApplication(source: .tauri)
    try await UpdateRelaunch.perform(
      application,
      process: recorder.client,
      progress: { _ in }
    ) {}

    let events = recorder.events()
    XCTAssertEqual(events, [.launch(application.applicationURL)])
  }

  func testDoesNotTreatMissingApplicationBundleAsRunning() {
    let application = makeApplication(source: .sparkle)
    XCTAssertTrue(ApplicationProcess.processIDs(inside: application.applicationURL).isEmpty)
    XCTAssertFalse(ApplicationProcess.isRunning(application))
  }

  func testDetectsCurrentProcessByExecutableDirectory() {
    var buffer = [UInt8](repeating: 0, count: 4096)
    let length = buffer.withUnsafeMutableBufferPointer { pointer in
      proc_pidpath(getpid(), pointer.baseAddress, UInt32(pointer.count))
    }
    XCTAssertGreaterThan(length, 0)

    let processPath = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    let directory = URL(fileURLWithPath: processPath).deletingLastPathComponent()
    XCTAssertTrue(
      ApplicationProcess.processIDs(inside: directory).contains(getpid()),
      "processPath=\(processPath)"
    )
  }

  func testQuitsHomebrewApplicationBeforeUpdatingThenRelaunches() async throws {
    let recorder = ProcessRecorder(isRunning: true)
    let application = makeApplication(source: .homebrew)
    try await UpdateRelaunch.perform(
      application,
      process: recorder.client,
      progress: { _ in }
    ) {}

    let events = recorder.events()
    XCTAssertEqual(
      events,
      [
        .quit(application.bundleIdentifier),
        .launch(application.applicationURL),
      ]
    )
  }

  func testRelaunchesRunningApplicationWhenUpdateFails() async throws {
    let recorder = ProcessRecorder(isRunning: true)
    let application = makeApplication(source: .electronBuilder)

    do {
      try await UpdateRelaunch.perform(
        application,
        process: recorder.client,
        progress: { _ in }
      ) {
        throw ProcessRunnerError.failed(status: 1, message: "failed")
      }
      XCTFail("Expected the update to throw")
    } catch {
      let events = recorder.events()
      XCTAssertEqual(events, [.launch(application.applicationURL)])
    }
  }

  private func makeApplication(source: UpdateSource) -> AppRecord {
    AppRecord(
      name: "Example",
      bundleIdentifier: "com.example.app",
      applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
      currentVersion: "1.0",
      source: source
    )
  }
}

private final class ProcessRecorder: @unchecked Sendable {
  enum Event: Equatable {
    case quit(String)
    case launch(URL)
  }

  private let lock = NSLock()
  private let running: Bool
  private var recorded: [Event] = []

  init(isRunning: Bool) {
    running = isRunning
  }

  var client: ApplicationProcessClient {
    ApplicationProcessClient(
      isRunning: { [running] _ in running },
      quit: { [weak self] application in
        self?.record(.quit(application.bundleIdentifier))
      },
      launch: { [weak self] url in
        self?.record(.launch(url))
      }
    )
  }

  func events() -> [Event] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  private func record(_ event: Event) {
    lock.lock()
    recorded.append(event)
    lock.unlock()
  }
}
