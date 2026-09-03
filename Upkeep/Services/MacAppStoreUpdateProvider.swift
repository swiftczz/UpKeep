import Foundation

struct MacAppStoreUpdateProvider: Sendable {
  typealias StartUpdate = @Sendable (
    _ adamID: UInt64,
    _ applicationURL: URL,
    _ progress: (@Sendable (UpdateProgress) -> Void)?,
    _ completion: @escaping @Sendable (String?, NSError?) -> Void
  ) -> Void

  private let availability: @Sendable () -> Bool
  private let startUpdate: StartUpdate

  static var isAvailable: Bool {
    AppStoreUpdateSession.isAvailable
  }

  init(
    availability: @escaping @Sendable () -> Bool = { Self.isAvailable },
    startUpdate: @escaping StartUpdate = { adamID, applicationURL, progress, completion in
      let session = AppStoreUpdateSession()
      session.startUpdate(
        adamID: adamID,
        applicationURL: applicationURL,
        progress: progress,
        completion: completion
      )
    }
  ) {
    self.availability = availability
    self.startUpdate = startUpdate
  }

  func upgrade(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    guard application.appStorePlatform == .mac else {
      throw MacAppStoreUpdateError.unsupportedPlatform
    }
    guard let adamID = Self.adamIdentifier(for: application) else {
      throw MacAppStoreUpdateError.missingStoreIdentifier
    }
    guard availability() else {
      throw MacAppStoreUpdateError.unavailable
    }

    progress(.indeterminate("正在准备更新…"))
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      startUpdate(
        adamID,
        application.applicationURL,
        { updateProgress in
          progress(updateProgress)
        },
        { _, error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            progress(UpdateProgress(fractionCompleted: 1, status: "正在完成…"))
            continuation.resume(returning: ())
          }
        }
      )
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
      "当前系统不支持 Upkeep 的 App Store 更新能力。"
    case .unsupportedPlatform:
      "安装在 Mac 上的 iPhone 或 iPad 应用需要通过 App Store 的更新页安装。"
    }
  }
}
