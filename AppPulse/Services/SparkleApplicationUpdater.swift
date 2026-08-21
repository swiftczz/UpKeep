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
  static func upgrade(_ application: AppRecord) async throws {
    try await SparkleUpdateSession.upgrade(application)
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
  private var userDriver: SPUStandardUserDriver!
  private var updater: SPUUpdater!
  private var continuation: CheckedContinuation<Void, any Error>?
  private var installationStarted = false

  static func upgrade(_ application: AppRecord) async throws {
    guard application.sourceURL?.scheme?.lowercased() == "https" else {
      throw SparkleApplicationUpdaterError.insecureFeed
    }
    guard let bundle = Bundle(url: application.applicationURL) else {
      throw SparkleApplicationUpdaterError.invalidApplication(application.name)
    }

    let session = SparkleUpdateSession(bundle: bundle)
    try await session.run()
  }

  private init(bundle: Bundle) {
    applicationURL = bundle.bundleURL
    initialVersion = Self.versionSnapshot(at: bundle.bundleURL)
    super.init()

    userDriver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
    updater = SPUUpdater(
      hostBundle: bundle,
      applicationBundle: bundle,
      userDriver: userDriver,
      delegate: self
    )
  }

  private func run() async throws {
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
      let data = try? Data(contentsOf: infoURL),
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
