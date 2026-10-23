import Foundation

extension AppRecord {
    /// The route shown as the update source: how the installed copy was last
    /// installed, or, while an update is pending, the route that will install it.
    /// A manual `brew upgrade` replaces the installed route with Homebrew.
    var displayedUpdateConfiguration: UpdateConfiguration {
        needsUpdate ? updateConfiguration : installedUpdateConfiguration ?? updateConfiguration
    }

    var channelTitle: String { displayedUpdateConfiguration.channel.title }

    var mechanismTitle: String { displayedUpdateConfiguration.mechanism.title }

    var channelSystemImage: String { displayedUpdateConfiguration.channel.systemImage }

    var channelPlatformSystemImage: String? {
        guard displayedUpdateConfiguration.mechanism == .appStore else { return nil }
        return appStorePlatform?.systemImage
    }

}
