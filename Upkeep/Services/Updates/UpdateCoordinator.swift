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
    private let rules: @Sendable () -> UpdateSourceRuleSet
    private let fetchData: ReleaseNotesFetcher.FetchData

    init(
        registry: UpdateSourceRegistry = .standard, process: ApplicationProcessClient = .live,
        rules: @escaping @Sendable () -> UpdateSourceRuleSet = {
            UpdateSourceRuleStore.shared.current()
        },
        fetchData: @escaping ReleaseNotesFetcher.FetchData = {
            try await UpdateHTTP.successfulData(from: $0)
        }
    ) {
        self.registry = registry
        self.process = process
        self.rules = rules
        self.fetchData = fetchData
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
                await applyingRuleReleaseNotes(to: checked),
                intoHomebrew: application
            )
        }

        return await applyingRuleReleaseNotes(
            to: await registry.provider(for: application.updateConfiguration.mechanism)
                .check(application, fallbackNotes: nil))
    }

    /// A rule can name where notes are published apart from its feed, such as the
    /// GitHub release for the version the check found.
    private func applyingRuleReleaseNotes(to application: AppRecord) async -> AppRecord {
        guard
            let latestVersion = application.latestVersion?.split(separator: ",").first
                .map(String.init),
            let match = rules().match(
                configurationIdentifier: application.updateConfiguration.identifier,
                bundleIdentifier: application.bundleIdentifier),
            let url = match.releaseNotesURL(
                values: match.values(
                    version: application.currentVersion, build: application.buildVersion,
                    bundleIdentifier: application.bundleIdentifier),
                latestVersion: latestVersion),
            url != application.releaseNotesURL,
            let notes = await ReleaseNotesFetcher.fetch(from: url, fetchData: fetchData)
        else { return application }
        var application = application
        application.releaseNotes = notes
        application.releaseNotesURL = url
        return application
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
