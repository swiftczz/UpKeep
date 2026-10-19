import Darwin
import Foundation
import XCTest

@testable import Upkeep

final class UpdateRelaunchTests: XCTestCase {
  func testDoesNotRelaunchWhenApplicationWasNotRunning() async throws {
    let recorder = ProcessRecorder(isRunning: false)
    try await UpdateRelaunch.perform(
      makeApplication(mechanism: .tauri),
      process: recorder.client,
      progress: { _ in },
      operation: {}
    )

    let events = recorder.events()
    XCTAssertEqual(events, [])
  }

  func testRelaunchesWhenApplicationWasRunning() async throws {
    let recorder = ProcessRecorder(isRunning: true)
    let application = makeApplication(mechanism: .tauri)
    try await UpdateRelaunch.perform(
      application,
      process: recorder.client,
      progress: { _ in },
      operation: {}
    )

    let events = recorder.events()
    XCTAssertEqual(events, [.launch(application.applicationURL)])
  }

  func testDoesNotTreatMissingApplicationBundleAsRunning() async {
    let application = makeApplication(mechanism: .sparkle)
    XCTAssertTrue(ApplicationProcess.processIDs(inside: application.applicationURL).isEmpty)
    let isRunning = await ApplicationProcess.isRunning(application)
    XCTAssertFalse(isRunning)
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

  func testTerminatesOrphanedHelperInsideApplicationBundle() async throws {
    let fileManager = FileManager.default
    let applicationURL = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepProcess-\(UUID().uuidString)/Demo.app", isDirectory: true)
    let resourcesURL = applicationURL.appendingPathComponent(
      "Contents/Resources", isDirectory: true)
    let helperURL = resourcesURL.appendingPathComponent("DemoHelper")
    try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
    try fileManager.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: helperURL)

    let helper = Process()
    helper.executableURL = helperURL
    helper.arguments = ["30"]
    helper.standardOutput = FileHandle.nullDevice
    helper.standardError = FileHandle.nullDevice
    try helper.run()
    defer {
      if helper.isRunning {
        _ = Darwin.kill(helper.processIdentifier, SIGKILL)
      }
      try? fileManager.removeItem(at: applicationURL.deletingLastPathComponent())
    }

    for _ in 0..<20 {
      if ApplicationProcess.processIDs(inside: applicationURL).contains(helper.processIdentifier) {
        break
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(
      ApplicationProcess.processIDs(inside: applicationURL).contains(helper.processIdentifier)
    )

    let application = AppRecord(
      name: "Demo",
      bundleIdentifier: "com.example.demo",
      applicationURL: applicationURL,
      currentVersion: "1.0",
      updateConfiguration: UpdateConfiguration(mechanism: .selfManaged)
    )
    let isRunning = await ApplicationProcess.isRunning(application)
    XCTAssertFalse(isRunning, "An orphaned helper must not cause the main app to relaunch")
    let hasRunningProcesses = await ApplicationProcess.hasRunningProcesses(application)
    XCTAssertTrue(hasRunningProcesses)

    try await ApplicationProcess.quit(application)
    for _ in 0..<40 where helper.isRunning {
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertFalse(helper.isRunning)
  }

  func testDetectsRunningMainExecutableWithDifferentBundleName() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("UpkeepMainProcess-\(UUID().uuidString)")
    let applicationURL = root.appendingPathComponent("Renamed.app")
    let executable = applicationURL.appendingPathComponent("Contents/MacOS/ActualExecutable")
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
    let info: [String: Any] = [
      "CFBundleIdentifier": "com.example.main",
      "CFBundleExecutable": "ActualExecutable", "CFBundlePackageType": "APPL",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: applicationURL.appendingPathComponent("Contents/Info.plist"))
    let process = Process()
    process.executableURL = executable
    process.arguments = ["30"]
    try process.run()
    defer {
      if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
      try? FileManager.default.removeItem(at: root)
    }
    let application = AppRecord(
      name: "Display Name",
      bundleIdentifier: "com.example.main",
      applicationURL: applicationURL,
      currentVersion: "1.0",
      updateConfiguration: UpdateConfiguration(mechanism: .selfManaged)
    )
    var running = false
    for _ in 0..<20 {
      running = await ApplicationProcess.isRunning(application)
      if running { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(running)
    try await ApplicationProcess.quit(application)
    let afterQuit = await ApplicationProcess.isRunning(application)
    XCTAssertFalse(afterQuit)
  }

  func testQuitsHomebrewApplicationBeforeUpdatingThenRelaunches() async throws {
    let recorder = ProcessRecorder(isRunning: true)
    let application = makeApplication(mechanism: .homebrew)
    try await UpdateRelaunch.perform(
      application,
      process: recorder.client,
      progress: { _ in },
      operation: {}
    )

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
    let application = makeApplication(mechanism: .electronBuilder)

    do {
      try await UpdateRelaunch.perform(
        application,
        process: recorder.client,
        progress: { _ in },
        operation: {
          throw ProcessRunnerError.failed(status: 1, message: "failed")
        }
      )
      XCTFail("Expected the update to throw")
    } catch {
      let events = recorder.events()
      XCTAssertEqual(events, [.launch(application.applicationURL)])
    }
  }

  func testHomebrewStopsBackgroundProcessesWithoutOpeningClosedMainApp() async throws {
    let recorder = ProcessRecorder(isRunning: false)
    var process = recorder.client
    process.hasRunningProcesses = { _ in true }
    let application = makeApplication(mechanism: .homebrew)
    try await UpdateRelaunch.perform(
      application, process: process, progress: { _ in }, operation: {})
    XCTAssertEqual(recorder.events(), [.quit(application.bundleIdentifier)])
  }

  private func makeApplication(mechanism: UpdateMechanism) -> AppRecord {
    AppRecord(
      name: "Example",
      bundleIdentifier: "com.example.app",
      applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
      currentVersion: "1.0",
      updateConfiguration: UpdateConfiguration(mechanism: mechanism)
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
