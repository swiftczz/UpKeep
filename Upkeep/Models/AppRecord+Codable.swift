import Foundation

extension AppRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case name
        case bundleIdentifier
        case applicationURL
        case currentVersion
        case buildVersion
        case applicationModificationDate
        case updateConfiguration
        case appStorePlatform
        case appStoreCountryCode
        case appStoreAccountCountryCode
        case status
        case latestVersion
        case latestBuildVersion
        case releaseNotes
        case releaseDate
        case releaseNotesURL
        case updatePageURL
        case alternateUpdateConfiguration
        case homebrewCaskToken
        case packageByteCount
        case canAutomaticallyUpdate
        case lastInstalledAt
        case installedUpdateConfiguration
        // Legacy flat records, decoded but never written again.
        case source
        case sourceURL
        case homepageURL
        case sourceIdentifier
        case githubReleaseTagPrefix
        case alternateUpdateSource
        case alternateSourceURL
        case alternateSourceIdentifier
        case alternateHomepageURL
        case installedSource
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let configuration: UpdateConfiguration
        if container.contains(.updateConfiguration) {
            configuration = try container.decode(
                UpdateConfiguration.self, forKey: .updateConfiguration)
        } else {
            let mechanism = try container.decode(UpdateMechanism.self, forKey: .source)
            configuration = UpdateConfiguration(
                mechanism: mechanism,
                feedURL: try container.decodeIfPresent(URL.self, forKey: .sourceURL),
                homepageURL: try container.decodeIfPresent(URL.self, forKey: .homepageURL),
                identifier: try container.decodeIfPresent(String.self, forKey: .sourceIdentifier),
                githubReleaseTagPrefix: mechanism == .githubReleases
                    ? try container.decodeIfPresent(String.self, forKey: .githubReleaseTagPrefix)
                    : nil
            )
        }
        let alternate: UpdateConfiguration?
        if container.contains(.alternateUpdateConfiguration) {
            alternate = try container.decodeIfPresent(
                UpdateConfiguration.self, forKey: .alternateUpdateConfiguration)
        } else if let mechanism = try container.decodeIfPresent(
            UpdateMechanism.self, forKey: .alternateUpdateSource)
        {
            alternate = UpdateConfiguration(
                mechanism: mechanism,
                feedURL: try container.decodeIfPresent(URL.self, forKey: .alternateSourceURL),
                homepageURL: try container.decodeIfPresent(URL.self, forKey: .alternateHomepageURL),
                identifier: try container.decodeIfPresent(
                    String.self, forKey: .alternateSourceIdentifier),
                githubReleaseTagPrefix: mechanism == .githubReleases
                    ? try container.decodeIfPresent(String.self, forKey: .githubReleaseTagPrefix)
                    : nil
            )
        } else {
            alternate = nil
        }
        let installed: UpdateConfiguration?
        if container.contains(.installedUpdateConfiguration) {
            installed = try container.decodeIfPresent(
                UpdateConfiguration.self, forKey: .installedUpdateConfiguration)
        } else if let mechanism = try container.decodeIfPresent(
            UpdateMechanism.self, forKey: .installedSource)
        {
            // Old records stored only the mechanism. Reuse endpoint details only when
            // an existing route describes that same mechanism.
            if configuration.mechanism == mechanism {
                installed = configuration
            } else if alternate?.mechanism == mechanism {
                installed = alternate
            } else {
                installed = UpdateConfiguration(mechanism: mechanism)
            }
        } else {
            installed = nil
        }
        self.init(
            name: try container.decode(String.self, forKey: .name),
            bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier),
            applicationURL: try container.decode(URL.self, forKey: .applicationURL),
            currentVersion: try container.decode(String.self, forKey: .currentVersion),
            buildVersion: try container.decodeIfPresent(String.self, forKey: .buildVersion),
            applicationModificationDate: try container.decodeIfPresent(
                Date.self, forKey: .applicationModificationDate),
            updateConfiguration: configuration,
            appStorePlatform: try container.decodeIfPresent(
                AppStorePlatform.self, forKey: .appStorePlatform),
            appStoreCountryCode: try container.decodeIfPresent(
                String.self, forKey: .appStoreCountryCode),
            appStoreAccountCountryCode: try container.decodeIfPresent(
                String.self, forKey: .appStoreAccountCountryCode),
            status: try container.decode(UpdateStatus.self, forKey: .status),
            latestVersion: try container.decodeIfPresent(String.self, forKey: .latestVersion),
            latestBuildVersion: try container.decodeIfPresent(
                String.self, forKey: .latestBuildVersion),
            releaseNotes: try container.decodeIfPresent(String.self, forKey: .releaseNotes),
            releaseDate: try container.decodeIfPresent(Date.self, forKey: .releaseDate),
            releaseNotesURL: try container.decodeIfPresent(URL.self, forKey: .releaseNotesURL),
            updatePageURL: try container.decodeIfPresent(URL.self, forKey: .updatePageURL),
            alternateUpdateConfiguration: alternate,
            homebrewCaskToken: try container.decodeIfPresent(
                String.self, forKey: .homebrewCaskToken),
            packageByteCount: try container.decodeIfPresent(Int64.self, forKey: .packageByteCount),
            canAutomaticallyUpdate: try container.decodeIfPresent(
                Bool.self, forKey: .canAutomaticallyUpdate) ?? false,
            lastInstalledAt: try container.decodeIfPresent(Date.self, forKey: .lastInstalledAt),
            installedUpdateConfiguration: installed
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(applicationURL, forKey: .applicationURL)
        try container.encode(currentVersion, forKey: .currentVersion)
        try container.encodeIfPresent(buildVersion, forKey: .buildVersion)
        try container.encodeIfPresent(
            applicationModificationDate, forKey: .applicationModificationDate)
        try container.encode(updateConfiguration, forKey: .updateConfiguration)
        try container.encodeIfPresent(appStorePlatform, forKey: .appStorePlatform)
        try container.encodeIfPresent(appStoreCountryCode, forKey: .appStoreCountryCode)
        try container.encodeIfPresent(
            appStoreAccountCountryCode, forKey: .appStoreAccountCountryCode)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(latestVersion, forKey: .latestVersion)
        try container.encodeIfPresent(latestBuildVersion, forKey: .latestBuildVersion)
        try container.encodeIfPresent(releaseNotes, forKey: .releaseNotes)
        try container.encodeIfPresent(releaseDate, forKey: .releaseDate)
        try container.encodeIfPresent(releaseNotesURL, forKey: .releaseNotesURL)
        try container.encodeIfPresent(updatePageURL, forKey: .updatePageURL)
        try container.encodeIfPresent(
            alternateUpdateConfiguration, forKey: .alternateUpdateConfiguration)
        try container.encodeIfPresent(homebrewCaskToken, forKey: .homebrewCaskToken)
        try container.encodeIfPresent(packageByteCount, forKey: .packageByteCount)
        try container.encode(canAutomaticallyUpdate, forKey: .canAutomaticallyUpdate)
        try container.encodeIfPresent(lastInstalledAt, forKey: .lastInstalledAt)
        try container.encodeIfPresent(
            installedUpdateConfiguration, forKey: .installedUpdateConfiguration)
    }
}
