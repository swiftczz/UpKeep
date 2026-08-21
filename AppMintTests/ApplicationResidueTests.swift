import Foundation
import XCTest

@testable import AppMint

final class ApplicationResidueTests: XCTestCase {
  func testMatchesBundleIdentifierLeavesAndTeamGroupContainer() {
    let identity = ApplicationResidueIdentity(
      bundleIdentifier: "com.sequel-ace.sequel-ace",
      teamIdentifier: "NKQ4HJ66PX",
      names: ["Sequel Ace", "SequelAce"],
      updaterCacheDirName: "@sequel-updater",
      homebrewToken: nil
    )

    XCTAssertTrue(identity.matches(leaf: "com.sequel-ace.sequel-ace"))
    XCTAssertTrue(identity.matches(leaf: "com.sequel-ace.sequel-ace.plist"))
    XCTAssertTrue(identity.matches(leaf: "com.sequel-ace.sequel-ace.sfl4"))
    XCTAssertTrue(identity.matches(leaf: "com.sequel-ace.sequel-ace.sfl3"))
    XCTAssertTrue(identity.matches(leaf: "NKQ4HJ66PX.sequel-ace"))
    XCTAssertTrue(identity.matches(leaf: "Sequel Ace"))
    XCTAssertTrue(identity.matches(leaf: "@sequel-updater"))
    XCTAssertTrue(identity.matches(leaf: "Sequel Ace_2026-01-01-120000.crash"))
    XCTAssertFalse(identity.matches(leaf: "NKQ4HJ66PX.other-app"))
    XCTAssertFalse(identity.matches(leaf: "com.apple.Safari"))
  }

  func testDoesNotUseGenericBundleSuffixAlone() {
    let identity = ApplicationResidueIdentity(
      bundleIdentifier: "com.example.app",
      teamIdentifier: "ABCD123456",
      names: ["Example"],
      updaterCacheDirName: nil,
      homebrewToken: nil
    )

    XCTAssertTrue(identity.matches(leaf: "com.example.app"))
    XCTAssertTrue(identity.matches(leaf: "ABCD123456.com.example.app"))
    XCTAssertFalse(identity.matches(leaf: "app"))
    XCTAssertFalse(identity.matches(leaf: "ABCD123456.other"))
  }

  func testMatchesLowercasedSharedFileListLeaf() {
    let identity = ApplicationResidueIdentity(
      bundleIdentifier: "com.billcz.pdfmarker.PDFMarker",
      teamIdentifier: nil,
      names: ["PDF Marker"],
      updaterCacheDirName: nil,
      homebrewToken: nil
    )

    XCTAssertTrue(
      identity.matches(leaf: "com.billcz.pdfmarker.pdfmarker.sfl3")
    )
    XCTAssertTrue(identity.matches(leaf: "com.billcz.pdfmarker.PDFMarker"))
    XCTAssertFalse(identity.matches(leaf: "com.billcz.other.pdfmarker.sfl3"))
  }

