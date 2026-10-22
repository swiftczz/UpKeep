import AppKit
import CoreGraphics
import Foundation
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
            Self.generateIcon(for: applicationURL, displayScale: displayScale)
        }
        pendingIcons[key] = task

        let icon = await task.value
        pendingIcons[key] = nil
        if let icon {
            cachedIcons.withLock { $0[key] = icon }
        }
        return icon
    }

    /// Reads the bundle's icon through Launch Services. Quick Look thumbnails were
    /// used before, but its agent can stall and leave icons missing indefinitely.
    static func generateIcon(for applicationURL: URL, displayScale: CGFloat) -> CGImage? {
        let image = NSWorkspace.shared.icon(forFile: applicationURL.path)
        var rect = CGRect(x: 0, y: 0, width: 128, height: 128)
        // The rect is in points; the transform picks the representation for this scale.
        let scale = NSAffineTransform()
        scale.scale(by: max(displayScale, 1))
        return image.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: scale])
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
