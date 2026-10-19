import Foundation

/// Where update metadata is published, independently of the updater protocol.
enum UpdateChannel: String, Hashable, Codable, CaseIterable, Sendable {
    case appStore, homebrew, github, website, unknown

    var title: String {
        switch self {
        case .appStore: "App Store"
        case .homebrew: "Homebrew"
        case .github: "GitHub"
        case .website: "Website"
        case .unknown: "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .appStore: "apple.logo"
        case .homebrew: "mug.fill"
        case .github: "shippingbox"
        case .website: "globe"
        case .unknown: "app.dashed"
        }
    }

    var searchTerms: [String] {
        switch self {
        case .website: ["Website", "官网", "官网更新"]
        case .unknown: ["Unknown", "未知"]
        default: [title]
        }
    }
}
