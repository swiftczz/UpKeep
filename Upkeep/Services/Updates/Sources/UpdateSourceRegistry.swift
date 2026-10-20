import Foundation

/// The single place where update sources are wired together.
struct UpdateSourceRegistry: Sendable {
    private let providersByMechanism: [UpdateMechanism: any UpdateSourceProvider]
    let enrichers: [any UpdateLibraryEnricher]
    /// Ordered from most to least authoritative; the first match wins.
    let detectors: [any UpdateSourceDetector]

    /// A later provider for the same mechanism replaces an earlier one.
    init(
        providers: [any UpdateSourceProvider],
        enrichers: [any UpdateLibraryEnricher] = [],
        detectors: [any UpdateSourceDetector] = []
    ) {
        var providersByMechanism: [UpdateMechanism: any UpdateSourceProvider] = [:]
        for provider in providers {
            providersByMechanism[provider.mechanism] = provider
        }
        self.providersByMechanism = providersByMechanism
        self.enrichers = enrichers
        self.detectors = detectors
    }

    var providers: [any UpdateSourceProvider] {
        UpdateMechanism.allCases.compactMap { providersByMechanism[$0] }
    }

    func provider(for mechanism: UpdateMechanism) -> any UpdateSourceProvider {
        providersByMechanism[mechanism] ?? UnsupportedUpdateSource(mechanism: mechanism)
    }

    static let standard: UpdateSourceRegistry = {
        let homebrew = HomebrewUpdateProvider()
        return UpdateSourceRegistry(
            providers: [
                AppStoreUpdateSource(),
                HomebrewUpdateSource(provider: homebrew),
                SparkleUpdateSource(),
                ElectronBuilderUpdateSource(),
                TauriUpdateSource(),
                VSCodeUpdateSource(),
                CustomAPIUpdateSource(),
                GitHubReleasesUpdateSource(),
                UnsupportedUpdateSource(mechanism: .selfManaged),
            ],
            enrichers: [homebrew],
            detectors: [
                AppStoreReceiptDetector(),
                IOSAppStoreDetector(),
                SparkleSourceDetector(),
                // Rules outrank heuristics, but not what the vendor declares in the
                // bundle: a store receipt or a Sparkle feed in Info.plist.
                RuleSourceDetector(precedence: .beforeHeuristics),
                ElectronBuilderSourceDetector(),
                VSCodeSourceDetector(),
                ElectronCustomAPISourceDetector(),
                ExecutableEndpointSourceDetector(),
                RuleSourceDetector(precedence: .fallback),
            ]
        )
    }()
}
