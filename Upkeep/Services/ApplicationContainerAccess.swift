import Foundation

enum ApplicationContainerAccessError: LocalizedError {
  case denied([URL])

  var errorDescription: String? {
    switch self {
    case .denied(let urls):
      let names = urls.prefix(3).map(\.lastPathComponent).joined(separator: "、")
      return "macOS 尚未允许 Upkeep 访问这些应用数据：\(names)。如果“完整磁盘访问”已经打开，请先从授权列表移除旧的 Upkeep，再点“+”选择当前的 /Applications/Upkeep.app，随后彻底退出并重新打开 Upkeep。"
    }
  }
}

enum ApplicationContainerAccess {
  static func requestRemovalAccess(
    to urls: [URL],
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) async throws {
    let roots = Set(
      urls.compactMap {
        protectedContainerRoot(containing: $0, homeDirectory: homeDirectory)
      }
    ).sorted { $0.path < $1.path }
    guard !roots.isEmpty else { return }

    let denied = await Task.detached(priority: .userInitiated) {
      roots.filter { !canReadProtectedContents(of: $0, homeDirectory: homeDirectory) }
    }.value
    guard denied.isEmpty else {
      throw ApplicationContainerAccessError.denied(denied)
    }
  }

  static func isProtectedContainer(
    _ url: URL,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> Bool {
    protectedContainerRoot(containing: url, homeDirectory: homeDirectory) != nil
  }

  static func protectedContainerRoot(containing url: URL, homeDirectory: URL) -> URL? {
    let target = url.standardizedFileURL
    let bases = [
      homeDirectory.appendingPathComponent("Library/Containers", isDirectory: true),
      homeDirectory.appendingPathComponent("Library/Group Containers", isDirectory: true),
    ]

    for base in bases {
      let basePath = base.standardizedFileURL.path
      let prefix = basePath + "/"
      guard target.path.hasPrefix(prefix) else { continue }
      let relativePath = target.path.dropFirst(prefix.count)
      guard let firstComponent = relativePath.split(separator: "/").first else { continue }
      return base.appendingPathComponent(String(firstComponent), isDirectory: true)
        .standardizedFileURL
    }
    return nil
  }

  private static func canReadProtectedContents(of root: URL, homeDirectory: URL) -> Bool {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: root.path) else { return true }

    let containersDirectory = homeDirectory
      .appendingPathComponent("Library/Containers", isDirectory: true)
      .standardizedFileURL.path
    let probeDirectory: URL
    if root.deletingLastPathComponent().standardizedFileURL.path == containersDirectory {
      let dataDirectory = root.appendingPathComponent("Data", isDirectory: true)
      probeDirectory = fileManager.fileExists(atPath: dataDirectory.path) ? dataDirectory : root
    } else {
      probeDirectory = root
    }

    do {
      _ = try fileManager.contentsOfDirectory(
        at: probeDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsSubdirectoryDescendants]
      )
      return true
    } catch {
      return !fileManager.fileExists(atPath: root.path)
    }
  }
}
