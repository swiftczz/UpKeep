import Foundation

enum FinderTrashError: LocalizedError {
  case automationDenied
  case authorizationCancelled
  case unsafeTargets([URL])
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .automationDenied:
      return "AppMint 没有控制 Finder 的权限。请在“系统设置 → 隐私与安全性 → 自动化”中允许 AppMint 控制 Finder 后重试。"
    case .authorizationCancelled:
      return "系统删除操作已取消，选中的项目未被删除。"
    case .unsafeTargets(let urls):
      let names = urls.prefix(3).map(\.lastPathComponent).joined(separator: "、")
      return "为保护系统安全，AppMint 拒绝处理这些路径：\(names)"
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

    let groups = partitionTargets(targets)
    let directTargets = groups.unprotected.filter {
      UserTrashMove.isDarwinVolatileTarget($0)
    }
    if !directTargets.isEmpty {
      try await UserTrashMove.moveToTrash(directTargets)
    }

    let finderTargets = groups.unprotected.filter {
      !directTargets.contains($0)
    }
    if !finderTargets.isEmpty {
      try await FinderBatchTrash.moveToTrash(finderTargets)
    }

    let remaining = targets.filter { FileManager.default.fileExists(atPath: $0.path) }
    guard !remaining.isEmpty else { return }

    let protectedTargets = remaining.filter {
      ApplicationContainerAccess.isProtectedContainer($0)
    }
    if !protectedTargets.isEmpty {
      throw ApplicationContainerAccessError.denied(protectedTargets)
    }

    throw FinderTrashError.failed("系统删除操作结束后，仍有 \(remaining.count) 项存在。")
  }

  static func partitionTargets(
    _ urls: [URL],
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> (unprotected: [URL], protected: [URL]) {
    let targets = urls.map(\.standardizedFileURL)
    return (
      unprotected: targets.filter {
        !ApplicationContainerAccess.isProtectedContainer($0, homeDirectory: homeDirectory)
      },
      protected: targets.filter {
        ApplicationContainerAccess.isProtectedContainer($0, homeDirectory: homeDirectory)
      }
    )
  }

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

enum UserTrashMove {
  static func moveToTrash(
    _ urls: [URL],
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory,
    fileManager: FileManager = .default
  ) async throws {
    let targets = urls.map(\.standardizedFileURL)
    let unsafeTargets = targets.filter {
      !isDarwinVolatileTarget($0, temporaryDirectory: temporaryDirectory)
    }
    guard unsafeTargets.isEmpty else {
      throw FinderTrashError.unsafeTargets(unsafeTargets)
    }

    let existingTargets = targets.filter { fileManager.fileExists(atPath: $0.path) }
    guard !existingTargets.isEmpty else { return }

    let trashBundle = try makeTrashBundleDirectory(
      homeDirectory: homeDirectory,
      fileManager: fileManager
    )
    var usedNames: [String: Int] = [:]

    for target in existingTargets {
      let destination = nextDestination(
        for: target,
        in: trashBundle,
        usedNames: &usedNames,
        fileManager: fileManager
      )
      _ = try await ProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/bin/mv"),
        arguments: [target.path, destination.path]
      )
    }
  }

  static func isDarwinVolatileTarget(
    _ url: URL,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) -> Bool {
    let targetPath = url.resolvingSymlinksInPath().standardizedFileURL.path
    let temporaryPath =
      temporaryDirectory
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path
    let darwinCachePath =
      temporaryDirectory
      .resolvingSymlinksInPath()
      .deletingLastPathComponent()
      .appendingPathComponent("C", isDirectory: true)
      .standardizedFileURL
      .path

    return [temporaryPath, darwinCachePath].contains { root in
      targetPath != root && targetPath.hasPrefix(root + "/")
    }
  }

  private static func makeTrashBundleDirectory(
    homeDirectory: URL,
    fileManager: FileManager
  ) throws -> URL {
    let trashDirectory = homeDirectory.appendingPathComponent(".Trash", isDirectory: true)
    try fileManager.createDirectory(
      at: trashDirectory,
      withIntermediateDirectories: true
    )

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let bundleName = "AppMint_\(formatter.string(from: Date()))_\(UUID().uuidString)"
    let bundle = trashDirectory.appendingPathComponent(bundleName, isDirectory: true)
    try fileManager.createDirectory(
      at: bundle,
      withIntermediateDirectories: false
    )
    return bundle
  }

  private static func nextDestination(
    for target: URL,
    in trashBundle: URL,
    usedNames: inout [String: Int],
    fileManager: FileManager
  ) -> URL {
    let baseName = target.lastPathComponent
    var index = usedNames[baseName] ?? 0
    var name = baseName

    while fileManager.fileExists(atPath: trashBundle.appendingPathComponent(name).path) {
      index += 1
      name = "\(baseName)-\(index)"
    }

    usedNames[baseName] = index
    return trashBundle.appendingPathComponent(name)
  }

}

enum FinderBatchTrash {
  static func moveToTrash(
    _ urls: [URL],
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) async throws {
    let targets = urls.map(\.standardizedFileURL)
    let unsafeTargets = targets.filter {
      !isAllowedTarget($0, homeDirectory: homeDirectory)
    }
    guard unsafeTargets.isEmpty else {
      throw FinderTrashError.unsafeTargets(unsafeTargets)
    }

    try await FinderTrash.execute(
      scriptSource,
      arguments: targets.map(\.path)
    )
  }

  static func isAllowedTarget(
    _ url: URL,
    homeDirectory: URL
  ) -> Bool {
    if ApplicationContainerAccess.isProtectedContainer(url, homeDirectory: homeDirectory) {
      return false
    }

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

  static let scriptSource = """
    on run argv
      set targetItems to {}
      repeat with targetPath in argv
        set end of targetItems to (POSIX file (targetPath as text))
      end repeat

      tell application "Finder"
        delete targetItems
      end tell
    end run
    """
}
