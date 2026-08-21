import Foundation

struct ApplicationLibrarySnapshot: Codable, Sendable {
  var lastCheckedAt: Date?
  var applications: [AppRecord]
}

struct ApplicationLibraryStore: Sendable {
  var load: @Sendable () -> ApplicationLibrarySnapshot?
  var save: @Sendable (ApplicationLibrarySnapshot) -> Void

  static func live(fileManager: FileManager = .default) -> ApplicationLibraryStore {
    let fileURL = snapshotURL(fileManager: fileManager)
    return ApplicationLibraryStore(
      load: {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ApplicationLibrarySnapshot.self, from: data)
      },
      save: { snapshot in
        do {
          try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.sortedKeys]
          let data = try encoder.encode(snapshot)
          try data.write(to: fileURL, options: [.atomic])
        } catch {}
      }
    )
  }

  static func memory() -> ApplicationLibraryStore {
    let box = SnapshotBox()
    return ApplicationLibraryStore(
      load: { box.snapshot },
      save: { box.snapshot = $0 }
    )
  }

  private static func snapshotURL(fileManager: FileManager) -> URL {
    let support =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    return support
      .appendingPathComponent("AppMint", isDirectory: true)
      .appendingPathComponent("library-snapshot.json")
  }
}

private final class SnapshotBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: ApplicationLibrarySnapshot?

  var snapshot: ApplicationLibrarySnapshot? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
    set {
      lock.lock()
      storage = newValue
      lock.unlock()
    }
  }
}
