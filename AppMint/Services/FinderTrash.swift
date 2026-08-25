import Darwin
import Foundation

enum FinderTrashError: LocalizedError {
  case unavailable
  case automationDenied
  case authorizationCancelled
  case unsafeTargets([URL])
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      return "无法启动系统删除操作。"
    case .automationDenied:
      return "AppMint 没有控制 Finder 的权限。请在“系统设置 → 隐私与安全性 → 自动化”中允许 AppMint 控制 Finder 后重试。"
    case .authorizationCancelled:
      return "管理员授权已取消，受保护项目未被删除。"
    case .unsafeTargets(let urls):
      let names = urls.prefix(3).map(\.lastPathComponent).joined(separator: "、")
      return "为保护系统安全，AppMint 拒绝以管理员权限处理这些路径：\(names)"
    case .failed(let message):
      if message.isEmpty {
        return "系统未能将受保护项目移到废纸篓。"
      }
      return "系统未能将受保护项目移到废纸篓：\(message)"
    }
  }
}

enum FinderTrash {
  static func moveToTrash(_ urls: [URL]) async throws {
    let targets = urls.map(\.standardizedFileURL)
    guard !targets.isEmpty else { return }

    var finderError: Error?
    do {
      try await moveUsingFinder(targets)
    } catch {
      finderError = error
    }

    var remaining = targets.filter { FileManager.default.fileExists(atPath: $0.path) }
    guard !remaining.isEmpty else { return }

    let privilegedTargets = remaining.filter {
      !ApplicationContainerAccess.isProtectedContainer($0)
    }
    if !privilegedTargets.isEmpty {
      try await PrivilegedTrash.moveToTrash(privilegedTargets)
    }

    remaining = remaining.filter { FileManager.default.fileExists(atPath: $0.path) }
    guard !remaining.isEmpty else { return }

    let protectedTargets = remaining.filter {
      ApplicationContainerAccess.isProtectedContainer($0)
    }
    if !protectedTargets.isEmpty {
      throw ApplicationContainerAccessError.denied(protectedTargets)
    }

    if let finderError {
      throw finderError
    }
    throw FinderTrashError.failed("授权操作结束后，仍有 \(remaining.count) 项存在。")
  }

  private static func moveUsingFinder(_ urls: [URL]) async throws {
    try await execute(
      finderScriptSource,
      arguments: urls.map(\.path)
    )
  }

  static let finderScriptSource = """
    on run argv
      set failureMessages to {}
      set firstErrorNumber to missing value
      repeat with itemPathReference in argv
        try
          set itemPath to contents of itemPathReference
          set itemReference to POSIX file itemPath
          tell application "Finder" to delete itemReference
        on error errorMessage number errorNumber
          if firstErrorNumber is missing value then set firstErrorNumber to errorNumber
          set end of failureMessages to errorMessage
        end try
      end repeat
      if failureMessages is not {} then
        set previousDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to linefeed
        set combinedMessage to failureMessages as text
        set AppleScript's text item delimiters to previousDelimiters
        error combinedMessage number firstErrorNumber
      end if
    end run
    """

  static func execute(
    _ source: String,
    arguments: [String]
  ) async throws {
    do {
      _ = try await ProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
        arguments: ["-e", source, "--"] + arguments
      )
    } catch let error as ProcessRunnerError {
      throw mapProcessError(error)
    } catch {
      throw FinderTrashError.failed(error.localizedDescription)
    }
  }

  private static func mapProcessError(_ error: ProcessRunnerError) -> FinderTrashError {
    let message = error.localizedDescription
    if message.contains("(-1743)") {
      return .automationDenied
    }
    if message.contains("(-128)") {
      return .authorizationCancelled
    }
    return .failed(cleanAppleScriptMessage(message))
  }

  private static func cleanAppleScriptMessage(_ message: String) -> String {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let range = trimmed.range(of: "execution error: ") else {
      return trimmed
    }
    return String(trimmed[range.upperBound...])
  }
}

enum PrivilegedTrash {
  static func moveToTrash(
    _ urls: [URL],
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    stagingBaseDirectory: URL = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
  ) async throws {
    let targets = urls.map(\.standardizedFileURL)
    let unsafeTargets = targets.filter {
      !isAllowedTarget($0, homeDirectory: homeDirectory)
    }
    guard unsafeTargets.isEmpty else {
      throw FinderTrashError.unsafeTargets(unsafeTargets)
    }

    let stagingDirectory = stagingBaseDirectory.appendingPathComponent(
      ".AppMint-Trash-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: stagingDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )

    var arguments = [
      stagingDirectory.path,
      String(getuid()),
      String(getgid()),
    ]
    for (index, target) in targets.enumerated() {
      let destination = stagingDirectory.appendingPathComponent(
        "\(index + 1)-\(target.lastPathComponent)"
      )
      arguments.append(target.path)
      arguments.append(destination.path)
    }

    do {
      try await FinderTrash.execute(
        privilegedScriptSource,
        arguments: arguments
      )
    } catch let moveError {
      do {
        try finishStagingDirectory(stagingDirectory)
      } catch let stagingError {
        throw FinderTrashError.failed(
          "\(moveError.localizedDescription) 暂存项目位于 \(stagingDirectory.path)：\(stagingError.localizedDescription)"
        )
      }
      throw moveError
    }

    try finishStagingDirectory(stagingDirectory)
  }

  static func isAllowedTarget(_ url: URL, homeDirectory: URL) -> Bool {
    let targetPath = url.standardizedFileURL.path
    let homePath = homeDirectory.standardizedFileURL.path
    let allowedRoots = [
      "/Applications",
      homePath + "/Applications",
      homePath + "/Library",
      "/Library",
      "/var/db/receipts",
      "/opt/homebrew/Caskroom",
      "/usr/local/Caskroom",
    ]
    return allowedRoots.contains { root in
      targetPath != root && targetPath.hasPrefix(root + "/")
    }
  }

  static let privilegedScriptSource = """
    on run argv
      set stagingPath to item 1 of argv
      set ownerID to item 2 of argv
      set groupID to item 3 of argv
      set shellCommands to {"failure=0"}

      set argumentIndex to 4
      repeat while argumentIndex is less than or equal to (count of argv)
        set sourcePath to item argumentIndex of argv
        set destinationPath to item (argumentIndex + 1) of argv
        set end of shellCommands to "/bin/mv -f -- " & quoted form of sourcePath & " " & quoted form of destinationPath & " || failure=1"
        set argumentIndex to argumentIndex + 2
      end repeat
      set end of shellCommands to "/usr/sbin/chown -R " & ownerID & ":" & groupID & " " & quoted form of stagingPath & " || failure=1"
      set end of shellCommands to "exit $failure"

      set previousDelimiters to AppleScript's text item delimiters
      set AppleScript's text item delimiters to linefeed
      set commandText to shellCommands as text
      set AppleScript's text item delimiters to previousDelimiters

      do shell script commandText with prompt "AppMint 需要授权，才能将你确认的受保护项目移到废纸篓。" with administrator privileges
    end run
    """

  private static func finishStagingDirectory(_ url: URL) throws {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path) else { return }
    let children = try fileManager.contentsOfDirectory(atPath: url.path)
    if children.isEmpty {
      try? fileManager.removeItem(at: url)
      return
    }
    try fileManager.trashItem(at: url, resultingItemURL: nil)
  }
}
