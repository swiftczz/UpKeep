import CoreGraphics
import Foundation
import QuickLookThumbnailing
import SwiftUI
import Synchronization

struct ApplicationIconClient: Sendable {
    /// Answers synchronously so a view can render an already loaded icon in its first frame.
    var cached: @Sendable (_ applicationURL: URL, _ displayScale: CGFloat) -> CGImage?
    var load: @Sendable (_ applicationURL: URL, _ displayScale: CGFloat) async -> CGImage?

    static func live() -> ApplicationIconClient {
        let cache = ApplicationIconCache()
        return ApplicationIconClient(
            cached: { applicationURL, displayScale in
                cache.cachedIcon(for: applicationURL, displayScale: displayScale)
            },
            load: { applicationURL, displayScale in
                await cache.icon(for: applicationURL, displayScale: displayScale)
            }
        )
    }
}

private actor ApplicationIconCache {
    private struct CacheKey: Hashable {
        let path: String
        let displayScale: Int

        init(_ applicationURL: URL, displayScale: CGFloat) {
            path = applicationURL.standardizedFileURL.path
            self.displayScale = Int((displayScale * 100).rounded())
        }
    }

    private let cachedIcons = Mutex<[CacheKey: CGImage]>([:])
    private var pendingIcons: [CacheKey: Task<CGImage?, Never>] = [:]

    nonisolated func cachedIcon(for applicationURL: URL, displayScale: CGFloat) -> CGImage? {
        let key = CacheKey(applicationURL, displayScale: displayScale)
        return cachedIcons.withLock { $0[key] }
    }

    func icon(for applicationURL: URL, displayScale: CGFloat) async -> CGImage? {
        let key = CacheKey(applicationURL, displayScale: displayScale)

        if let cachedIcon = cachedIcons.withLock({ $0[key] }) {
            return cachedIcon
        }
        if let pendingIcon = pendingIcons[key] {
            return await pendingIcon.value
        }

        let task = Task.detached(priority: .utility) {
            await Self.generateIcon(for: applicationURL, displayScale: displayScale)
        }
        pendingIcons[key] = task

        let icon = await task.value
        pendingIcons[key] = nil
        if let icon {
            cachedIcons.withLock { $0[key] = icon }
        }
        return icon
    }

    private static func generateIcon(
        for applicationURL: URL,
        displayScale: CGFloat
    ) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: applicationURL,
            size: CGSize(width: 128, height: 128),
            scale: max(displayScale, 1),
            representationTypes: .icon
        )

        do {
            return try await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request)
                .cgImage
        } catch {
            return nil
        }
    }
}

private struct ApplicationIconClientKey: EnvironmentKey {
    static let defaultValue = ApplicationIconClient.live()
}

extension EnvironmentValues {
    var applicationIconClient: ApplicationIconClient {
        get { self[ApplicationIconClientKey.self] }
        set { self[ApplicationIconClientKey.self] = newValue }
    }
}
