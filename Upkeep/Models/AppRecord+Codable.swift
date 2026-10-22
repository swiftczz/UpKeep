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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier),
            applicationURL: try container.decode(URL.self, forKey: .applicationURL),
            currentVersion: try container.decode(String.self, forKey: .currentVersion),
            buildVersion: try container.decodeIfPresent(String.self, forKey: .buildVersion),
            applicationModificationDate: try container.decodeIfPresent(
                Date.self, forKey: .applicationModificationDate),
            updateConfiguration: try container.decode(
                UpdateConfiguration.self, forKey: .updateConfiguration),
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
            alternateUpdateConfiguration: try container.decodeIfPresent(
                UpdateConfiguration.self, forKey: .alternateUpdateConfiguration),
            homebrewCaskToken: try container.decodeIfPresent(
                String.self, forKey: .homebrewCaskToken),
            packageByteCount: try container.decodeIfPresent(Int64.self, forKey: .packageByteCount),
            canAutomaticallyUpdate: try container.decodeIfPresent(
                Bool.self, forKey: .canAutomaticallyUpdate) ?? false,
            lastInstalledAt: try container.decodeIfPresent(Date.self, forKey: .lastInstalledAt),
            installedUpdateConfiguration: try container.decodeIfPresent(
                UpdateConfiguration.self, forKey: .installedUpdateConfiguration)
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
