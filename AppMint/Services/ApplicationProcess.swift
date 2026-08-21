import AppKit
import Darwin
import Foundation

enum ApplicationProcess {
  static func isRunning(_ application: AppRecord) -> Bool {
    !processIDs(inside: application.applicationURL).isEmpty
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

    await MainActor.run {
      for pid in pids {
        NSRunningApplication(processIdentifier: pid)?.terminate()
      }
    }

    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
      if processIDs(inside: application.applicationURL).isEmpty {
        return
      }
      try await Task.sleep(for: .milliseconds(250))
    }

    throw ApplicationPackageInstallerError.applicationStillRunning(application.name)
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
  var isRunning: @Sendable (AppRecord) -> Bool
  var quit: @Sendable (AppRecord) async throws -> Void
  var launch: @Sendable (URL) async throws -> Void

  static let live = ApplicationProcessClient(
    isRunning: { ApplicationProcess.isRunning($0) },
    quit: { try await ApplicationProcess.quit($0) },
    launch: { try await ApplicationLauncher.live.launch($0) }
  )
}

enum UpdateRelaunch {
  static func perform(
    _ application: AppRecord,
    process: ApplicationProcessClient = .live,
    progress: @escaping @Sendable (UpdateProgress) -> Void,
    operation: () async throws -> Void
  ) async throws {
    let wasRunning = process.isRunning(application)

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
