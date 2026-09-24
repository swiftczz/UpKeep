import AppKit
import Darwin
import Foundation

enum ApplicationProcessError: LocalizedError {
  case couldNotTerminate(String)

  var errorDescription: String? {
    switch self {
    case .couldNotTerminate(let name):
      return "未能完全结束 \(name) 的后台进程。"
    }
  }
}

enum ApplicationProcess {
  static func isRunning(_ application: AppRecord) async -> Bool {
    await runningApplicationIDs(in: [application]).contains(application.id)
  }

  static func runningApplicationIDs(
    in applications: [AppRecord],
    snapshot: @escaping @Sendable () -> [String] = executablePathSnapshot
  ) async -> Set<AppRecord.ID> {
    guard !applications.isEmpty, !Task.isCancelled else { return [] }
    let worker = Task.detached(priority: .userInitiated) {
      // Resolve every process path once, even when preparing an update for many apps.
      let paths = snapshot()
      var running = Set<AppRecord.ID>()
      for application in applications {
        guard !Task.isCancelled else { return Set<AppRecord.ID>() }
        let root = application.applicationURL.resolvingSymlinksInPath().path
        guard !root.isEmpty else { continue }
        if paths.contains(where: { $0 == root || $0.hasPrefix(root + "/") }) {
          running.insert(application.id)
        }
      }
      return running
    }
    return await withTaskCancellationHandler {
      await worker.value
    } onCancel: {
      worker.cancel()
    }
  }

  private static func executablePathSnapshot() -> [String] {
    var paths: [String] = []
    for pid in allProcessIDs() {
      guard !Task.isCancelled else { return [] }
      let path = processPath(pid)
      if !path.isEmpty { paths.append(path) }
    }
    return paths
  }

  @MainActor
  static func activateHost() {
    NSApp.activate()
  }

  static func quit(_ application: AppRecord) async throws {
    let pids = processIDs(inside: application.applicationURL)
    guard !pids.isEmpty else {
      return
    }

    let applicationRoot = application.applicationURL.resolvingSymlinksInPath()
    let helperPIDs = await MainActor.run {
      var helperPIDs: [pid_t] = []
      for pid in pids {
        guard let runningApplication = NSRunningApplication(processIdentifier: pid) else {
          helperPIDs.append(pid)
          continue
        }
        if runningApplication.bundleURL?.resolvingSymlinksInPath() == applicationRoot {
          runningApplication.terminate()
        } else {
          helperPIDs.append(pid)
        }
      }
      return helperPIDs
    }
    sendSignal(SIGTERM, to: helperPIDs, inside: application.applicationURL)

    if try await waitUntilStopped(application.applicationURL, timeout: 5) {
      return
    }

    sendSignal(
      SIGTERM,
      to: processIDs(inside: application.applicationURL),
      inside: application.applicationURL
    )
    if try await waitUntilStopped(application.applicationURL, timeout: 3) {
      return
    }

    sendSignal(
      SIGKILL,
      to: processIDs(inside: application.applicationURL),
      inside: application.applicationURL
    )
    if try await waitUntilStopped(application.applicationURL, timeout: 2) {
      return
    }

    throw ApplicationProcessError.couldNotTerminate(application.name)
  }

  static func processIDs(inside applicationURL: URL) -> [pid_t] {
    let root = applicationURL.resolvingSymlinksInPath().path
    guard !root.isEmpty else {
      return []
    }

    return allProcessIDs().filter { pid in
      let path = processPath(pid)
      return path == root || path.hasPrefix(root + "/")
    }
  }

  private static func sendSignal(
    _ signal: Int32,
    to pids: [pid_t],
    inside applicationURL: URL
  ) {
    let root = applicationURL.resolvingSymlinksInPath().path
    guard !root.isEmpty else { return }

    for pid in pids where pid != getpid() {
      let path = processPath(pid)
      guard path == root || path.hasPrefix(root + "/") else { continue }
      _ = Darwin.kill(pid, signal)
    }
  }

  private static func waitUntilStopped(_ applicationURL: URL, timeout: TimeInterval) async throws
    -> Bool
  {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if processIDs(inside: applicationURL).isEmpty {
        return true
      }
      try await Task.sleep(for: .milliseconds(200))
    }
    return processIDs(inside: applicationURL).isEmpty
  }

  private static func allProcessIDs() -> [pid_t] {
    var estimatedCount = max(Int(proc_listallpids(nil, 0)), 256)
    for _ in 0..<3 {
      var pids = [pid_t](repeating: 0, count: estimatedCount + 32)
      let filled = pids.withUnsafeMutableBufferPointer { buffer in
        proc_listallpids(
          buffer.baseAddress,
          Int32(buffer.count * MemoryLayout<pid_t>.stride)
        )
      }
      guard filled > 0 else {
        return []
      }
      let count = Int(filled)
      if count >= pids.count {
        estimatedCount = count + 32
        continue
      }
      return pids.prefix(count).filter { $0 > 0 }
    }
    return []
  }

  private static func processPath(_ pid: pid_t) -> String {
    var buffer = [UInt8](repeating: 0, count: Int(4 * MAXPATHLEN))
    let length = buffer.withUnsafeMutableBufferPointer { pointer in
      proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
    }
    guard length > 0 else {
      return ""
    }
    let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }
}

struct ApplicationProcessClient: Sendable {
  var isRunning: @Sendable (AppRecord) async -> Bool
  var runningApplicationIDs: @Sendable ([AppRecord]) async -> Set<AppRecord.ID>
  var quit: @Sendable (AppRecord) async throws -> Void
  var launch: @Sendable (URL) async throws -> Void

  init(
    isRunning: @escaping @Sendable (AppRecord) async -> Bool,
    quit: @escaping @Sendable (AppRecord) async throws -> Void,
    launch: @escaping @Sendable (URL) async throws -> Void,
    runningApplicationIDs: (@Sendable ([AppRecord]) async -> Set<AppRecord.ID>)? = nil
  ) {
    self.isRunning = isRunning
    self.quit = quit
    self.launch = launch
    self.runningApplicationIDs = runningApplicationIDs ?? { applications in
      var running = Set<AppRecord.ID>()
      for application in applications {
        guard !Task.isCancelled else { return [] }
        if await isRunning(application) { running.insert(application.id) }
      }
      return running
    }
  }

  static let live = ApplicationProcessClient(
    isRunning: { await ApplicationProcess.isRunning($0) },
    quit: { try await ApplicationProcess.quit($0) },
    launch: { try await ApplicationLauncher.live.launch($0) },
    runningApplicationIDs: { await ApplicationProcess.runningApplicationIDs(in: $0) }
  )
}

enum UpdateRelaunch {
  static func perform(
    _ application: AppRecord,
    process: ApplicationProcessClient = .live,
    progress: @escaping @Sendable (UpdateProgress) -> Void,
    operation: () async throws -> Void
  ) async throws {
    let wasRunning = await process.isRunning(application)
    try Task.checkCancellation()

    func restoreIfNeeded() async {
      guard wasRunning else { return }
      progress(.indeterminate("正在重新打开…"))
      try? await process.launch(application.applicationURL)
    }

    do {
      if wasRunning, application.source == .homebrew {
        progress(.indeterminate("正在退出…"))
        try await process.quit(application)
      }
      try await operation()
      await restoreIfNeeded()
    } catch {
      await restoreIfNeeded()
      throw error
    }
  }
}
