import Foundation

enum ApplicationProcess {
  static func isRunning(bundleIdentifier: String) -> Bool {
    guard
      let output = try? ProcessRunner.blockingRun(
        executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
        arguments: [
          "-e",
          "tell application \"System Events\" to (exists process whose bundle identifier is \"\(bundleIdentifier)\")",
        ]
      )
    else {
      return false
    }
    return output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      .localizedCaseInsensitiveContains("true")
  }

  static func quit(_ application: AppRecord) async throws {
    guard isRunning(bundleIdentifier: application.bundleIdentifier) else {
      return
    }

    try? await ProcessRunner.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
      arguments: [
        "-e",
        "tell application id \"\(application.bundleIdentifier)\" to quit",
      ]
    )

    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
      if !isRunning(bundleIdentifier: application.bundleIdentifier) {
        return
      }
      try await Task.sleep(for: .milliseconds(250))
    }

    throw ApplicationPackageInstallerError.applicationStillRunning(application.name)
  }
}

struct ApplicationProcessClient: Sendable {
  var isRunning: @Sendable (String) -> Bool
  var quit: @Sendable (AppRecord) async throws -> Void
  var launch: @Sendable (URL) async throws -> Void

  static let live = ApplicationProcessClient(
    isRunning: { ApplicationProcess.isRunning(bundleIdentifier: $0) },
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
    let wasRunning = process.isRunning(application.bundleIdentifier)

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
