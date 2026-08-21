import Foundation

struct MacAppStoreUpdateProvider: Sendable {
  static var isAvailable: Bool {
    AppStoreUpdateSession.isAvailable
  }

  func upgrade(_ application: AppRecord) async throws {
    guard application.appStorePlatform == .mac else {
      throw MacAppStoreUpdateError.unsupportedPlatform
    }
    guard let adamID = Self.adamIdentifier(for: application) else {
      throw MacAppStoreUpdateError.missingStoreIdentifier
    }
    guard Self.isAvailable else {
      throw MacAppStoreUpdateError.unavailable
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      let session = AppStoreUpdateSession()
      session.startUpdate(
        adamID: adamID,
        applicationURL: application.applicationURL,
        progress: nil
      ) { _, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: ())
        }
      }
    }
  }

  static func adamIdentifier(for application: AppRecord) -> UInt64? {
    if let sourceIdentifier = application.sourceIdentifier,
      let identifier = UInt64(sourceIdentifier)
    {
      return identifier
    }

    guard let sourceURL = application.sourceURL else {
      return nil
    }
    return sourceURL.pathComponents.reversed().lazy.compactMap { component in
      guard component.hasPrefix("id") else { return nil }
      return UInt64(component.dropFirst(2))
    }.first
  }
}

private enum MacAppStoreUpdateError: LocalizedError {
  case missingStoreIdentifier
  case unavailable
  case unsupportedPlatform

  var errorDescription: String? {
    switch self {
    case .missingStoreIdentifier:
      "缺少 App Store 应用编号，无法开始更新。"
    case .unavailable:
      "当前系统不支持 AppPulse 的 App Store 更新能力。"
    case .unsupportedPlatform:
      "安装在 Mac 上的 iPhone 或 iPad 应用暂不支持直接更新。"
    }
  }
}
