import Foundation

// Built-in detectors, registered in `UpdateSourceRegistry.standard` from most to
// least authoritative. Each reads only what its own protocol needs.

struct AppStoreReceiptDetector: UpdateSourceDetector {
    func detect(_ context: UpdateSourceDetectionContext) -> DetectedUpdateSource? {
        guard context.hasAppStoreReceipt else { return nil }
        let identifier =
            (context.depth == .full ? context.iOSAppStoreMetadata?.storeIdentifier : nil)
            ?? ApplicationScanner.appStoreAdamIdentifier(at: context.applicationURL)
        return DetectedUpdateSource(
            UpdateConfiguration(mechanism: .appStore, identifier: identifier),
            appStorePlatform: .mac)
    }
}

/// iPhone and iPad apps installed from the App Store on Apple silicon.
struct IOSAppStoreDetector: UpdateSourceDetector {
    func detect(_ context: UpdateSourceDetectionContext) -> DetectedUpdateSource? {
        guard let metadata = context.iOSAppStoreMetadata else { return nil }
        return DetectedUpdateSource(
            UpdateConfiguration(mechanism: .appStore, identifier: metadata.storeIdentifier),
            appStorePlatform: metadata.platform)
    }
}

struct SparkleSourceDetector: UpdateSourceDetector {
    func detect(_ context: UpdateSourceDetectionContext) -> DetectedUpdateSource? {
        guard context.hasSparkleSource else { return nil }
        return DetectedUpdateSource(
            UpdateConfiguration(mechanism: .sparkle, feedURL: context.sparkleFeedURL))
    }
}

struct RuleSourceDetector: UpdateSourceDetector {
    let precedence: UpdateSourceRule.Precedence

    func detect(_ context: UpdateSourceDetectionContext) -> DetectedUpdateSource? {
        guard
            let match = context.rules.firstMatch(
                for: context.bundleIdentifier, precedence: precedence),
            let configuration = match.configuration(
                values: match.values(
                    version: context.currentVersion, build: context.buildVersion,
                    bundleIdentifier: context.bundleIdentifier))
        else { return nil }
        return DetectedUpdateSource(configuration)
    }
}

struct ElectronBuilderSourceDetector: UpdateSourceDetector {
    func detect(_ context: UpdateSourceDetectionContext) -> DetectedUpdateSource? {
        guard context.depth == .full,
            let metadata = ElectronBuilderDetector.detect(in: context.bundleURL)
        else { return nil }
        return DetectedUpdateSource(
            UpdateConfiguration(
                mechanism: .electronBuilder, feedURL: metadata.feedURL,
                homepageURL: metadata.homepageURL, identifier: metadata.identifier))
    }
}

struct VSCodeSourceDetector: UpdateSourceDetector {
    func detect(_ context: UpdateSourceDetectionContext) -> DetectedUpdateSource? {
        guard let metadata = VSCodeUpdaterDetector.detect(in: context.bundleURL) else {
            return nil
        }
        // The updater compares commits; a bundle version equal to the marketing
        // version cannot tell two builds apart.
        let replacesBuild =
            context.depth == .installedOnly || context.buildVersion == nil
            || context.buildVersion == context.currentVersion
        return DetectedUpdateSource(
            UpdateConfiguration(
                mechanism: .vscodeUpdater, feedURL: metadata.updateURL,
                homepageURL: metadata.homepageURL,
                identifier: VSCodeUpdaterDetector.updateIdentifier(
                    quality: metadata.quality, commit: metadata.commit)),
            buildVersion: replacesBuild ? String(metadata.commit.prefix(7)) : nil)
    }
}

struct ElectronCustomAPISourceDetector: UpdateSourceDetector {
    func detect(_ context: UpdateSourceDetectionContext) -> DetectedUpdateSource? {
        guard context.depth == .full,
            let configuration = ElectronCustomAPIUpdateDetector.detect(
                in: context.bundleURL, currentVersion: context.currentVersion)
        else { return nil }
        return DetectedUpdateSource(configuration)
    }
}

/// Endpoints embedded in executables: Tauri manifests, website APIs and GitHub
/// repositories, in that order. Installed-only scans never read binaries.
struct ExecutableEndpointSourceDetector: UpdateSourceDetector {
    func detect(_ context: UpdateSourceDetectionContext) -> DetectedUpdateSource? {
        guard context.depth == .full else { return nil }
        let detection = ExecutableUpdaterDetector.detect(bundleURL: context.bundleURL)
        if let endpoint = detection.tauriEndpoint {
            return DetectedUpdateSource(
                UpdateConfiguration(
                    mechanism: .tauri, feedURL: endpoint, identifier: endpoint.absoluteString))
        }
        if let endpoint = detection.customAPIUpdateEndpoint {
            return DetectedUpdateSource(
                UpdateConfiguration(
                    mechanism: .customAPI, feedURL: endpoint, identifier: endpoint.absoluteString))
        }
        let matching = detection.githubReleases.filter {
            GitHubReleasesDetector.matchesApplication(
                $0, name: context.name, bundleIdentifier: context.bundleIdentifier)
        }
        guard let metadata = matching.first(where: { $0.tagPrefix != nil }) ?? matching.first
        else { return nil }
        return DetectedUpdateSource(
            UpdateConfiguration(
                mechanism: .githubReleases, feedURL: metadata.apiURL,
                homepageURL: metadata.homepageURL, identifier: metadata.identifier,
                githubReleaseTagPrefix: metadata.tagPrefix))
    }
}
