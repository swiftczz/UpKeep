import Foundation

enum UpdateStatus: Hashable, Sendable, Codable {
    case checking
    case upToDate
    case updateAvailable
    case selfManaged
    case unavailable(String)

    var title: String {
        switch self {
        case .checking: "正在检查"
        case .upToDate: "已是最新"
        case .updateAvailable: "可用更新"
        case .selfManaged: "自行更新"
        case .unavailable: "无法检查"
        }
    }
}
