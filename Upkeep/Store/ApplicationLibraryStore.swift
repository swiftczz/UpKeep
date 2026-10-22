import Foundation

struct ApplicationLibrarySnapshot: Codable, Sendable {
    var lastCheckedAt: Date?
    var applications: [AppRecord]

    mutating func discardUnverifiableReleases() {
        // A lost updater cannot substantiate a pending release from an older app edition.
        for index in applications.indices
        where applications[index].updateConfiguration.mechanism == .selfManaged {
            applications[index].discardRemoteRelease()
        }
    }
}

struct ApplicationLibraryStore: Sendable {
    var load: @Sendable () -> ApplicationLibrarySnapshot?
    var save: @Sendable (ApplicationLibrarySnapshot) -> Void

    static func live(fileManager: FileManager = .default) -> ApplicationLibraryStore {
        let fileURL = snapshotURL(fileManager: fileManager)
        return ApplicationLibraryStore(
            load: {
                guard let data = try? Data(contentsOf: fileURL) else { return nil }
                guard
                    var snapshot = try? JSONDecoder().decode(
                        ApplicationLibrarySnapshot.self, from: data)
                else { return nil }
                snapshot.discardUnverifiableReleases()
                return snapshot
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

    private static func snapshotURL(fileManager: FileManager) -> URL {
        let support =
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        return
            support
            .appendingPathComponent("Upkeep", isDirectory: true)
            .appendingPathComponent("library-snapshot.json")
    }
}
