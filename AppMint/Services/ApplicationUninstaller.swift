import Foundation

enum ApplicationUninstallerError: LocalizedError {
  case nothingSelected
  case applicationStillRunning(String)
  case failed(removedCount: Int, messages: [String])

  var errorDescription: String? {
    switch self {
    case .nothingSelected:
      return "请选择要移除的文件。"
    case .applicationStillRunning(let name):
      return "请先退出 \(name) 后再卸载。"
    case .failed(let removedCount, let messages):
      let detail = messages.prefix(4).joined(separator: "\n")
      if removedCount == 0 {
        return "无法移除选中的文件。\n\(detail)"
      }
      return "已移除 \(removedCount) 项，其余文件未能删除。\n\(detail)"
    }
  }
}

enum ApplicationUninstaller {
  struct Result: Sendable {
    let removedURLs: [URL]
    let didRemoveApplication: Bool
  }

  static func uninstall(
    _ application: AppRecord,
    items: [ApplicationResidueItem],
    fileManager: FileManager = .default,
    process: ApplicationProcessClient = .live,
    brewExecutableURL: URL? = nil
  ) async throws -> Result {
    guard !items.isEmpty else {
      throw ApplicationUninstallerError.nothingSelected
    }

    let removingApplication = items.contains {
      $0.url.standardizedFileURL == application.applicationURL.standardizedFileURL
    }

    if removingApplication, process.isRunning(application.bundleIdentifier) {
      try await process.quit(application)
      if process.isRunning(application.bundleIdentifier) {
        throw ApplicationUninstallerError.applicationStillRunning(application.name)
      }
    }

    if removingApplication,
      application.source == .homebrew,
      let token = application.sourceIdentifier
    {
      try? await uninstallHomebrewCask(token: token, brewExecutableURL: brewExecutableURL)
    }

    var removed: [URL] = []
    var failures: [String] = []

    for item in items {
      let url = item.url.standardizedFileURL
      guard fileManager.fileExists(atPath: url.path) else {
        removed.append(url)
        continue
      }

      do {
        try fileManager.trashItem(at: url, resultingItemURL: nil)
        removed.append(url)
      } catch {
        failures.append("\(item.displayName)：\(error.localizedDescription)")
      }
    }

    if !failures.isEmpty {
      throw ApplicationUninstallerError.failed(
        removedCount: removed.count,
        messages: failures
      )
    }

    return Result(
      removedURLs: removed,
      didRemoveApplication: removingApplication
        && !fileManager.fileExists(atPath: application.applicationURL.path)
    )
  }

  private static func uninstallHomebrewCask(token: String, brewExecutableURL: URL?) async throws {
    let brewURL =
      brewExecutableURL
      ?? [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
      ]
      .map(URL.init(fileURLWithPath:))
      .first { FileManager.default.isExecutableFile(atPath: $0.path) }

    guard let brewURL else { return }
    _ = try await ProcessRunner.run(
      executableURL: brewURL,
      arguments: ["uninstall", "--cask", "--force", token]
    )
  }
}
