import Foundation

/// How update metadata is read and updates are installed.
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

    var title: String {
        switch self {
        case .appStore: "App Store"
        case .homebrew: "Homebrew Cask"
        case .sparkle: "Sparkle"
        case .electronBuilder: "Electron Updater"
        case .tauri: "Tauri Updater"
        case .vscodeUpdater: "VS Code Updater"
        case .customAPI: "Custom API"
        case .githubReleases: "GitHub Releases"
        case .selfManaged: "Unknown"
        }
    }

    var searchTerms: [String] {
        switch self {
        case .appStore:
            ["App Store", "Mac App Store", "iPhone App Store", "iPad App Store"]
        case .homebrew:
            ["Homebrew", "Homebrew Cask"]
        case .sparkle:
            ["Sparkle"]
        case .electronBuilder:
            ["Electron Updater", "electron", "electron-updater"]
        case .tauri:
            ["Tauri", "Tauri Updater"]
        case .vscodeUpdater:
            ["VS Code", "VS Code Updater", "VSCode"]
        case .customAPI:
            [
                "Custom API", "Website Updater", "Website Updates", "Website update", "Website",
                "官网更新",
                "官网",
            ]
        case .githubReleases:
            ["GitHub", "GitHub Releases"]
        case .selfManaged:
            ["未知", "Unknown"]
        }
    }

    var canBeAlternateUpdateMechanism: Bool {
        switch self {
        case .sparkle, .electronBuilder, .tauri, .vscodeUpdater, .customAPI, .githubReleases:
            return true
        case .appStore, .homebrew, .selfManaged:
            return false
        }
    }

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
