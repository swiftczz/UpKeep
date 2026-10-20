struct UpdateAllPlan: Sendable {
    let applicationIDs: [AppRecord.ID]
    let runningApplications: [AppRecord]
}

struct UpdateAllProgress: Equatable, Sendable {
    var completedCount = 0
    let totalCount: Int
    var currentApplicationName: String?
}
