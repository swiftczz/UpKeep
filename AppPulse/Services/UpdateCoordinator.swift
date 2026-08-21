import Foundation

protocol UpdateCoordinating: Sendable {
  func check(_ applications: [AppRecord]) async -> [AppRecord]
  func update(_ application: AppRecord) async throws
}

struct UpdateCoordinator: UpdateCoordinating, Sendable {
  private let appStore = AppStoreUpdateProvider()
  private let homebrew = HomebrewUpdateProvider()
  private let sparkle = SparkleUpdateProvider()

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
          case .homebrew, .github, .selfManaged, .sparkle:
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

  func update(_ application: AppRecord) async throws {
    switch application.source {
    case .homebrew:
      try await homebrew.upgrade(application)
    case .appStore, .sparkle, .github, .selfManaged:
      throw ProcessRunnerError.failed(
        status: 1,
        message: "此应用需要由 \(application.sourceTitle) 完成更新。"
      )
    }
  }
}
