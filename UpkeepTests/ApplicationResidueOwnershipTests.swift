import Foundation
import XCTest

@testable import Upkeep

final class ApplicationResidueOwnershipTests: XCTestCase {
  func testUnknownVariantAndNameMatchesAreListedButNotSelected() throws {
    let fixture = try ResidueOwnershipFixture()
    defer { fixture.remove() }
    let container = try fixture.item("Containers/com.example.Editor")
    let preferences = try fixture.item("Preferences/com.example.Editor.plist", file: true)
    let cache = try fixture.item("Caches/com.example.Editor")
    let variant = try fixture.item("Containers/com.example.Editor.beta")
    let support = try fixture.item("Application Support/Editor")
    let unrelated = try fixture.item("Containers/org.unrelated.Editor")

    let items = fixture.scanner().items(for: fixture.application)
    XCTAssertEqual(try fixture.find(variant, in: items).matchReason, .possibleBundleVariant)
    XCTAssertEqual(try fixture.find(support, in: items).matchReason, .nameOnly)
    XCTAssertFalse(items.contains { $0.id == unrelated.path })
    XCTAssertEqual(
      ApplicationResidueItem.defaultSelection(in: items),
      Set([
        fixture.application.applicationURL.path, container.path, preferences.path, cache.path,
      ]))
  }

  func testInstalledBetaApplicationIsExcludedFromAllResidueCategories() throws {
    let fixture = try ResidueOwnershipFixture()
    defer { fixture.remove() }
    let paths = try [
      "Containers/com.example.Editor.beta",
      "Caches/com.example.Editor.beta.ShipIt",
      "Preferences/com.example.Editor.beta.plist",
      "Application Scripts/com.example.Editor.beta",
    ].map { try fixture.item($0, file: $0.hasSuffix(".plist")) }
    let before = fixture.scanner().items(for: fixture.application)
    for path in paths { XCTAssertFalse(try fixture.find(path, in: before).isSelectedByDefault) }

    _ = try fixture.install(name: "Editor Beta", identifier: "com.example.Editor.beta")
    let after = fixture.scanner().items(for: fixture.application)
    XCTAssertFalse(after.contains { paths.map(\.path).contains($0.id) })
  }

  func testDeclaredUpdaterCacheIsListedButNotSelected() throws {
    let fixture = try ResidueOwnershipFixture()
    defer { fixture.remove() }
    let cache = try fixture.item("Caches/editor-updater")
    let support = try fixture.item("Application Support/editor-updater")
    let items = fixture.scanner(updaterCaches: ["com.example.Editor": "editor-updater"])
      .items(for: fixture.application)
    XCTAssertEqual(try fixture.find(cache, in: items).matchReason, .declaredUpdaterCache)
    XCTAssertFalse(try fixture.find(cache, in: items).isSelectedByDefault)
    XCTAssertFalse(try fixture.find(support, in: items).isSelectedByDefault)
  }

  func testPreferencesUseDirectorySpecificRules() throws {
    let fixture = try ResidueOwnershipFixture()
    defer { fixture.remove() }
    let hostPreference = try fixture.item(
      "Preferences/ByHost/com.example.Editor.12345678-1234-1234-1234-123456789ABC.plist",
      file: true
    )
    let variant = try fixture.item("Preferences/ByHost/com.example.Editor.beta.plist", file: true)
    let misleadingContainer = try fixture.item("Containers/com.example.Editor.plist")
    let items = fixture.scanner().items(for: fixture.application)
    XCTAssertTrue(try fixture.find(hostPreference, in: items).isSelectedByDefault)
    XCTAssertFalse(try fixture.find(variant, in: items).isSelectedByDefault)
    XCTAssertFalse(try fixture.find(misleadingContainer, in: items).isSelectedByDefault)
  }

