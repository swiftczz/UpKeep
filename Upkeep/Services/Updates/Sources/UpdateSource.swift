import Foundation

/// Checks and installs updates for one `UpdateMechanism`.
///
/// To add an update source, implement this protocol (and usually an
/// `UpdateSourceDetector`), then register both in `UpdateSourceRegistry.standard`.
/// Formats that are only a JSON endpoint do not need code: describe them with an
/// `UpdateSourceRule` instead.
protocol UpdateSourceProvider: Sendable {
    var mechanism: UpdateMechanism { get }

    /// Returns the record with the latest release applied.
    /// `fallbackNotes` is the Homebrew record whose notes may fill gaps when this
    /// provider checks a cask's alternate route.
    func check(_ application: AppRecord, fallbackNotes: AppRecord?) async -> AppRecord

    func upgrade(
        _ application: AppRecord,
        progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws

    /// Runs before a library-wide refresh, e.g. to drop caches on a manual refresh.
    func prepareForRefresh(cachePolicy: UpdateCachePolicy) async
}

extension UpdateSourceProvider {
    func prepareForRefresh(cachePolicy: UpdateCachePolicy) async {}
}

/// Rewrites the whole library before individual checks, e.g. from a package
/// manager that answers for many applications at once.
protocol UpdateLibraryEnricher: Sendable {
    func enrich(_ applications: [AppRecord], cachePolicy: UpdateCachePolicy) async -> [AppRecord]
}

/// Everything a detector may inspect about one installed application.
struct UpdateSourceDetectionContext {
    enum Depth: Sendable {
        /// Reads only the bundle's metadata; used when the file system changes.
        case installedOnly
        /// May read archives and executables to discover embedded endpoints.
        case full
    }

    let applicationURL: URL
    let bundleURL: URL
    let name: String
    let bundleIdentifier: String
    let currentVersion: String
    let buildVersion: String?
    let depth: Depth
    let hasAppStoreReceipt: Bool
    let iOSAppStoreMetadata: IOSAppStoreMetadata?
    let sparkleFeedURL: URL?
    let hasSparkleSource: Bool
    let rules: UpdateSourceRuleSet
}

struct DetectedUpdateSource: Sendable {
    var configuration: UpdateConfiguration
    var appStorePlatform: AppStorePlatform?
    /// Replaces the bundle's build version, e.g. with a commit the updater compares.
    var buildVersion: String?

    init(
        _ configuration: UpdateConfiguration,
        appStorePlatform: AppStorePlatform? = nil,
        buildVersion: String? = nil
    ) {
        self.configuration = configuration
        self.appStorePlatform = appStorePlatform
        self.buildVersion = buildVersion
    }
}

/// Recognizes an update source from an installed bundle. Detectors run in the
/// registry's order and the first match wins, so more authoritative sources
/// (store receipts, explicit feeds) come before heuristics.
protocol UpdateSourceDetector: Sendable {
    func detect(_ context: UpdateSourceDetectionContext) -> DetectedUpdateSource?
}
