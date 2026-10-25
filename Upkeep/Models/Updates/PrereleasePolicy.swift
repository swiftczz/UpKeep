import Foundation

/// Whether update checks offer an application's alpha, beta, rc and preview releases.
enum PrereleasePolicy: String, CaseIterable, Sendable {
    /// Follows the installed copy: a preview build, or an app set to its own preview
    /// channel, keeps getting previews; a release build only gets releases.
    case automatic
    case stableOnly
    case includePrereleases

    var title: String {
        switch self {
        case .automatic: "自动"
        case .stableOnly: "仅正式版"
        case .includePrereleases: "正式版和预览版"
        }
    }
}
