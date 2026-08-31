import Foundation

struct UpdateProgress: Hashable, Sendable {
  var fractionCompleted: Double?
  var status: String

  static func indeterminate(_ status: String) -> UpdateProgress {
    UpdateProgress(fractionCompleted: nil, status: status)
  }

  var percentText: String? {
    guard let fractionCompleted else { return nil }
    return "\(Int((min(max(fractionCompleted, 0), 1) * 100).rounded()))%"
  }

  static func clamp(_ value: Double) -> Double {
    let normalized = value > 1.0001 ? value / 100 : value
    return min(max(normalized, 0), 1)
  }
}

protocol UpdateCoordinating: Sendable {
  func enrich(_ applications: [AppRecord]) async -> [AppRecord]
  func enrich(
    _ applications: [AppRecord],
    cachePolicy: UpdateCachePolicy
  ) async -> [AppRecord]
  func check(_ application: AppRecord) async -> AppRecord
  func update(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws
}

extension UpdateCoordinating {
  func enrich(
    _ applications: [AppRecord],
    cachePolicy: UpdateCachePolicy
  ) async -> [AppRecord] {
    await enrich(applications)
  }
}

enum UpdateCachePolicy: Sendable {
  case allowed
  case reloadIgnoringCache

  func merging(_ other: UpdateCachePolicy) -> UpdateCachePolicy {
    self == .reloadIgnoringCache || other == .reloadIgnoringCache
      ? .reloadIgnoringCache
      : .allowed
  }
}

struct UpdateCoordinator: UpdateCoordinating, Sendable {
  private let appStore = AppStoreUpdateProvider()
  private let macAppStore = MacAppStoreUpdateProvider()
  private let homebrew = HomebrewUpdateProvider()
  private let sparkle = SparkleUpdateProvider()
  private let electronBuilder = ElectronBuilderUpdateProvider()
  private let tauri = TauriUpdateProvider()
  private let vscode = VSCodeUpdateProvider()
  private let releaseJSON = ReleaseJSONUpdateProvider()
  private let githubReleases = GitHubReleasesUpdateProvider()
  private let process: ApplicationProcessClient

  init(process: ApplicationProcessClient = .live) {
    self.process = process
  }

  func enrich(_ applications: [AppRecord]) async -> [AppRecord] {
    await enrich(applications, cachePolicy: .allowed)
  }

  func enrich(
    _ applications: [AppRecord],
    cachePolicy: UpdateCachePolicy
  ) async -> [AppRecord] {
    await homebrew.enrich(applications, cachePolicy: cachePolicy)
  }

  func check(_ application: AppRecord) async -> AppRecord {
    switch application.source {
    case .appStore:
      return await appStore.check(application)
    case .sparkle where application.sourceURL != nil:
      return await sparkle.check(application)
    case .electronBuilder:
      return await electronBuilder.check(application)
    case .tauri:
      return await tauri.check(application)
    case .vscodeUpdater:
      return await vscode.check(application)
    case .releaseJSON:
      return await releaseJSON.check(application)
    case .githubReleases:
      return await githubReleases.check(application)
    case .homebrew, .selfManaged, .sparkle:
      return application
    }
  }

  func update(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    try await UpdateRelaunch.perform(
      application,
      process: process,
      progress: progress
    ) {
      switch application.source {
      case .homebrew:
        try await homebrew.upgrade(application, progress: progress)
      case .appStore:
        try await macAppStore.upgrade(application, progress: progress)
      case .sparkle:
        try await sparkle.upgrade(application, progress: progress)
      case .electronBuilder:
        try await electronBuilder.upgrade(application, progress: progress)
      case .tauri:
        try await tauri.upgrade(application, progress: progress)
      case .vscodeUpdater:
        try await vscode.upgrade(application, progress: progress)
      case .releaseJSON:
        try await releaseJSON.upgrade(application, progress: progress)
      case .githubReleases:
        try await githubReleases.upgrade(application, progress: progress)
      case .selfManaged:
        throw ProcessRunnerError.failed(
          status: 1,
          message: "此应用没有可自动安装的更新源。"
        )
      }
    }
  }
}
