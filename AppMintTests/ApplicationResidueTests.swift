import AppKit
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
    XCTAssertTrue(
      items.contains { $0.category == .caches && $0.displayName == "com.sequel-ace.sequel-ace" }
    )
    XCTAssertTrue(
      items.contains { $0.category == .preferences && $0.displayName.hasSuffix(".plist") }
    )
  }

  func testScannerSkipsSystemManagedDarwinRuntimeDirectories() throws {
    let fileManager = FileManager.default
    let fixture = fileManager.temporaryDirectory
      .appendingPathComponent("AppMintResidueManagedDarwin-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: fixture) }

    let applicationURL = fixture.appendingPathComponent("Demo.app", isDirectory: true)
    let darwinTemp = fixture.appendingPathComponent("T", isDirectory: true)
    let runtimeDirectory = darwinTemp.appendingPathComponent(
      "com.apple.WebKit.GPU+com.example.demo",
      isDirectory: true
    )
    let normalDirectory = darwinTemp.appendingPathComponent(
      "com.example.demo",
      isDirectory: true
    )
    try fileManager.createDirectory(at: applicationURL, withIntermediateDirectories: true)
    try createDirectory(runtimeDirectory)
    try createDirectory(normalDirectory)

    let scanner = ApplicationResidueScanner(
      fileManager: fileManager,
      homeDirectory: fixture,
      libraryDirectories: [],
      receiptsDirectory: nil,
      darwinDirectories: [darwinTemp],
      caskroomDirectories: [],
      teamIdentifier: { _ in nil },
      bundleName: { _ in "Demo" },
      updaterCacheDirName: { _ in nil },
      systemManagedDarwinItem: { $0.lastPathComponent.hasPrefix("com.apple.WebKit.") }
    )
    let application = AppRecord(
      name: "Demo",
      bundleIdentifier: "com.example.demo",
      applicationURL: applicationURL,
      currentVersion: "1.0"
    )

    let names = Set(scanner.items(for: application).map(\.displayName))
    XCTAssertFalse(names.contains("com.apple.WebKit.GPU+com.example.demo"))
    XCTAssertTrue(names.contains("com.example.demo"))
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
        byteCount: 4
      ),
      ApplicationResidueItem(
        url: residueURL,
        displayName: residueURL.lastPathComponent,
        category: .applicationSupport,
        byteCount: 4
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

  func testUninstallerUsesFinderFallbackAndVerifiesEveryPathWasRemoved() async throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
      .appendingPathComponent("AppMintFinderTrash-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = directory.appendingPathComponent("Demo.app", isDirectory: true)
    let residueURL = directory.appendingPathComponent("com.example.demo.plist")
    defer { try? fileManager.removeItem(at: directory) }

    try fileManager.createDirectory(at: applicationURL, withIntermediateDirectories: true)
    try Data("residue".utf8).write(to: residueURL)

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
        byteCount: 0
      ),
      ApplicationResidueItem(
        url: residueURL,
        displayName: residueURL.lastPathComponent,
        category: .preferences,
        byteCount: 7
      ),
    ]
    let process = ApplicationProcessClient(
      isRunning: { _ in false },
      quit: { _ in },
      launch: { _ in }
    )
    let trashClient = ApplicationUninstaller.TrashClient(
      moveDirectly: { _ in
        throw CocoaError(.fileWriteNoPermission)
      },
      moveUsingFinder: { urls in
        for url in urls {
          try fileManager.removeItem(at: url)
        }
      }
    )

    let result = try await ApplicationUninstaller.uninstall(
      application,
      items: items,
      fileManager: fileManager,
      process: process,
      trashClient: trashClient
    )

    XCTAssertTrue(result.didRemoveApplication)
    XCTAssertFalse(fileManager.fileExists(atPath: applicationURL.path))
    XCTAssertFalse(fileManager.fileExists(atPath: residueURL.path))
  }

  func testUninstallerQuitsRunningApplicationBeforeRemovingResidueOnly() async throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
      .appendingPathComponent("AppMintResidueOnlyQuit-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = directory.appendingPathComponent("Demo.app", isDirectory: true)
    let residueURL = directory.appendingPathComponent("com.example.demo.plist")
    defer { try? fileManager.removeItem(at: directory) }

    try fileManager.createDirectory(at: applicationURL, withIntermediateDirectories: true)
    try Data("residue".utf8).write(to: residueURL)

    let application = AppRecord(
      name: "Demo",
      bundleIdentifier: "com.example.demo",
      applicationURL: applicationURL,
      currentVersion: "1.0"
    )
    let item = ApplicationResidueItem(
      url: residueURL,
      displayName: residueURL.lastPathComponent,
      category: .preferences,
      byteCount: 7
    )
    let quitCount = LockedCounter()
    let process = ApplicationProcessClient(
      isRunning: { _ in quitCount.value == 0 },
      quit: { _ in quitCount.increment() },
      launch: { _ in }
    )
    let trashClient = ApplicationUninstaller.TrashClient(
      moveDirectly: { url in try fileManager.removeItem(at: url) },
      moveUsingFinder: { _ in XCTFail("Unexpected Finder fallback") }
    )

    let result = try await ApplicationUninstaller.uninstall(
      application,
      items: [item],
      fileManager: fileManager,
      process: process,
      trashClient: trashClient
    )

    XCTAssertFalse(result.didRemoveApplication)
    XCTAssertEqual(quitCount.value, 1)
    XCTAssertTrue(fileManager.fileExists(atPath: applicationURL.path))
    XCTAssertFalse(fileManager.fileExists(atPath: residueURL.path))
  }

  func testUninstallerReportsFinderItemsThatStillExist() async throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
      .appendingPathComponent("AppMintFinderVerify-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = directory.appendingPathComponent("Demo.app", isDirectory: true)
    defer { try? fileManager.removeItem(at: directory) }
    try fileManager.createDirectory(at: applicationURL, withIntermediateDirectories: true)

    let application = AppRecord(
      name: "Demo",
      bundleIdentifier: "com.example.demo",
      applicationURL: applicationURL,
      currentVersion: "1.0"
    )
    let item = ApplicationResidueItem(
      url: applicationURL,
      displayName: "Demo",
      category: .application,
      byteCount: 0
    )
    let process = ApplicationProcessClient(
      isRunning: { _ in false },
      quit: { _ in },
      launch: { _ in }
    )
    let trashClient = ApplicationUninstaller.TrashClient(
      moveDirectly: { _ in
        throw CocoaError(.fileWriteNoPermission)
      },
      moveUsingFinder: { _ in }
    )

    do {
      _ = try await ApplicationUninstaller.uninstall(
        application,
        items: [item],
        fileManager: fileManager,
        process: process,
        trashClient: trashClient
      )
      XCTFail("Expected the verified path to remain")
    } catch let error as ApplicationUninstallerError {
      XCTAssertTrue(error.localizedDescription.contains("Demo"))
    }
  }

  func testProtectedContainerAccessResolvesOnlyContainerChildren() {
    let home = URL(fileURLWithPath: "/Users/demo", isDirectory: true)
    let container = URL(
      fileURLWithPath: "/Users/demo/Library/Containers/com.example.demo",
      isDirectory: true
    )
    let child = container.appendingPathComponent("Data/Library", isDirectory: true)
    let groupContainer = URL(
      fileURLWithPath: "/Users/demo/Library/Group Containers/TEAM.example.demo",
      isDirectory: true
    )

    XCTAssertEqual(
      ApplicationContainerAccess.protectedContainerRoot(
        containing: child,
        homeDirectory: home
      ),
      container
    )
    XCTAssertEqual(
      ApplicationContainerAccess.protectedContainerRoot(
        containing: groupContainer,
        homeDirectory: home
      ),
      groupContainer
    )
    XCTAssertNil(
      ApplicationContainerAccess.protectedContainerRoot(
        containing: URL(fileURLWithPath: "/Users/demo/Library/Containers"),
        homeDirectory: home
      )
    )
    XCTAssertNil(
      ApplicationContainerAccess.protectedContainerRoot(
        containing: URL(fileURLWithPath: "/Users/demo/Library/Application Support/demo"),
        homeDirectory: home
      )
    )
  }

  func testUninstallerDoesNotIgnoreAFallbackCompletionError() async throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
      .appendingPathComponent("AppMintTrashCompletion-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = directory.appendingPathComponent("Demo.app", isDirectory: true)
    defer { try? fileManager.removeItem(at: directory) }
    try fileManager.createDirectory(at: applicationURL, withIntermediateDirectories: true)

    let application = AppRecord(
      name: "Demo",
      bundleIdentifier: "com.example.demo",
      applicationURL: applicationURL,
      currentVersion: "1.0"
    )
    let item = ApplicationResidueItem(
      url: applicationURL,
      displayName: "Demo",
      category: .application,
      byteCount: 0
    )
    let process = ApplicationProcessClient(
      isRunning: { _ in false },
      quit: { _ in },
      launch: { _ in }
    )
    let trashClient = ApplicationUninstaller.TrashClient(
      moveDirectly: { _ in throw CocoaError(.fileWriteNoPermission) },
      moveUsingFinder: { urls in
        try fileManager.removeItem(at: urls[0])
        throw FinderTrashError.failed("暂存目录未能进入废纸篓")
      }
    )

    do {
      _ = try await ApplicationUninstaller.uninstall(
        application,
        items: [item],
        fileManager: fileManager,
        process: process,
        trashClient: trashClient
      )
      XCTFail("Expected the fallback completion error")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("暂存目录未能进入废纸篓"))
    }
  }

  func testFinderBatchTrashOnlyAcceptsSpecificCleanupChildren() {
    let home = URL(fileURLWithPath: "/Users/demo", isDirectory: true)

    XCTAssertTrue(
      FinderBatchTrash.isAllowedTarget(
        URL(fileURLWithPath: "/Applications/UPDF.app"),
        homeDirectory: home
      )
    )
    XCTAssertTrue(
      FinderBatchTrash.isAllowedTarget(
        URL(fileURLWithPath: "/Users/demo/Library/Caches/com.example.app"),
        homeDirectory: home
      )
    )
    XCTAssertTrue(
      FinderBatchTrash.isAllowedTarget(
        URL(fileURLWithPath: "/var/db/receipts/com.example.app.bom"),
        homeDirectory: home
      )
    )

    XCTAssertFalse(
      FinderBatchTrash.isAllowedTarget(
        URL(fileURLWithPath: "/"),
        homeDirectory: home
      )
    )
    XCTAssertFalse(
      FinderBatchTrash.isAllowedTarget(
        URL(fileURLWithPath: "/Applications"),
        homeDirectory: home
      )
    )
    XCTAssertFalse(
      FinderBatchTrash.isAllowedTarget(
        URL(fileURLWithPath: "/var/db/receipts"),
        homeDirectory: home
      )
    )
    XCTAssertFalse(
      FinderBatchTrash.isAllowedTarget(
        URL(fileURLWithPath: "/var/folders/zz/demo/T/com.apple.WebKit.GPU+com.example.app"),
        homeDirectory: home
      )
    )
    XCTAssertFalse(
      FinderBatchTrash.isAllowedTarget(
        URL(fileURLWithPath: "/var/folders/zz/demo/T", isDirectory: true),
        homeDirectory: home
      )
    )
    XCTAssertFalse(
      FinderBatchTrash.isAllowedTarget(
        URL(fileURLWithPath: "/var/folders/zz/demo/C", isDirectory: true),
        homeDirectory: home
      )
    )
    XCTAssertFalse(
      FinderBatchTrash.isAllowedTarget(
        URL(fileURLWithPath: "/Users/demo/Library/Containers/com.example.app"),
        homeDirectory: home
      )
    )
    XCTAssertFalse(
      FinderBatchTrash.isAllowedTarget(
        URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
        homeDirectory: home
      )
    )
  }

  func testTrashFallbackPartitionsProtectedContainersBeforeFinderBatch() {
    let home = URL(fileURLWithPath: "/Users/demo", isDirectory: true)
    let application = URL(fileURLWithPath: "/Applications/Demo.app", isDirectory: true)
    let receipt = URL(fileURLWithPath: "/var/db/receipts/com.example.demo.bom")
    let container = URL(
      fileURLWithPath: "/Users/demo/Library/Containers/com.example.demo",
      isDirectory: true
    )
    let groupContainer = URL(
      fileURLWithPath: "/Users/demo/Library/Group Containers/TEAM.example.demo",
      isDirectory: true
    )

    let groups = FinderTrash.partitionTargets(
      [application, container, receipt, groupContainer],
      homeDirectory: home
    )

    XCTAssertEqual(groups.unprotected, [application, receipt])
    XCTAssertEqual(groups.protected, [container, groupContainer])
  }

  func testDarwinVolatileTargetsMoveIntoUserTrashDirectly() async throws {
    let fileManager = FileManager.default
    let fixture = fileManager.temporaryDirectory
      .appendingPathComponent("AppMintUserTrashMove-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: fixture) }

    let home = fixture.appendingPathComponent("Home", isDirectory: true)
    let temporaryDirectory =
      fixture
      .appendingPathComponent("var/folders/demo/T", isDirectory: true)
    let target =
      temporaryDirectory
      .appendingPathComponent("com.apple.WebKit.GPU+com.example.app", isDirectory: true)
    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)

    XCTAssertTrue(
      UserTrashMove.isDarwinVolatileTarget(target, temporaryDirectory: temporaryDirectory)
    )

    try await UserTrashMove.moveToTrash(
      [target],
      homeDirectory: home,
      temporaryDirectory: temporaryDirectory
    )

    XCTAssertFalse(fileManager.fileExists(atPath: target.path))
    let trashDirectory = home.appendingPathComponent(".Trash", isDirectory: true)
    let trashBundles = try fileManager.contentsOfDirectory(
      at: trashDirectory,
      includingPropertiesForKeys: nil
    )
    let movedTargets = trashBundles.map {
      $0.appendingPathComponent("com.apple.WebKit.GPU+com.example.app", isDirectory: true)
    }
    XCTAssertTrue(movedTargets.contains { fileManager.fileExists(atPath: $0.path) })
  }

  @MainActor
  func testTrashAppleScriptsCompile() throws {
    for source in [FinderBatchTrash.scriptSource] {
      let script = try XCTUnwrap(NSAppleScript(source: source))
      var errorInfo: NSDictionary?
      XCTAssertTrue(script.compileAndReturnError(&errorInfo), "\(errorInfo ?? [:])")
    }
  }

  func testFinderBatchTrashUsesOneFinderBatchWithoutMutatingPackageContents() {
    let batchDelete = "delete targetItems"
    XCTAssertEqual(
      FinderBatchTrash.scriptSource.components(separatedBy: batchDelete).count - 1,
      1
    )
    XCTAssertTrue(FinderBatchTrash.scriptSource.contains("tell application \"Finder\""))
    XCTAssertFalse(FinderBatchTrash.scriptSource.contains("chown"))
  }

  func testUserTrashMoveRejectsNonVolatileTargets() async throws {
    let fileManager = FileManager.default
    let fixture = fileManager.temporaryDirectory
      .appendingPathComponent("AppMintUserTrashReject-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: fixture) }

    let home = fixture.appendingPathComponent("Home", isDirectory: true)
    let temporaryDirectory = fixture.appendingPathComponent("T", isDirectory: true)
    let target = fixture.appendingPathComponent("Library/com.example.app", isDirectory: true)
    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)

    do {
      try await UserTrashMove.moveToTrash(
        [target],
        homeDirectory: home,
        temporaryDirectory: temporaryDirectory
      )
      XCTFail("Expected non-volatile target to be rejected")
    } catch let error as FinderTrashError {
      XCTAssertTrue(error.localizedDescription.contains(target.lastPathComponent))
    }
  }

  @MainActor
  func testTrashAppleScriptDoesNotBlockMainActor() async throws {
    let clock = ContinuousClock()
    let startedAt = clock.now
    let scriptTask = Task {
      try await FinderTrash.execute("delay 0.25", arguments: [])
    }

    try await Task.sleep(for: .milliseconds(40))
    XCTAssertLessThan(startedAt.duration(to: clock.now), .milliseconds(180))
    try await scriptTask.value
  }

  private func createDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: url.appendingPathComponent(".keep"))
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  var value: Int {
    lock.withLock { storage }
  }

  func increment() {
    lock.withLock {
      storage += 1
    }
  }
}
