import Foundation
import Observation
import Synchronization
import XCTest

@testable import Upkeep

@MainActor
final class AppSidebarSectionsTests: XCTestCase {
  func testGroupsKeepExistingDateOrderAndSearchSemantics() {
    var installed = application("Installed", status: .upToDate, date: 500)
    installed.lastInstalledAt = Date(timeIntervalSince1970: 600)
    let newer = application("Newer", date: 300)
    let older = application("Older", date: 100)
    let ignored = application("Ignored", date: 400)
    var checking = application("Checking", status: .checking, date: 200)
    checking.latestVersion = "2"
    let apps = [older, installed, ignored, checking, newer]
    let sections = AppSidebarSections(applications: apps, ignoredBundleIdentifiers: [ignored.bundleIdentifier])
    let ignoredIDs: Set<AppRecord.ID> = [ignored.id]
    XCTAssertEqual(sections.availableUpdates, apps.availableUpdates(ignoredIDs: ignoredIDs))
    XCTAssertEqual(sections.installedApplications, apps.installedApplications())
    XCTAssertEqual(sections.ignoredUpdates, apps.ignoredUpdates(ignoredIDs: ignoredIDs))

    for query in ["", "  ", "Newer", "SPARKLE", "com.example", "not present"] {
      let filtered = apps.filter { $0.matchesSearch(query) }
      let result = sections.matching(query)
      XCTAssertEqual(result.availableUpdates, filtered.availableUpdates(ignoredIDs: ignoredIDs))
      XCTAssertEqual(result.installedApplications, filtered.installedApplications())
      XCTAssertEqual(result.ignoredUpdates, filtered.ignoredUpdates(ignoredIDs: ignoredIDs))
      XCTAssertEqual(result.applicationIDs, Set(apps.map(\.id)))
    }
  }

  func testLibraryMaintainsSectionsAfterSearchIgnoreUpdateAndRemoval() throws {
    let suite = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = application("First")
    let second = application("Second")
    let library = AppLibrary(applications: [first, second], userDefaults: defaults, libraryStore: .memory())
    library.searchText = "First"
    XCTAssertEqual(library.sidebarSections.availableUpdates.map(\.id), [first.id])
    XCTAssertEqual(Set(library.automaticUpdates.map(\.id)), [first.id, second.id])

    library.ignoreUpdates(for: first.id)
    XCTAssertTrue(library.sidebarSections.availableUpdates.isEmpty)
    XCTAssertEqual(library.sidebarSections.ignoredUpdates.map(\.id), [first.id])
    library.stopIgnoringUpdates(for: first.id)
    XCTAssertEqual(library.sidebarSections.availableUpdates.map(\.id), [first.id])

    library.applications[0].status = .upToDate
    XCTAssertTrue(library.sidebarSections.availableUpdates.isEmpty)
    XCTAssertEqual(library.sidebarSections.installedApplications.map(\.id), [first.id])
    XCTAssertEqual(library.automaticUpdates.map(\.id), [second.id])
    library.forgetUninstalled(first)
    XCTAssertTrue(library.sidebarSections.isEmpty)
    XCTAssertEqual(library.sidebarSections.applicationIDs, [second.id])
    library.searchText = ""
    XCTAssertEqual(library.sidebarSections.availableUpdates.map(\.id), [second.id])
  }

  func testSelectionAndPhaseChangesDoNotInvalidateDerivedSections() throws {
    let suite = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let library = AppLibrary(applications: [application("First"), application("Second")],
      userDefaults: defaults, libraryStore: .memory())
    let changed = Mutex(false)
    withObservationTracking {
      _ = library.sidebarSections
      _ = library.automaticUpdates
    } onChange: {
      changed.withLock { $0 = true }
    }
    library.selectedApplicationID = library.applications.last?.id
    library.phase = .checking
    library.alertMessage = "Example"
    XCTAssertFalse(changed.withLock { $0 })
    library.searchText = "First"
    XCTAssertTrue(changed.withLock { $0 })
  }

  private func application(_ name: String, status: UpdateStatus = .updateAvailable, date: TimeInterval = 100) -> AppRecord {
    AppRecord(name: name, bundleIdentifier: "com.example.\(name.lowercased())",
      applicationURL: URL(fileURLWithPath: "/Applications/\(name).app"), currentVersion: "1",
      applicationModificationDate: Date(timeIntervalSince1970: date), source: .sparkle,
      status: status, latestVersion: "2", releaseDate: Date(timeIntervalSince1970: date),
      canAutomaticallyUpdate: true)
  }
}
