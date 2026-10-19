import Foundation

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
    private let customAPIUpdate = CustomAPIUpdateProvider()
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
        if cachePolicy == .reloadIgnoringCache {
            await githubReleases.invalidateMissingReleaseCache()
        }
        return await homebrew.enrich(applications, cachePolicy: cachePolicy)
    }

    func check(_ application: AppRecord) async -> AppRecord {
        if application.updateConfiguration.mechanism == .homebrew,
            let alternate = application.alternateUpdateCheckRecord
        {
            let checked: AppRecord
            switch alternate.updateConfiguration.mechanism {
            case .sparkle:
                checked = await sparkle.check(alternate, fallbackNotes: application)
            case .tauri:
                checked = await tauri.check(alternate, fallbackNotes: application)
            default:
                checked = await checkUsingMechanism(alternate)
            }
            return HomebrewUpdateProvider.mergeAlternateCheckResult(
                checked,
                intoHomebrew: application
            )
        }

        return await checkUsingMechanism(application)
    }

    private func checkUsingMechanism(_ application: AppRecord) async -> AppRecord {
        switch application.updateConfiguration.mechanism {
        case .appStore:
            return await appStore.check(application)
        case .sparkle where application.updateConfiguration.feedURL != nil:
            return await sparkle.check(application)
        case .electronBuilder:
            return await electronBuilder.check(application)
        case .tauri:
            return await tauri.check(application)
        case .vscodeUpdater:
            return await vscode.check(application)
        case .customAPI:
            return await customAPIUpdate.check(application)
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
            switch application.updateConfiguration.mechanism {
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
            case .customAPI:
                try await customAPIUpdate.upgrade(application, progress: progress)
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
