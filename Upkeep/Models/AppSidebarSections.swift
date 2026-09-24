import Foundation

/// A snapshot of the sidebar's ordering, independent of selection and progress.
struct AppSidebarSections: Equatable, Sendable {
  struct Layout: Equatable, Sendable {
    let availableUpdateIDs: [AppRecord.ID]
    let installedApplicationIDs: [AppRecord.ID]
    let ignoredUpdateIDs: [AppRecord.ID]
  }

  let availableUpdates: [AppRecord]
  let installedApplications: [AppRecord]
  let ignoredUpdates: [AppRecord]
  let applicationIDs: Set<AppRecord.ID>
  let ignoredApplicationIDs: Set<AppRecord.ID>
  let layout: Layout

  var isEmpty: Bool {
    availableUpdates.isEmpty && installedApplications.isEmpty && ignoredUpdates.isEmpty
  }

  init(applications: [AppRecord] = [], ignoredBundleIdentifiers: Set<String> = []) {
    var available: [AppRecord] = []
    var installed: [AppRecord] = []
    var ignored: [AppRecord] = []
    var ignoredIDs = Set<AppRecord.ID>()
    for application in applications {
      let isIgnored = ignoredBundleIdentifiers.contains(application.bundleIdentifier.lowercased())
      if isIgnored { ignoredIDs.insert(application.id) }
      if !application.needsUpdate {
        installed.append(application)
      } else if isIgnored {
        ignored.append(application)
      } else {
        available.append(application)
      }
    }
    self.init(
      availableUpdates: available.sortedByDescendingDate { $0.releaseDate ?? $0.applicationModificationDate },
      installedApplications: installed.sortedByDescendingDate { $0.lastInstalledAt ?? $0.applicationModificationDate },
      ignoredUpdates: ignored.sortedByDescendingDate { $0.releaseDate ?? $0.applicationModificationDate },
      applicationIDs: Set(applications.map(\.id)),
      ignoredApplicationIDs: ignoredIDs
    )
  }

  /// Filtering preserves the already sorted groups and the unfiltered selection IDs.
  func matching(_ searchText: String) -> AppSidebarSections {
    let query = AppRecord.SearchQuery(searchText)
    guard !query.text.isEmpty else { return self }
    return AppSidebarSections(
      availableUpdates: availableUpdates.filter { $0.matchesSearch(query) },
      installedApplications: installedApplications.filter { $0.matchesSearch(query) },
      ignoredUpdates: ignoredUpdates.filter { $0.matchesSearch(query) },
      applicationIDs: applicationIDs,
      ignoredApplicationIDs: ignoredApplicationIDs
    )
  }

  private init(
    availableUpdates: [AppRecord], installedApplications: [AppRecord], ignoredUpdates: [AppRecord],
    applicationIDs: Set<AppRecord.ID>, ignoredApplicationIDs: Set<AppRecord.ID>
  ) {
    self.availableUpdates = availableUpdates
    self.installedApplications = installedApplications
    self.ignoredUpdates = ignoredUpdates
    self.applicationIDs = applicationIDs
    self.ignoredApplicationIDs = ignoredApplicationIDs
    layout = Layout(
      availableUpdateIDs: availableUpdates.map(\.id),
      installedApplicationIDs: installedApplications.map(\.id),
      ignoredUpdateIDs: ignoredUpdates.map(\.id)
    )
  }
}