  func testAllDeclaredGroupsAndNameMatchesAreRetained() throws {
    let fixture = try ResidueOwnershipFixture()
    defer { fixture.remove() }
    _ = try fixture.install(name: "Companion", identifier: "org.example.Companion")
    let shared = try fixture.item("Group Containers/TEAM.shared-storage")
    let scripts = try fixture.item("Application Scripts/TEAM.shared-storage")
    let exclusive = try fixture.item("Group Containers/TEAM.private-storage")
    let otherOnly = try fixture.item("Group Containers/TEAM.Editor")
    let items = fixture.scanner(groups: [
      "com.example.Editor": ["TEAM.shared-storage", "TEAM.private-storage"],
      "org.example.Companion": ["TEAM.shared-storage", "TEAM.Editor"],
    ]).items(for: fixture.application)

    XCTAssertEqual(try fixture.find(shared, in: items).matchReason, .unverifiedGroupContainer)
    XCTAssertEqual(try fixture.find(scripts, in: items).matchReason, .unverifiedGroupContainer)
    XCTAssertFalse(try fixture.find(shared, in: items).isSelectedByDefault)
    XCTAssertFalse(try fixture.find(scripts, in: items).isSelectedByDefault)
    XCTAssertEqual(try fixture.find(exclusive, in: items).matchReason, .unverifiedGroupContainer)
    XCTAssertFalse(try fixture.find(exclusive, in: items).isSelectedByDefault)
    XCTAssertFalse(try fixture.find(otherOnly, in: items).isSelectedByDefault)
  }

  func testTeamAndNameAloneDoNotAuthorizeGroupContainerSelection() throws {
    let fixture = try ResidueOwnershipFixture()
    defer { fixture.remove() }
    let teamMatch = try fixture.item("Group Containers/TEAM.Editor")
    let bundleMatch = try fixture.item("Group Containers/com.example.Editor")
    let items = fixture.scanner().items(for: fixture.application)
    for path in [teamMatch, bundleMatch] {
      XCTAssertEqual(try fixture.find(path, in: items).matchReason, .undeclaredGroupContainer)
      XCTAssertFalse(try fixture.find(path, in: items).isSelectedByDefault)
    }
  }

  func testUnreadableOtherAppDoesNotBlockTargetScan() throws {
    let fixture = try ResidueOwnershipFixture()
    defer { fixture.remove() }
    _ = try fixture.install(name: "Unreadable", identifier: "org.example.Unreadable")
    let group = try fixture.item("Group Containers/TEAM.private-storage")
    let items = fixture.scanner(
      groups: ["com.example.Editor": ["TEAM.private-storage"]],
      unreadable: ["org.example.Unreadable"]
    ).items(for: fixture.application)
    XCTAssertEqual(try fixture.find(group, in: items).matchReason, .unverifiedGroupContainer)
    XCTAssertFalse(try fixture.find(group, in: items).isSelectedByDefault)
  }

  func testSecondInstallationWithSameBundleIdentifierKeepsSharedData() throws {
    let fixture = try ResidueOwnershipFixture()
    defer { fixture.remove() }
    _ = try fixture.install(name: "Editor Copy", identifier: "com.example.Editor")
    let data = try fixture.item("Containers/com.example.Editor")
    let items = fixture.scanner().items(for: fixture.application)
    XCTAssertEqual(try fixture.find(data, in: items).matchReason, .sharedWith(["Editor Copy"]))
    XCTAssertFalse(try fixture.find(data, in: items).isSelectedByDefault)
    XCTAssertTrue(
      try fixture.find(fixture.application.applicationURL, in: items).isSelectedByDefault)
  }

  func testSharedUpdaterCacheIsNotSelectedByDefault() throws {
    let fixture = try ResidueOwnershipFixture()
    defer { fixture.remove() }
    _ = try fixture.install(name: "Editor Beta", identifier: "com.example.Editor.beta")
    let cache = try fixture.item("Caches/editor-updater")
    let items = fixture.scanner(updaterCaches: [
      "com.example.Editor": "editor-updater", "com.example.Editor.beta": "editor-updater",
    ]).items(for: fixture.application)
    XCTAssertEqual(try fixture.find(cache, in: items).matchReason, .declaredUpdaterCache)
    XCTAssertFalse(try fixture.find(cache, in: items).isSelectedByDefault)
  }