  func testDoesNotListProtectedRecentDocuments() throws {
    let fileManager = FileManager.default
    let fixture = fileManager.temporaryDirectory
      .appendingPathComponent("AppMintResidueSFL-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: fixture) }

    let applicationURL = fixture.appendingPathComponent("PDF Marker.app", isDirectory: true)
    let library = fixture.appendingPathComponent("Library", isDirectory: true)
    let recentDocuments = library.appending(
      path:
        "Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments",
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: applicationURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: recentDocuments, withIntermediateDirectories: true)
    try Data("sfl".utf8).write(
      to: recentDocuments.appendingPathComponent("com.billcz.pdfmarker.pdfmarker.sfl3")
    )

    let scanner = ApplicationResidueScanner(
      fileManager: fileManager,
      homeDirectory: fixture,
      libraryDirectories: [library],
      receiptsDirectory: nil,
      darwinDirectories: [],
      caskroomDirectories: [],
      teamIdentifier: { _ in nil },
      bundleName: { _ in "PDF Marker" },
      updaterCacheDirName: { _ in nil }
    )
    let application = AppRecord(
      name: "PDF Marker",
      bundleIdentifier: "com.billcz.pdfmarker.PDFMarker",
      applicationURL: applicationURL,
      currentVersion: "1.0"
    )

    let names = Set(scanner.items(for: application).map(\.displayName))
    XCTAssertFalse(names.contains("com.billcz.pdfmarker.pdfmarker.sfl3"))
  }

  func testBreadcrumbUsesHomeLayout() {
    let home = URL(fileURLWithPath: "/Users/demo")
    let url = home.appendingPathComponent("Library/Containers/com.example.app")
    XCTAssertEqual(
      ApplicationResiduePath.breadcrumb(for: url, homeDirectory: home),
      "Users › demo › Library › Containers › com.example.app"
    )
  }

  func testScannerFindsFixtureFilesAndSkipsOtherTeamApps() throws {
    let fileManager = FileManager.default
    let fixture = fileManager.temporaryDirectory
      .appendingPathComponent("AppMintResidue-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: fixture) }

    let applicationURL = fixture.appendingPathComponent("Sequel Ace.app", isDirectory: true)
    let library = fixture.appendingPathComponent("Library", isDirectory: true)
    let receipts = fixture.appendingPathComponent("receipts", isDirectory: true)
    let darwinCache = fixture.appendingPathComponent("C", isDirectory: true)
    let recentDocuments = library.appendingPathComponent(
      "Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments",
      isDirectory: true
    )

    try fileManager.createDirectory(at: applicationURL, withIntermediateDirectories: true)
    try Data("app".utf8).write(
      to: applicationURL.appendingPathComponent("Info.plist")
    )
    try createDirectory(
      library.appendingPathComponent("Containers/com.sequel-ace.sequel-ace", isDirectory: true)
    )
    try createDirectory(
      library.appendingPathComponent("Group Containers/NKQ4HJ66PX.sequel-ace", isDirectory: true)
    )
    try createDirectory(
      library.appendingPathComponent("Group Containers/NKQ4HJ66PX.other-app", isDirectory: true)
    )
    try createDirectory(
      library.appendingPathComponent("Application Support/Sequel Ace", isDirectory: true)
    )
    try fileManager.createDirectory(at: recentDocuments, withIntermediateDirectories: true)
    try Data("sfl".utf8).write(
      to: recentDocuments.appendingPathComponent("com.sequel-ace.sequel-ace.sfl4")
    )
    try createDirectory(
      library.appendingPathComponent(
        "Application Scripts/com.sequel-ace.sequel-ace",
        isDirectory: true
      )
    )
    try fileManager.createDirectory(at: receipts, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 180).write(
      to: receipts.appendingPathComponent("com.sequel-ace.sequel-ace.bom")
    )
    try Data("plist".utf8).write(
      to: receipts.appendingPathComponent("com.sequel-ace.sequel-ace.plist")
    )
    try createDirectory(
      darwinCache.appendingPathComponent("com.sequel-ace.sequel-ace", isDirectory: true)
    )
    try createDirectory(
      library.appendingPathComponent("Caches/com.sequel-ace.sequel-ace", isDirectory: true)
    )
    try fileManager.createDirectory(
      at: library.appendingPathComponent("Preferences", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data("plist".utf8).write(
      to: library.appendingPathComponent("Preferences/com.sequel-ace.sequel-ace.plist")
    )
    try fileManager.createDirectory(
      at: library.appendingPathComponent("Preferences/ByHost", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data("host".utf8).write(
      to: library.appendingPathComponent(
        "Preferences/ByHost/com.sequel-ace.sequel-ace.AAAA.plist"
      )
    )

    let scanner = ApplicationResidueScanner(
      fileManager: fileManager,
      homeDirectory: fixture,
      libraryDirectories: [library],
      receiptsDirectory: receipts,
      darwinDirectories: [darwinCache],
      caskroomDirectories: [],
      teamIdentifier: { _ in "NKQ4HJ66PX" },
      bundleName: { _ in "Sequel Ace" },
      updaterCacheDirName: { _ in nil }
    )

    let application = AppRecord(
      name: "Sequel Ace",
      bundleIdentifier: "com.sequel-ace.sequel-ace",
      applicationURL: applicationURL,
      currentVersion: "1.0"
    )
    let items = scanner.items(for: application)
    let names = Set(items.map(\.displayName))

    XCTAssertTrue(names.contains("Sequel Ace"))
    XCTAssertTrue(names.contains("com.sequel-ace.sequel-ace"))
    XCTAssertTrue(names.contains("NKQ4HJ66PX.sequel-ace"))
    XCTAssertFalse(names.contains("com.sequel-ace.sequel-ace.sfl4"))
    XCTAssertTrue(names.contains("com.sequel-ace.sequel-ace.bom"))
    XCTAssertFalse(names.contains("NKQ4HJ66PX.other-app"))
    XCTAssertEqual(items.filter { $0.category == .application }.count, 1)
    XCTAssertEqual(items.filter { $0.category == .containers }.count, 2)
    XCTAssertEqual(items.filter { $0.category == .caches }.count, 2)
    XCTAssertEqual(items.filter { $0.category == .preferences }.count, 2)
    XCTAssertEqual(items.filter { $0.category == .applicationSupport }.count, 1)
    XCTAssertTrue(items.contains { $0.category == .caches && $0.displayName == "com.sequel-ace.sequel-ace" })
    XCTAssertTrue(items.contains { $0.category == .preferences && $0.displayName.hasSuffix(".plist") })
  }

  func testUninstallerMovesSelectedFilesToTrash() async throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
      .appendingPathComponent("AppMintUninstall-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = directory.appendingPathComponent("Demo.app", isDirectory: true)
    let residueURL = directory.appendingPathComponent("com.example.demo.plist")
    defer { try? fileManager.removeItem(at: directory) }

    try fileManager.createDirectory(at: applicationURL, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: residueURL)

    let application = AppRecord(
      name: "Demo",
      bundleIdentifier: "com.example.demo",
      applicationURL: applicationURL,
      currentVersion: "1.0"
    )
    let items = [
      ApplicationResidueItem(
        url: applicationURL,
        displayName: "Demo",
        category: .application,
        byteCount: 4,
        isDirectory: true
      ),
      ApplicationResidueItem(
        url: residueURL,
        displayName: residueURL.lastPathComponent,
        category: .applicationSupport,
        byteCount: 4,
        isDirectory: false
      ),
    ]
    let process = ApplicationProcessClient(
      isRunning: { _ in false },
      quit: { _ in },
      launch: { _ in }
    )

    let result = try await ApplicationUninstaller.uninstall(
      application,
      items: items,
      fileManager: fileManager,
      process: process
    )

    XCTAssertTrue(result.didRemoveApplication)
    XCTAssertFalse(fileManager.fileExists(atPath: applicationURL.path))
    XCTAssertFalse(fileManager.fileExists(atPath: residueURL.path))
  }

  private func createDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: url.appendingPathComponent(".keep"))
  }
}
