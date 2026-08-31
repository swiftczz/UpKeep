import CoreGraphics
import Foundation
import QuickLookThumbnailing
import SwiftUI

struct ApplicationIconClient: Sendable {
  var load: @Sendable (_ applicationURL: URL, _ displayScale: CGFloat) async -> CGImage?

  static func live() -> ApplicationIconClient {
    let cache = ApplicationIconCache()
    return ApplicationIconClient { applicationURL, displayScale in
      await cache.icon(for: applicationURL, displayScale: displayScale)
    }
  }
}

private actor ApplicationIconCache {
  private struct CacheKey: Hashable {
    let path: String
    let displayScale: Int
  }

  private var cachedIcons: [CacheKey: CGImage] = [:]
  private var pendingIcons: [CacheKey: Task<CGImage?, Never>] = [:]

  func icon(for applicationURL: URL, displayScale: CGFloat) async -> CGImage? {
    let key = CacheKey(
      path: applicationURL.standardizedFileURL.path,
      displayScale: Int((displayScale * 100).rounded())
    )

    if let cachedIcon = cachedIcons[key] {
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
      cachedIcons[key] = icon
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
