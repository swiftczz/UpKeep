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
  func check(_ applications: [AppRecord]) async -> [AppRecord]
  func update(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws
}

struct UpdateCoordinator: UpdateCoordinating, Sendable {
  private let appStore = AppStoreUpdateProvider()
  private let macAppStore = MacAppStoreUpdateProvider()
  private let homebrew = HomebrewUpdateProvider()
  private let sparkle = SparkleUpdateProvider()
  private let electronBuilder = ElectronBuilderUpdateProvider()
  private let tauri = TauriUpdateProvider()
  private let process: ApplicationProcessClient

  init(process: ApplicationProcessClient = .live) {
    self.process = process
  }

  func check(_ applications: [AppRecord]) async -> [AppRecord] {
    let enrichedApplications = await homebrew.enrich(applications)

    return await withTaskGroup(of: (Int, AppRecord).self) { group in
      for (index, application) in enrichedApplications.enumerated() {
        group.addTask {
          let result: AppRecord
          switch application.source {
          case .appStore:
            result = await appStore.check(application)
          case .sparkle where application.sourceURL != nil:
            result = await sparkle.check(application)
          case .electronBuilder:
            result = await electronBuilder.check(application)
          case .tauri:
            result = await tauri.check(application)
          case .homebrew, .selfManaged, .sparkle:
            result = application
          }
          return (index, result)
        }
      }

      var results = enrichedApplications
      for await (index, application) in group {
        results[index] = application
      }
      return results
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
        try await SparkleApplicationUpdater.upgrade(application, progress: progress)
      case .electronBuilder:
        try await electronBuilder.upgrade(application, progress: progress)
      case .tauri:
        try await tauri.upgrade(application, progress: progress)
      case .selfManaged:
        throw ProcessRunnerError.failed(
          status: 1,
          message: "此应用需要由 \(application.sourceTitle) 完成更新。"
        )
      }
    }
  }
}
