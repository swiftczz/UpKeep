import Foundation

enum ApplicationUninstallerError: LocalizedError {
  case nothingSelected
  case applicationStillRunning(String)
  case failed(removedCount: Int, itemNames: [String], reason: String)

  var errorDescription: String? {
    switch self {
    case .nothingSelected:
      return "请选择要移除的文件。"
    case .applicationStillRunning(let name):
      return "\(name) 仍有后台进程未能结束。请稍后重试，或在“活动监视器”中结束相关进程后再卸载。"
    case .failed(let removedCount, let itemNames, let reason):
      let visibleNames = itemNames.prefix(5).joined(separator: "、")
      let remainingCount = itemNames.count - min(itemNames.count, 5)
      let suffix = remainingCount > 0 ? "，另有 \(remainingCount) 项" : ""
      let detail = "未移除：\(visibleNames)\(suffix)\n\(reason)"
      if removedCount == 0 {
        return "无法移除选中的文件。\n\(detail)"
      }
      return "已移除 \(removedCount) 项，其余文件未能删除。\n\(detail)"
    }
  }
}

enum ApplicationUninstaller {
  struct TrashClient: @unchecked Sendable {
    var moveDirectly: (URL) throws -> Void
    var moveUsingFinder: ([URL]) async throws -> Void

    static func live(fileManager: FileManager) -> TrashClient {
      TrashClient(
        moveDirectly: { url in
          try fileManager.trashItem(at: url, resultingItemURL: nil)
        },
        moveUsingFinder: { urls in
          try await FinderTrash.moveToTrash(urls)
        }
      )
    }
  }

  struct Result: Sendable {
    let didRemoveApplication: Bool
  }

  static func uninstall(
    _ application: AppRecord,
    items: [ApplicationResidueItem],
    fileManager: FileManager = .default,
    process: ApplicationProcessClient = .live,
    brewExecutableURL: URL? = nil,
    trashClient: TrashClient? = nil
  ) async throws -> Result {
    guard !items.isEmpty else {
      throw ApplicationUninstallerError.nothingSelected
    }

    let removingApplication = items.contains {
      $0.url.standardizedFileURL == application.applicationURL.standardizedFileURL
    }

    if process.isRunning(application) {
      do {
        try await process.quit(application)
      } catch is ApplicationProcessError {
        throw ApplicationUninstallerError.applicationStillRunning(application.name)
      }
      if process.isRunning(application) {
        throw ApplicationUninstallerError.applicationStillRunning(application.name)
      }
    }

    try await ApplicationContainerAccess.requestRemovalAccess(
      to: items.map(\.url)
    )

    if removingApplication,
      application.source == .homebrew,
      let token = application.sourceIdentifier
    {
      try? await uninstallHomebrewCask(token: token, brewExecutableURL: brewExecutableURL)
    }

    let trashClient = trashClient ?? .live(fileManager: fileManager)
    var removedCount = 0
    var finderCandidates: [(item: ApplicationResidueItem, directError: Error)] = []

    for item in items {
      let url = item.url.standardizedFileURL
      guard fileManager.fileExists(atPath: url.path) else {
        removedCount += 1
        continue
      }

      do {
        try trashClient.moveDirectly(url)
        if fileManager.fileExists(atPath: url.path) {
          finderCandidates.append(
            (item, CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]))
          )
        } else {
          removedCount += 1
        }
      } catch {
        finderCandidates.append((item, error))
      }
    }

    var finderError: Error?
    if !finderCandidates.isEmpty {
      do {
        try await trashClient.moveUsingFinder(finderCandidates.map { $0.item.url })
      } catch {
        finderError = error
      }
    }

    var failures: [(item: ApplicationResidueItem, directError: Error)] = []
    for candidate in finderCandidates {
      let url = candidate.item.url.standardizedFileURL
      if fileManager.fileExists(atPath: url.path) {
        failures.append(candidate)
      } else {
        removedCount += 1
      }
    }

    if failures.isEmpty, let finderError {
      throw finderError
    }

    if !failures.isEmpty {
      throw ApplicationUninstallerError.failed(
        removedCount: removedCount,
        itemNames: failures.map { $0.item.displayName },
        reason: (finderError ?? failures[0].directError).localizedDescription
      )
    }

    return Result(
      didRemoveApplication: removingApplication
        && !fileManager.fileExists(atPath: application.applicationURL.path)
    )
  }

  private static func uninstallHomebrewCask(token: String, brewExecutableURL: URL?) async throws {
    let brewURL = brewExecutableURL ?? HomebrewCLI.executableURL

    guard let brewURL else { return }
    _ = try await ProcessRunner.run(
      executableURL: brewURL,
      arguments: ["uninstall", "--cask", "--force", token]
    )
  }
}
