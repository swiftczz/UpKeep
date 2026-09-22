import Foundation
import XCTest
@testable import Upkeep

final class ApplicationResidueScanTests: XCTestCase, @unchecked Sendable {
  func testDiscoveryOnlyListsFixedLocationsAndReadsTheSelectedApp() throws {
    let fixture = try ResidueScanFixture()
    defer { fixture.remove() }
    // Large resources and other apps must not be walked to discover residue.
    for path in ["Example.app/Contents/Resources/Archive/Other.app", "Unrelated.app"] {
      try FileManager.default.createDirectory(
        at: fixture.root.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    let files = RecordingResidueFileManager()
    var scanner = fixture.scanner
    scanner.fileManager = files
    scanner.libraryDirectories = [fixture.root.appendingPathComponent("Library")]
    let appPath = fixture.application.applicationURL.resolvingSymlinksInPath().path
    scanner.applicationGroups = { url in
      XCTAssertEqual(url.path, appPath)
      return []
    }
    let items = scanner.items(for: fixture.application, includingSizes: false)
    XCTAssertEqual(items.count, 1)
    XCTAssertFalse(files.directories.isEmpty)
    for directory in files.directories {
      XCTAssertTrue(directory.path.hasPrefix(appPath + "/")
        || directory.path.hasPrefix(fixture.root.appendingPathComponent("Library").path + "/"))
      XCTAssertFalse(directory.path.contains("/Resources/"))
    }
  }

  func testTargetReadDoesNotFollowCodeDirectorySymlinksOutsideApp() throws {
    let fixture = try ResidueScanFixture()
    defer { fixture.remove() }
    let outside = fixture.root.appendingPathComponent("Unrelated.app")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: fixture.application.applicationURL.appendingPathComponent("Contents/Helpers"),
      withDestinationURL: outside)
    let files = RecordingResidueFileManager()
    _ = ApplicationResidueTarget.read(at: fixture.application.applicationURL,
      fileManager: files, applicationGroups: { _ in [] })
    XCTAssertFalse(files.directories.contains { $0.path.hasPrefix(outside.path) })
  }

  func testDiscoveryDoesNotWaitForDirectorySizes() async throws {
    let fixture = try ResidueScanFixture()
    defer { fixture.remove() }
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    var scanner = fixture.scanner
    scanner.sizeCalculator = { _ in
      _ = release.wait(timeout: .now() + 5)
      return 4096
    }
    var iterator = scanner.events(for: fixture.application).makeAsyncIterator()
    guard case .found(let items) = await iterator.next() else {
      return XCTFail("Expected discovery before measurements")
    }
    XCTAssertEqual(items.count, 1)
    XCTAssertFalse(items[0].isSizeCalculated)
    XCTAssertEqual(items[0].formattedSize, "正在计算…")
    XCTAssertTrue(items[0].isSelectedByDefault)
    release.signal()
    guard case .measured(let item) = await iterator.next() else {
      return XCTFail("Expected size update")
    }
    XCTAssertEqual(item.id, items[0].id)
    XCTAssertEqual(item.matchReason, items[0].matchReason)
    XCTAssertTrue(item.isSizeCalculated)
    XCTAssertEqual(item.byteCount, 4096)
  }

  func testCancellingConsumerStopsSizeCalculation() async throws {
    let fixture = try ResidueScanFixture()
    defer { fixture.remove() }
    let started = expectation(description: "size started")
    let stopped = expectation(description: "size cancelled")
    var scanner = fixture.scanner
    scanner.sizeCalculator = { _ in
      started.fulfill()
      let pause = DispatchSemaphore(value: 0)
      let deadline = Date().addingTimeInterval(5)
      while !Task.isCancelled && Date() < deadline {
        _ = pause.wait(timeout: .now() + 0.01)
      }
      if Task.isCancelled { stopped.fulfill() }
      return 0
    }
    let stream = scanner.events(for: fixture.application)
    let consumer = Task {
      for await _ in stream {}
    }
    await fulfillment(of: [started], timeout: 5)
    consumer.cancel()
    await consumer.value
    await fulfillment(of: [stopped], timeout: 5)
  }
}

private final class RecordingResidueFileManager: FileManager, @unchecked Sendable {
  var directories: [URL] = []

  override func contentsOfDirectory(
    at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
    options mask: FileManager.DirectoryEnumerationOptions = []
  ) throws -> [URL] {
    directories.append(url)
    return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
  }

}

private struct ResidueScanFixture {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("UpkeepScan-\(UUID().uuidString)")
  var application: AppRecord {
    AppRecord(name: "Example", bundleIdentifier: "com.example.app",
      applicationURL: root.appendingPathComponent("Example.app"), currentVersion: "1")
  }
  var scanner: ApplicationResidueScanner {
    ApplicationResidueScanner(
      fileManager: .default, homeDirectory: root, libraryDirectories: [],
      receiptsDirectory: nil, darwinDirectories: [], caskroomDirectories: [],
      teamIdentifier: { _ in nil }, bundleName: { _ in nil }, updaterCacheDirName: { _ in nil }
    )
  }
  init() throws {
    try FileManager.default.createDirectory(
      at: application.applicationURL.appendingPathComponent("Contents"),
      withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "com.example.app", "CFBundleName": "Example"],
      format: .xml, options: 0)
    try plist.write(to: application.applicationURL.appendingPathComponent("Contents/Info.plist"))
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}
