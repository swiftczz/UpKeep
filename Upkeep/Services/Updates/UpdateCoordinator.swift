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

/// Routes each record to the provider registered for its mechanism.
struct UpdateCoordinator: UpdateCoordinating, Sendable {
    private let registry: UpdateSourceRegistry
    private let process: ApplicationProcessClient

    init(registry: UpdateSourceRegistry = .standard, process: ApplicationProcessClient = .live) {
        self.registry = registry
        self.process = process
    }

    func enrich(_ applications: [AppRecord]) async -> [AppRecord] {
        await enrich(applications, cachePolicy: .allowed)
    }

    func enrich(
        _ applications: [AppRecord],
        cachePolicy: UpdateCachePolicy
    ) async -> [AppRecord] {
        for provider in registry.providers {
            await provider.prepareForRefresh(cachePolicy: cachePolicy)
        }
        var enriched = applications
        for enricher in registry.enrichers {
            enriched = await enricher.enrich(enriched, cachePolicy: cachePolicy)
        }
        return enriched
    }

    func check(_ application: AppRecord) async -> AppRecord {
        // A cask can delegate checks to the updater embedded in its app.
        if application.updateConfiguration.mechanism == .homebrew,
            let alternate = application.alternateUpdateCheckRecord
        {
            let checked = await registry.provider(for: alternate.updateConfiguration.mechanism)
                .check(alternate, fallbackNotes: application)
            return HomebrewUpdateProvider.mergeAlternateCheckResult(
                checked,
                intoHomebrew: application
            )
        }

        return await registry.provider(for: application.updateConfiguration.mechanism)
            .check(application, fallbackNotes: nil)
    }

    func update(
        _ application: AppRecord,
        progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws {
        let provider = registry.provider(for: application.updateConfiguration.mechanism)
        try await UpdateRelaunch.perform(
            application,
            process: process,
            progress: progress
        ) {
            try await provider.upgrade(application, progress: progress)
        }
    }
}
