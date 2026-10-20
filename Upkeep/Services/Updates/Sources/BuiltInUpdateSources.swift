import Foundation

// Adapters from the protocol-specific providers to `UpdateSourceProvider`.
// The providers keep their own APIs; these types only describe how the
// coordinator reaches them.

struct AppStoreUpdateSource: UpdateSourceProvider {
    var checker = AppStoreUpdateProvider()
    var installer = MacAppStoreUpdateProvider()
    var mechanism: UpdateMechanism { .appStore }

    func check(_ application: AppRecord, fallbackNotes: AppRecord?) async -> AppRecord {
        await checker.check(application)
    }

    func upgrade(
        _ application: AppRecord, progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws {
        try await installer.upgrade(application, progress: progress)
    }
}

/// Casks are checked in bulk by the enricher; individual records only install.
struct HomebrewUpdateSource: UpdateSourceProvider {
    var provider = HomebrewUpdateProvider()
    var mechanism: UpdateMechanism { .homebrew }

    func check(_ application: AppRecord, fallbackNotes: AppRecord?) async -> AppRecord {
        application
    }

    func upgrade(
        _ application: AppRecord, progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws {
        try await provider.upgrade(application, progress: progress)
    }
}

extension HomebrewUpdateProvider: UpdateLibraryEnricher {}

struct SparkleUpdateSource: UpdateSourceProvider {
    var provider = SparkleUpdateProvider()
    var mechanism: UpdateMechanism { .sparkle }

    func check(_ application: AppRecord, fallbackNotes: AppRecord?) async -> AppRecord {
        // An embedded Sparkle framework without a feed has nothing to check.
        guard application.updateConfiguration.feedURL != nil else { return application }
        return await provider.check(application, fallbackNotes: fallbackNotes)
    }

    func upgrade(
        _ application: AppRecord, progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws {
        try await provider.upgrade(application, progress: progress)
    }
}

struct ElectronBuilderUpdateSource: UpdateSourceProvider {
    var provider = ElectronBuilderUpdateProvider()
    var mechanism: UpdateMechanism { .electronBuilder }

    func check(_ application: AppRecord, fallbackNotes: AppRecord?) async -> AppRecord {
        await provider.check(application)
    }

    func upgrade(
        _ application: AppRecord, progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws {
        try await provider.upgrade(application, progress: progress)
    }
}

struct TauriUpdateSource: UpdateSourceProvider {
    var provider = TauriUpdateProvider()
    var mechanism: UpdateMechanism { .tauri }

    func check(_ application: AppRecord, fallbackNotes: AppRecord?) async -> AppRecord {
        await provider.check(application, fallbackNotes: fallbackNotes)
    }

    func upgrade(
        _ application: AppRecord, progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws {
        try await provider.upgrade(application, progress: progress)
    }
}

struct VSCodeUpdateSource: UpdateSourceProvider {
    var provider = VSCodeUpdateProvider()
    var mechanism: UpdateMechanism { .vscodeUpdater }

    func check(_ application: AppRecord, fallbackNotes: AppRecord?) async -> AppRecord {
        await provider.check(application)
    }

    func upgrade(
        _ application: AppRecord, progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws {
        try await provider.upgrade(application, progress: progress)
    }
}

struct CustomAPIUpdateSource: UpdateSourceProvider {
    var provider = CustomAPIUpdateProvider()
    var mechanism: UpdateMechanism { .customAPI }

    func check(_ application: AppRecord, fallbackNotes: AppRecord?) async -> AppRecord {
        await provider.check(application)
    }

    func upgrade(
        _ application: AppRecord, progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws {
        try await provider.upgrade(application, progress: progress)
    }
}

struct GitHubReleasesUpdateSource: UpdateSourceProvider {
    var provider = GitHubReleasesUpdateProvider()
    var mechanism: UpdateMechanism { .githubReleases }

    func check(_ application: AppRecord, fallbackNotes: AppRecord?) async -> AppRecord {
        await provider.check(application)
    }

    func upgrade(
        _ application: AppRecord, progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws {
        try await provider.upgrade(application, progress: progress)
    }

    func prepareForRefresh(cachePolicy: UpdateCachePolicy) async {
        // A manual refresh re-verifies repositories that recently had no release.
        if cachePolicy == .reloadIgnoringCache {
            await provider.invalidateMissingReleaseCache()
        }
    }
}

/// For records without an installable route: checks leave them unchanged.
struct UnsupportedUpdateSource: UpdateSourceProvider {
    let mechanism: UpdateMechanism

    func check(_ application: AppRecord, fallbackNotes: AppRecord?) async -> AppRecord {
        application
    }

    func upgrade(
        _ application: AppRecord, progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws {
        throw UpdateSourceError.noInstallableSource
    }
}

enum UpdateSourceError: LocalizedError {
    case noInstallableSource

    var errorDescription: String? {
        switch self {
        case .noInstallableSource: "此应用没有可自动安装的更新源。"
        }
    }
}
