import Foundation

struct UpdateAllPlan: Sendable {
    let applicationIDs: [AppRecord.ID]
    let runningApplications: [AppRecord]
}

struct UpdateAllProgress: Equatable, Sendable {
    var completedCount = 0
    let totalCount: Int
    struct ActiveApplication: Equatable, Sendable {
        let id: AppRecord.ID
        let name: String
    }

    /// Applications updating right now, in the order they started.
    var activeApplications: [ActiveApplication] = []

    var activeApplicationNames: [String] { activeApplications.map(\.name) }

    var activeSummary: String? {
        guard let first = activeApplicationNames.first else { return nil }
        let count = activeApplicationNames.count
        return count > 1 ? "\(first) 等 \(count) 个" : first
    }
}

/// How many applications "更新全部" updates at once, chosen in Settings.
enum UpdateAllConcurrency {
    static let defaultsKey = "maximumConcurrentUpdates"
    static let defaultLimit = 5
    static let range = 1...10

    static func limit(in userDefaults: UserDefaults) -> Int {
        guard userDefaults.object(forKey: defaultsKey) != nil else { return defaultLimit }
        return min(max(userDefaults.integer(forKey: defaultsKey), range.lowerBound), range.upperBound)
    }
}
