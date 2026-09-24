struct UpdateAllPlan: Sendable {
  let applicationIDs: [AppRecord.ID]
  let runningApplications: [AppRecord]
}
