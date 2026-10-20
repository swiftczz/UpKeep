import Foundation

/// How update metadata is read and updates are installed.
///
/// The raw value is persisted in library snapshots. Everything else a mechanism
/// needs to describe itself lives in `traits`, so adding a mechanism means adding
/// one case here, one `traits` entry and one `UpdateSourceProvider` registration.
enum UpdateMechanism: String, Hashable, Sendable, Codable, CaseIterable {
    case appStore
    case homebrew
    case sparkle
    case electronBuilder
    case tauri
    case vscodeUpdater
    case customAPI
    case githubReleases
    case selfManaged

    struct Traits: Sendable {
        enum Checkability: Sendable {
            case always
            case requiresFeedURL
            case never
        }

        enum ChannelRule: Sendable {
            case fixed(UpdateChannel)
            /// GitHub or website, derived from the metadata endpoint's host.
            case feedHost
        }

        let title: String
        let searchTerms: [String]
        /// Whether a Homebrew cask can delegate its update checks to this mechanism.
        let canBeAlternate: Bool
        let checkability: Checkability
        let channel: ChannelRule
        /// Help text for the primary update action.
        let installHelp: String
    }

    var traits: Traits {
        switch self {
        case .appStore:
            Traits(
                title: "App Store",
                searchTerms: ["App Store", "Mac App Store", "iPhone App Store", "iPad App Store"],
                canBeAlternate: false, checkability: .always, channel: .fixed(.appStore),
                installHelp: "使用当前 App Store 账号下载并安装此更新")
        case .homebrew:
            Traits(
                title: "Homebrew Cask", searchTerms: ["Homebrew", "Homebrew Cask"],
                canBeAlternate: false, checkability: .never, channel: .fixed(.homebrew),
                installHelp: "使用 Homebrew 下载并安装此更新")
        case .sparkle:
            Traits(
                title: "Sparkle", searchTerms: ["Sparkle"],
                canBeAlternate: true, checkability: .requiresFeedURL, channel: .feedHost,
                installHelp: Self.packageInstallHelp)
        case .electronBuilder:
            Traits(
                title: "Electron Updater",
                searchTerms: ["Electron Updater", "electron", "electron-updater"],
                canBeAlternate: true, checkability: .always, channel: .feedHost,
                installHelp: Self.packageInstallHelp)
        case .tauri:
            Traits(
                title: "Tauri Updater", searchTerms: ["Tauri", "Tauri Updater"],
                canBeAlternate: true, checkability: .always, channel: .feedHost,
                installHelp: Self.packageInstallHelp)
        case .vscodeUpdater:
            Traits(
                title: "VS Code Updater", searchTerms: ["VS Code", "VS Code Updater", "VSCode"],
                canBeAlternate: true, checkability: .always, channel: .feedHost,
                installHelp: Self.packageInstallHelp)
        case .customAPI:
            Traits(
                title: "Custom API",
                searchTerms: [
                    "Custom API", "Website Updater", "Website Updates", "Website update",
                    "Website", "官网更新", "官网",
                ],
                canBeAlternate: true, checkability: .always, channel: .feedHost,
                installHelp: Self.packageInstallHelp)
        case .githubReleases:
            Traits(
                title: "GitHub Releases", searchTerms: ["GitHub", "GitHub Releases"],
                canBeAlternate: true, checkability: .always, channel: .fixed(.github),
                installHelp: Self.packageInstallHelp)
        case .selfManaged:
            Traits(
                title: "Unknown", searchTerms: ["未知", "Unknown"],
                canBeAlternate: false, checkability: .never, channel: .fixed(.unknown),
                installHelp: Self.packageInstallHelp)
        }
    }

    private static let packageInstallHelp = "下载并安装此更新"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        // Previous snapshot schemas used these names for custom API updates.
        if value == "releaseJSON" || value == "website" {
            self = .customAPI
        } else if let mechanism = Self(rawValue: value) {
            self = mechanism
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unknown update mechanism: \(value)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var title: String { traits.title }

    var searchTerms: [String] { traits.searchTerms }

    var canBeAlternateUpdateMechanism: Bool { traits.canBeAlternate }

    static func isMechanismSearchQuery(_ query: String) -> Bool {
        allCases.lazy.flatMap(\.searchTerms).contains {
            searchTerm($0, matches: query)
        }
    }

    static func searchTerm(_ term: String, matches query: String) -> Bool {
        if term.localizedCaseInsensitiveCompare(query) == .orderedSame {
            return true
        }
        guard query.count >= 4 else { return false }
        return term.range(of: query, options: [.anchored, .caseInsensitive]) != nil
    }
}
