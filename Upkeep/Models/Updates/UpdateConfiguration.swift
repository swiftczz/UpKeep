import Foundation

/// A complete update route. Primary, alternate, and installed routes share this
/// value type so repository details and feed metadata travel together.
struct UpdateConfiguration: Hashable, Sendable, Codable {
    var mechanism: UpdateMechanism
    var feedURL: URL?
    var homepageURL: URL?
    var identifier: String?
    var githubReleaseTagPrefix: String?
    var targetBundleIdentifier: String?

    init(
        mechanism: UpdateMechanism,
        feedURL: URL? = nil,
        homepageURL: URL? = nil,
        identifier: String? = nil,
        githubReleaseTagPrefix: String? = nil,
        targetBundleIdentifier: String? = nil
    ) {
        self.mechanism = mechanism
        self.feedURL = feedURL
        self.homepageURL = homepageURL
        self.identifier = identifier
        self.githubReleaseTagPrefix = githubReleaseTagPrefix
        self.targetBundleIdentifier = targetBundleIdentifier
    }

    /// Derive this from the metadata endpoint, never the package's download host.
    /// Keeping it derived prevents a stale channel when a feed changes.
    var channel: UpdateChannel {
        switch mechanism {
        case .appStore: return .appStore
        case .homebrew: return .homebrew
        case .githubReleases: return .github
        case .selfManaged: return .unknown
        case .sparkle, .electronBuilder, .tauri, .vscodeUpdater, .customAPI:
            guard let host = feedURL?.host?.lowercased(), !host.isEmpty else { return .unknown }
            if ["github.com", "www.github.com", "api.github.com", "raw.githubusercontent.com"]
                .contains(
                    host)
            {
                return .github
            }
            return .website
        }
    }

    var isCheckable: Bool {
        switch mechanism {
        case .appStore, .electronBuilder, .tauri, .vscodeUpdater, .customAPI, .githubReleases:
            return true
        case .sparkle:
            return feedURL != nil
        case .homebrew, .selfManaged:
            return false
        }
    }
}