  func testTargetExtensionGroupsAreListedButNotSelected() throws {
    let fixture = try ResidueOwnershipFixture()
    defer { fixture.remove() }
    _ = try fixture.install(name: "Companion", identifier: "org.example.Companion")
    _ = try fixture.install(
      name: "Extension", identifier: "org.example.Companion.extension",
      at: fixture.application.applicationURL.appendingPathComponent("Contents/PlugIns/Extension.appex")
    )
    let group = try fixture.item("Group Containers/TEAM.shared-storage")
    let items = fixture.scanner(groups: [
      "org.example.Companion.extension": ["TEAM.shared-storage"],
    ]).items(for: fixture.application)
    XCTAssertEqual(try fixture.find(group, in: items).matchReason, .unverifiedGroupContainer)
    XCTAssertFalse(try fixture.find(group, in: items).isSelectedByDefault)
  }

  func testTargetFrameworkHelperGroupsAreListedButNotSelected() throws {
    let fixture = try ResidueOwnershipFixture()
    defer { fixture.remove() }
    _ = try fixture.install(name: "Companion", identifier: "org.example.Companion")
    _ = try fixture.install(
      name: "Helper", identifier: "org.example.Companion.helper",
      at: fixture.application.applicationURL.appendingPathComponent(
        "Contents/Frameworks/Example.framework/Versions/A/XPCServices/Helper.xpc"
      )
    )
    let group = try fixture.item("Group Containers/TEAM.shared-storage")
    let items = fixture.scanner(groups: [
      "org.example.Companion.helper": ["TEAM.shared-storage"],
    ]).items(for: fixture.application)
    XCTAssertEqual(try fixture.find(group, in: items).matchReason, .unverifiedGroupContainer)
    XCTAssertFalse(try fixture.find(group, in: items).isSelectedByDefault)
  }

  func testReadsApplicationGroupsFromSignedBundle() throws {
    let fixture = try ResidueOwnershipFixture()
    defer { fixture.remove() }
    let applicationURL = fixture.application.applicationURL
    let executableURL = applicationURL.appendingPathComponent("Contents/MacOS/Fixture")
    try FileManager.default.createDirectory(
      at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executableURL)
    let entitlementsURL = fixture.root.appendingPathComponent("entitlements.plist")
    let groups = ["TEAM.shared-storage", "group.com.example.Editor"]
    try PropertyListSerialization.data(
      fromPropertyList: ["com.apple.security.application-groups": groups], format: .xml, options: 0
    ).write(to: entitlementsURL)
    _ = try ProcessRunner.blockingRun(
      executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
      arguments: [
        "--force", "--sign", "-", "--entitlements", entitlementsURL.path, applicationURL.path,
      ]
    )
    XCTAssertEqual(ApplicationCodeSigning.applicationGroups(at: applicationURL), Set(groups))
    XCTAssertNil(ApplicationCodeSigning.teamIdentifier(at: applicationURL))
  }

  func testEmbeddedSDKDataIsNeverSelectedAndNewHelpersAreReadWithoutAnIndex() throws {
    let fixture = try ResidueOwnershipFixture()
    defer { fixture.remove() }
    let data = try fixture.item("Caches/org.sparkle-project.Updater")
    let scanner = fixture.scanner()
    XCTAssertFalse(scanner.items(for: fixture.application).contains { $0.id == data.path })
    _ = try fixture.install(name: "Updater", identifier: "org.sparkle-project.Updater",
      at: fixture.application.applicationURL.appendingPathComponent("Contents/XPCServices/Updater.xpc"))
    let items = scanner.items(for: fixture.application)
    XCTAssertEqual(try fixture.find(data, in: items).matchReason, .embeddedBundle)
    XCTAssertFalse(try fixture.find(data, in: items).isSelectedByDefault)
  }

