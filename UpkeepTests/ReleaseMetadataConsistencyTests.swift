import XCTest
@testable import Upkeep

@MainActor
final class ReleaseMetadataConsistencyTests: XCTestCase {
  private func app(source: UpdateSource = .homebrew, version: String = "1.14.0") -> AppRecord {
    AppRecord(name: "Folo", bundleIdentifier: "is.follow",
      applicationURL: URL(fileURLWithPath: "/Applications/Folo.app"),
      currentVersion: "1.14.0", source: source, status: .updateAvailable,
      latestVersion: version, releaseNotes: "Old notes", releaseDate: Date(timeIntervalSince1970: 100),
      releaseNotesURL: URL(string: "https://example.com/v1.14.0"), packageByteCount: 123)
  }

  func testHomebrewDoesNotInheritOlderNotesFromAnySource() {
    let sources: [UpdateSource] = [.homebrew, .sparkle, .electronBuilder, .tauri,
      .vscodeUpdater, .releaseJSON, .githubReleases, .appStore, .selfManaged]
    for source in sources {
      let previous = app(source: source)
      var current = app(version: "1.15.0")
      current.clearReleaseMetadata()
      let result = AppLibrary.mergeKeepingCheckResults([current], previous: [previous])[0]
      XCTAssertEqual(result.latestVersion, "1.15.0")
      XCTAssertNil(result.releaseNotes, "\(source)")
      XCTAssertNil(result.releaseNotesURL)
      XCTAssertNil(result.releaseDate)
      XCTAssertNil(result.packageByteCount)
    }
  }

  func testSameVersionDifferentBuildDoesNotReuseMetadata() {
    var previous = app()
    previous.latestBuildVersion = "100"
    var current = app()
    current.latestBuildVersion = "101"
    current.clearReleaseMetadata()
    let result = AppLibrary.mergeKeepingCheckResults([current], previous: [previous])[0]
    XCTAssertNil(result.releaseNotes)
    XCTAssertEqual(result.latestBuildVersion, "101")
  }

  func testRemoteReleaseDoesNotKeepPreviousLink() {
    var application = app()
    application.applyRemoteRelease(version: "1.15.0", releaseNotes: "New notes", canInstall: true)
    XCTAssertEqual(application.releaseNotes, "New notes")
    XCTAssertNil(application.releaseNotesURL)
  }

  func testInstalledReleaseDropsNotesForDifferentVersionOrBuild() {
    for source in [UpdateSource.vscodeUpdater, .releaseJSON] {
      var application = app(source: source, version: "1.15.0")
      application.applyInstalledRelease()
      XCTAssertNil(application.releaseNotes)
      XCTAssertNil(application.releaseNotesURL)
      XCTAssertEqual(application.latestVersion, application.currentVersion)
      XCTAssertEqual(application.status, .upToDate)
    }
    var application = app(source: .vscodeUpdater)
    application.buildVersion = "new"
    application.latestBuildVersion = "old"
    application.applyInstalledRelease()
    XCTAssertNil(application.releaseNotes)
  }

  func testAlternateCheckDoesNotCarryUnattributedNotes() throws {
    var original = app()
    original.alternateUpdateSource = .sparkle
    original.alternateSourceURL = URL(string: "https://example.com/appcast.xml")
    let alternate = try XCTUnwrap(original.alternateUpdateCheckRecord)
    XCTAssertNil(alternate.releaseNotes)
    XCTAssertNil(alternate.releaseNotesURL)
    XCTAssertNil(alternate.releaseDate)
  }

  func testDifferentAlternateVersionDoesNotSupplySizeOrBuild() {
    var original = app(version: "1.15.0")
    original.clearReleaseMetadata()
    var checked = app(source: .tauri)
    checked.latestBuildVersion = "100"
    let result = HomebrewUpdateProvider.mergeAlternateCheckResult(checked, intoHomebrew: original)
    XCTAssertNil(result.releaseNotes)
    XCTAssertNil(result.packageByteCount)
    XCTAssertNil(result.latestBuildVersion)
  }

  func testOldSnapshotsInvalidateNotesOnce() throws {
    let snapshot = ApplicationLibrarySnapshot(applications: [app()])
    let data = try JSONEncoder().encode(snapshot)
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json.removeValue(forKey: "releaseMetadataRevision")
    var old = try JSONDecoder().decode(ApplicationLibrarySnapshot.self,
      from: JSONSerialization.data(withJSONObject: json))
    old.migrateReleaseMetadataIfNeeded()
    XCTAssertNil(old.applications[0].releaseNotes)
    XCTAssertEqual(old.applications[0].latestVersion, "1.14.0")
    var current = try JSONDecoder().decode(ApplicationLibrarySnapshot.self, from: data)
    current.migrateReleaseMetadataIfNeeded()
    XCTAssertEqual(current.applications[0].releaseNotes, "Old notes")
  }
}
