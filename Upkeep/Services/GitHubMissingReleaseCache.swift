import Foundation

/// Only caches 404s from inferred Craft endpoints, never rate limits or network errors.
actor GitHubMissingReleaseCache {
    static let shared = GitHubMissingReleaseCache(fileURL: cacheURL)
    static let lifetime: TimeInterval = 60 * 60

    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private var entries: [String: Date]

    init(fileURL: URL? = nil, now: @escaping @Sendable () -> Date = { .now }) {
        self.fileURL = fileURL
        self.now = now
        if let fileURL,
            let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size <= 64_000,
            let data = try? Data(contentsOf: fileURL),
            let entries = try? JSONDecoder().decode([String: Date].self, from: data)
        {
            self.entries = entries
        } else {
            entries = [:]
        }
    }

    func contains(_ url: URL) -> Bool {
        guard let expiry = entries[url.absoluteString] else { return false }
        let date = now()
        guard expiry > date, expiry <= date.addingTimeInterval(Self.lifetime) else {
            entries.removeValue(forKey: url.absoluteString)
            return false
        }
        return true
    }

    func remember(_ url: URL) {
        guard !Task.isCancelled else { return }
        let date = now()
        entries = entries.filter { $0.value > date }
        if entries.count >= 128, let oldest = entries.min(by: { $0.value < $1.value })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[url.absoluteString] = date.addingTimeInterval(Self.lifetime)
        persist()
    }

    func remove(_ url: URL) {
        if entries.removeValue(forKey: url.absoluteString) != nil { persist() }
    }

    func invalidate() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {}
    }

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Upkeep", isDirectory: true)
            .appendingPathComponent("missing-craft-releases.json")
    }
}
