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
        switch mechanism.traits.channel {
        case .fixed(let channel):
            return channel
        case .feedHost:
            guard let host = feedURL?.host?.lowercased(), !host.isEmpty else { return .unknown }
            let githubHosts = [
                "github.com", "www.github.com", "api.github.com", "raw.githubusercontent.com",
            ]
            return githubHosts.contains(host) ? .github : .website
        }
    }

    /// Assigned by an `UpdateSourceRule` rather than declared by the application.
    var isRuleAssigned: Bool {
        UpdateSourceRule.ruleID(fromConfigurationIdentifier: identifier) != nil
    }

    /// An electron-builder app that reads a channel other than `latest`, such as
    /// `nightly-mac.yml`, has opted into its own preview releases.
    var followsPrereleaseChannel: Bool {
        guard mechanism == .electronBuilder,
            let name = feedURL?.lastPathComponent.lowercased(), name.hasSuffix("-mac.yml")
        else { return false }
        return name != "latest-mac.yml"
    }

    var isCheckable: Bool {
        switch mechanism.traits.checkability {
        case .always: true
        case .requiresFeedURL: feedURL != nil
        case .never: false
        }
    }
}
