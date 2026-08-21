import Foundation
import Sparkle

enum SparkleApplicationUpdaterError: LocalizedError {
  case invalidApplication(String)
  case insecureFeed
  case updateFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidApplication(let name):
      return "无法读取 \(name) 的应用信息。"
    case .insecureFeed:
      return "此应用没有提供安全的 Sparkle 更新源。"
    case .updateFailed(let message):
      return "Sparkle 更新失败：\(message)"
    }
  }
}

enum SparkleApplicationUpdater {
  static func upgrade(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    try await SparkleUpdateSession.upgrade(application, progress: progress)
  }
}

@MainActor
private final class SparkleUpdateSession: NSObject, SPUUpdaterDelegate {
  private struct VersionSnapshot: Equatable {
    let shortVersion: String?
    let buildVersion: String?
  }

  private let applicationURL: URL
  private let initialVersion: VersionSnapshot?
  private let progressHandler: @Sendable (UpdateProgress) -> Void
  private var userDriver: SparkleProgressUserDriver!
  private var updater: SPUUpdater!
  private var continuation: CheckedContinuation<Void, any Error>?
  private var installationStarted = false

  static func upgrade(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    guard let sourceURL = application.sourceURL, SecureUpdateURL.https(sourceURL) != nil else {
      throw SparkleApplicationUpdaterError.insecureFeed
    }
    guard let bundle = Bundle(url: application.applicationURL) else {
      throw SparkleApplicationUpdaterError.invalidApplication(application.name)
    }

    let session = SparkleUpdateSession(bundle: bundle, progress: progress)
    try await session.run()
  }

  private init(bundle: Bundle, progress: @escaping @Sendable (UpdateProgress) -> Void) {
    applicationURL = bundle.bundleURL
    initialVersion = Self.versionSnapshot(at: bundle.bundleURL)
    progressHandler = progress
    super.init()

    userDriver = SparkleProgressUserDriver(onProgress: progress)
    updater = SPUUpdater(
      hostBundle: bundle,
      applicationBundle: bundle,
      userDriver: userDriver,
      delegate: self
    )
  }

  private func run() async throws {
    progressHandler(.indeterminate("正在检查更新…"))
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation

      do {
        try updater.start()
        updater.checkForUpdates()
      } catch {
        finish(throwing: error)
      }
    }
  }

  func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
    installationStarted = true
    progressHandler(UpdateProgress(fractionCompleted: 0.95, status: "正在安装…"))
  }

  func updater(
    _ updater: SPUUpdater,
    didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
    error: (any Error)?
  ) {
    if let error {
      let nsError = error as NSError
      if Self.isBenignCompletion(nsError) {
        finish()
      } else {
        finish(
          throwing: SparkleApplicationUpdaterError.updateFailed(nsError.localizedDescription)
        )
      }
      return
    }

    guard installationStarted else {
      finish()
      return
    }

    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.waitForInstalledVersion()
      self.progressHandler(UpdateProgress(fractionCompleted: 1, status: "正在完成…"))
      self.finish()
    }
  }

  private func waitForInstalledVersion() async {
    guard let initialVersion else { return }

    for _ in 0..<120 {
      guard !Task.isCancelled else { return }
      if let currentVersion = Self.versionSnapshot(at: applicationURL),
        currentVersion != initialVersion
      {
        return
      }
      try? await Task.sleep(for: .milliseconds(250))
    }
  }

  private func finish(throwing error: (any Error)? = nil) {
    guard let continuation else { return }
    self.continuation = nil

    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume()
    }
  }

  private static func isBenignCompletion(_ error: NSError) -> Bool {
    guard error.domain == SUSparkleErrorDomain else { return false }
    return error.code == 1001 || error.code == 4007
  }

  private static func versionSnapshot(at applicationURL: URL) -> VersionSnapshot? {
    let infoURL = applicationURL
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("Info.plist")

    guard
      let data = try? Data(contentsOf: infoURL, options: .uncached),
      let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let info = propertyList as? [String: Any]
    else {
      return nil
    }

    return VersionSnapshot(
      shortVersion: info["CFBundleShortVersionString"] as? String,
      buildVersion: info["CFBundleVersion"] as? String
    )
  }
}

@MainActor
private final class SparkleProgressUserDriver: NSObject, SPUUserDriver {
  private let onProgress: @Sendable (UpdateProgress) -> Void
  private var expectedContentLength: UInt64 = 0
  private var receivedContentLength: UInt64 = 0

  init(onProgress: @escaping @Sendable (UpdateProgress) -> Void) {
    self.onProgress = onProgress
  }

  func show(
    _ request: SPUUpdatePermissionRequest,
    reply: @escaping (SUUpdatePermissionResponse) -> Void
  ) {
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    onProgress(.indeterminate("正在检查更新…"))
  }

  func showUpdateFound(
    with appcastItem: SUAppcastItem,
    state: SPUUserUpdateState,
    reply: @escaping (SPUUserUpdateChoice) -> Void
  ) {
    if appcastItem.isInformationOnlyUpdate {
      reply(.dismiss)
      return
    }

    onProgress(.indeterminate("准备下载更新…"))
    reply(.install)
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

  func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }

  func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    expectedContentLength = 0
    receivedContentLength = 0
    onProgress(.indeterminate("正在下载…"))
  }

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    self.expectedContentLength = expectedContentLength
    reportDownloadProgress()
  }

  func showDownloadDidReceiveData(ofLength length: UInt64) {
    receivedContentLength += length
    reportDownloadProgress()
  }

  func showDownloadDidStartExtractingUpdate() {
    onProgress(UpdateProgress(fractionCompleted: 0.82, status: "正在解压…"))
  }

  func showExtractionReceivedProgress(_ progress: Double) {
    onProgress(
      UpdateProgress(
        fractionCompleted: 0.82 + (0.1 * UpdateProgress.clamp(progress)),
        status: "正在解压…"
      )
    )
  }

  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    onProgress(UpdateProgress(fractionCompleted: 0.93, status: "准备安装…"))
    reply(.install)
  }

  func showInstallingUpdate(
    withApplicationTerminated applicationTerminated: Bool,
    retryTerminatingApplication: @escaping () -> Void
  ) {
    onProgress(UpdateProgress(fractionCompleted: 0.96, status: "正在安装…"))
  }

  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    onProgress(UpdateProgress(fractionCompleted: 1, status: "正在完成…"))
    acknowledgement()
  }

  func dismissUpdateInstallation() {}

  private func reportDownloadProgress() {
    guard expectedContentLength > 0 else {
      onProgress(.indeterminate("正在下载…"))
      return
    }

    let fraction = min(Double(receivedContentLength) / Double(expectedContentLength), 1) * 0.8
    onProgress(UpdateProgress(fractionCompleted: fraction, status: "正在下载…"))
  }
}