  func testWrappedIOSAppReadsItsOwnGroupDeclarations() throws {
    let fixture = try ResidueOwnershipFixture()
    defer { fixture.remove() }
    let wrapper = fixture.applicationsDirectory.appendingPathComponent("Mobile.app")
    let wrapped = try fixture.install(name: "Mobile", identifier: "com.example.mobile",
      at: wrapper.appendingPathComponent("Wrapper/Mobile.app"))
    try FileManager.default.createSymbolicLink(at: wrapper.appendingPathComponent("WrappedBundle"),
      withDestinationURL: wrapped)
    let group = try fixture.item("Group Containers/TEAM.mobile")
    let scanner = fixture.scanner(groups: ["com.example.mobile": ["TEAM.mobile"]])
    let app = AppRecord(name: "Mobile", bundleIdentifier: "com.example.mobile",
      applicationURL: wrapper, currentVersion: "1")
    let items = scanner.items(for: app)
    XCTAssertEqual(try fixture.find(group, in: items).matchReason, .unverifiedGroupContainer)
    XCTAssertTrue(try fixture.find(wrapper, in: items).isSelectedByDefault)
  }
}

private struct ResidueOwnershipFixture: Sendable {
  let root: URL
  var applicationsDirectory: URL { root.appendingPathComponent("Applications") }
  var library: URL { root.appendingPathComponent("Library") }
  var application: AppRecord {
    AppRecord(
      name: "Editor", bundleIdentifier: "com.example.Editor",
      applicationURL: applicationsDirectory.appendingPathComponent("Editor.app"),
      currentVersion: "1.0"
    )
  }

  init() throws {
    root =
      FileManager.default.temporaryDirectory
      .appendingPathComponent("UpkeepOwnership-\(UUID().uuidString)").standardizedFileURL
    _ = try install(name: "Editor", identifier: "com.example.Editor")
  }

  func install(name: String, identifier: String, at location: URL? = nil) throws -> URL {
    let url = location ?? applicationsDirectory.appendingPathComponent(name + ".app")
    let contents = url.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": identifier, "CFBundleName": name,
        "CFBundlePackageType": "APPL", "CFBundleExecutable": "Fixture",
      ], format: .xml, options: 0
    ).write(to: contents.appendingPathComponent("Info.plist"))
    return url
  }

  func item(_ path: String, file: Bool = false) throws -> URL {
    let url = library.appendingPathComponent(path).standardizedFileURL
    try FileManager.default.createDirectory(
      at: file ? url.deletingLastPathComponent() : url, withIntermediateDirectories: true
    )
    if file { try Data("fixture".utf8).write(to: url) }
    return url
  }

  func scanner(
    groups: [String: Set<String>] = [:],
    unreadable: Set<String> = [],
    updaterCaches: [String: String] = [:]
  ) -> ApplicationResidueScanner {
    let groupsReader: @Sendable (URL) -> Set<String>? = { url in
      guard let identifier = Bundle(url: url)?.bundleIdentifier,
        !unreadable.contains(identifier)
      else { return nil }
      return groups[identifier] ?? []
    }
    let cacheReader: @Sendable (URL) -> String? = { url in
      Bundle(url: url)?.bundleIdentifier.flatMap { updaterCaches[$0] }
    }
    return ApplicationResidueScanner(
      fileManager: .default, homeDirectory: root, libraryDirectories: [library],
      receiptsDirectory: nil, darwinDirectories: [], caskroomDirectories: [],
      teamIdentifier: { _ in "TEAM" }, bundleName: { _ in "Editor" },
      updaterCacheDirName: cacheReader,
      applicationGroups: groupsReader,
      knownApplications: ((try? FileManager.default.contentsOfDirectory(
        at: applicationsDirectory, includingPropertiesForKeys: nil)) ?? []).compactMap { url in
          guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
          return AppRecord(name: url.deletingPathExtension().lastPathComponent,
            bundleIdentifier: id, applicationURL: url, currentVersion: "1")
        }
    )
  }

  func find(
    _ url: URL, in items: [ApplicationResidueItem],
    file: StaticString = #filePath, line: UInt = #line
  ) throws -> ApplicationResidueItem {
    try XCTUnwrap(
      items.first { $0.id == url.standardizedFileURL.path }, "Missing \(url.path)", file: file,
      line: line)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
