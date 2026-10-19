import Foundation
import XCTest

@testable import Upkeep

final class ElectronCustomAPIUpdateTests: XCTestCase, @unchecked Sendable {
  func testReadsRegionalEndpointsFromPackedAndUnpackedProductConfigurations() throws {
    for (name, endpoint, unpacked) in [
      ("WorkBuddy", "https://domestic.example.com", false),
      ("workbuddy-ai", "https://international.example.com", true),
    ] {
      let app = try fixture(applicationName: name, endpoint: endpoint, unpackedProduct: unpacked)
      let configuration = try XCTUnwrap(
        ElectronCustomAPIUpdateDetector.detect(
          in: app, currentVersion: "5.5.2", architecture: .arm64))
      XCTAssertEqual(configuration.mechanism, .customAPI)
      XCTAssertEqual(configuration.channel, .website)
      XCTAssertEqual(
        configuration.feedURL?.absoluteString,
        endpoint + "/v2/update?platform=workbuddy-darwin-arm64&version=5.5.2")
      XCTAssertNil(configuration.targetBundleIdentifier)
      XCTAssertEqual(configuration.homepageURL?.absoluteString, endpoint + "/home")
      XCTAssertFalse(configuration.feedURL!.absoluteString.contains("user-id"))
    }
  }

  func testArchitectureAndNewFamilyNamesDoNotNeedBundleIdentifierMappings() throws {
    let app = try fixture(applicationName: "workbuddy-research")
    let configuration = try XCTUnwrap(
      ElectronCustomAPIUpdateDetector.detect(
        in: app, currentVersion: "1.0", architecture: .x64))
    XCTAssertTrue(configuration.feedURL!.absoluteString.contains("platform=workbuddy-darwin-x64"))
  }

  func testMissingUpdaterEvidenceAndInsecureEndpointsAreNotDetected() throws {
    for endpoint in [
      "http://example.com", "https://user:secret@example.com", "https://example.com?token=private",
    ] {
      let app = try fixture(endpoint: endpoint)
      XCTAssertNil(ElectronCustomAPIUpdateDetector.detect(in: app, currentVersion: "1.0"))
    }
    let app = try fixture(code: "const unrelatedExample = '/v2/update?platform=example';")
    XCTAssertNil(ElectronCustomAPIUpdateDetector.detect(in: app, currentVersion: "1.0"))
  }

  func testScannerRecoversUnknownCacheAndRetainsRegionAndMigrationMetadata() throws {
    let app = try fixture(bundleIdentifier: "com.example.legacy")
    let fresh = try XCTUnwrap(ApplicationScanner.makeRecord(from: app))
    XCTAssertEqual(fresh.updateConfiguration.mechanism, .customAPI)
    XCTAssertEqual(fresh.updateConfiguration.targetBundleIdentifier, "com.example.migrated")
    var cached = fresh
    cached.updateConfiguration = UpdateConfiguration(mechanism: .selfManaged)
    cached.status = .selfManaged
    let recovered = try XCTUnwrap(ApplicationScanner.makeRecord(from: app, reusing: cached))
    XCTAssertEqual(recovered.updateConfiguration, fresh.updateConfiguration)
    let decoded = try JSONDecoder().decode(AppRecord.self, from: JSONEncoder().encode(recovered))
    XCTAssertEqual(decoded.updateConfiguration, fresh.updateConfiguration)
  }

  func testArchiveRejectsEscapingPathsOversizedEntriesAndInvalidOffsets() throws {
    let app = try fixture()
    let archive = try XCTUnwrap(ElectronApplicationArchive(bundleURL: app))
    XCTAssertNotNil(archive.data(for: "package.json", maximumBytes: 1024))
    XCTAssertNil(archive.data(for: "package.json", maximumBytes: 2))
    XCTAssertNil(archive.data(for: "../package.json", maximumBytes: 1024))
    XCTAssertNil(archive.data(for: "/package.json", maximumBytes: 1024))
    XCTAssertNil(archive.data(for: "overflow.json", maximumBytes: 1024))
    XCTAssertNil(archive.data(for: "linked.json", maximumBytes: 1024))
    let escaped = app.appendingPathComponent(
      "Contents/Resources/app.asar.unpacked/cli/product.json")
    try FileManager.default.createDirectory(
      at: escaped.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: escaped, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
    let untrusted = try fixture(unpackedProduct: true)
    let product = untrusted.appendingPathComponent(
      "Contents/Resources/app.asar.unpacked/cli/product.json")
    try FileManager.default.removeItem(at: product)
    try FileManager.default.createSymbolicLink(at: product, withDestinationURL: escaped)
    XCTAssertNil(ElectronCustomAPIUpdateDetector.detect(in: untrusted, currentVersion: "1.0"))
  }

  func testArchiveRejectsTruncatedHeaders() throws {
    let app = try fixture()
    try Data([4, 0, 0, 0]).write(to: app.appendingPathComponent("Contents/Resources/app.asar"))
    XCTAssertNil(ElectronApplicationArchive(bundleURL: app))
  }

  func testSinglePackageFeedKeepsProductVersionChecksumAndPublicationDate() throws {
    let manifest = try XCTUnwrap(CustomAPIUpdateManifest.parse(try feed()))
    XCTAssertEqual(manifest.version, "5.8.4.41366630")
    XCTAssertEqual(
      manifest.selectedPackage(architecture: .arm64)?.sha256, String(repeating: "a", count: 64))
    XCTAssertNil(manifest.selectedPackage(architecture: .x64))
    XCTAssertEqual(manifest.publicationDate, Date(timeIntervalSince1970: 1_792_089_830))
    XCTAssertEqual(manifest.notes, "Release notes")
    XCTAssertNil(manifest.releaseURL)
  }

  func testVersionedChecksUseCurrentVersionAndHandleNoUpdateResponses() async throws {
    let app = try fixture()
    var record = try XCTUnwrap(ApplicationScanner.makeRecord(from: app))
    record.currentVersion = "5.8.4"
    let provider = CustomAPIUpdateProvider(fetchResponse: { url in
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
      XCTAssertEqual(items?.first(where: { $0.name == "version" })?.value, "5.8.4")
      XCTAssertEqual(items?.map(\.name).sorted(), ["platform", "version"])
      return (204, Data())
    })
    let checked = await provider.check(record)
    XCTAssertEqual(checked.status, .upToDate)
    XCTAssertEqual(checked.latestVersion, "5.8.4")
    XCTAssertEqual(checked.updateConfiguration.mechanism, .customAPI)
    XCTAssertFalse(checked.canAutomaticallyUpdate)
  }

  func testMigrationIsDetectedWithoutMarkingInternationalBundleForMigration() async throws {
    let data = try feed()
    let provider = CustomAPIUpdateProvider(fetchResponse: { _ in (200, data) })
    for (identifier, canInstall) in [
      ("com.example.legacy", false), ("com.example.international", true),
    ] {
      let app = try fixture(bundleIdentifier: identifier)
      let record = try XCTUnwrap(ApplicationScanner.makeRecord(from: app))
      let checked = await provider.check(record)
      XCTAssertEqual(checked.status, .updateAvailable)
      XCTAssertEqual(checked.latestVersion, "5.8.4.41366630")
      XCTAssertEqual(checked.canAutomaticallyUpdate, canInstall)
      XCTAssertEqual(checked.requiresBundleMigration, !canInstall)
    }
  }

  func testMigrationUpgradeHandsOffBeforeAnyDownload() async throws {
    let app = try fixture(bundleIdentifier: "com.example.legacy")
    let record = try XCTUnwrap(ApplicationScanner.makeRecord(from: app))
    let provider = CustomAPIUpdateProvider(fetchResponse: { _ in
      XCTFail("Migration must not download an installation package")
      return nil
    })
    do {
      try await provider.upgrade(record, progress: { _ in })
      XCTFail("Migration should use the application's updater")
    } catch { XCTAssertTrue(record.requiresBundleMigration) }
  }

  private func feed() throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "version": "aabbccdd", "productVersion": "5.8.4.41366630",
      "url": "https://downloads.example.com/App-darwin-arm64-5.8.4.zip",
      "sha256hash": String(repeating: "a", count: 64), "timestamp": 1_792_089_830,
      "releaseNotes": "Release notes",
    ])
  }

  private func fixture(
    applicationName: String = "workbuddy-ai",
    endpoint: String = "https://international.example.com",
    bundleIdentifier: String = "com.example.international", unpackedProduct: Bool = false,
    code: String? = nil
  ) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "UpkeepTests-\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Example.app")
    let resources = app.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": bundleIdentifier, "CFBundleName": "Example",
        "CFBundleShortVersionString": "5.5.2", "CFBundleVersion": "5.5.2",
        "CFBundlePackageType": "APPL", "CFBundleExecutable": "Electron",
      ], format: .xml, options: 0
    ).write(to: app.appendingPathComponent("Contents/Info.plist"))
    let product = try JSONSerialization.data(withJSONObject: [
      "applicationName": applicationName, "endpoint": endpoint,
      "links": ["officialWebsite": endpoint + "/home"],
      "updates": [
        "apiVersion": "v2", "checkVersion": ["scene": "saas"], "download": ["scene": "saas"],
      ],
    ])
    let main =
      code ?? """
        var CURRENT_DARWIN_BUNDLE_ID = "com.example.legacy";
        var TARGET_DARWIN_BUNDLE_ID = "com.example.migrated";
        function resolveUpdateClientTypePrefix() {}
        function buildUpdateFeedUrl() { return '/v2/update?platform='; }
        function getFeedVersion(feed) { return feed.productVersion; }
        """
    var files = [
      "package.json": try JSONSerialization.data(withJSONObject: [
        "main": "main/index.js", "homepage": "https://example.com",
      ]),
      "main/index.js": Data(main.utf8),
    ]
    if !unpackedProduct { files["cli/product.json"] = product }
    var tree: [String: Any] = ["files": [String: Any]()]
    func insert(_ entry: [String: Any], _ path: ArraySlice<String>, into node: inout [String: Any])
    {
      let name = path.first!
      var children = node["files"] as? [String: Any] ?? [:]
      if path.count == 1 {
        children[name] = entry
      } else {
        var child = children[name] as? [String: Any] ?? [:]
        insert(entry, path.dropFirst(), into: &child)
        children[name] = child
      }
      node["files"] = children
    }
    var payload = Data()
    for name in files.keys.sorted() {
      let data = files[name]!
      insert(
        ["size": data.count, "offset": String(payload.count)],
        name.split(separator: "/").map(String.init)[...], into: &tree)
      payload.append(data)
    }
    insert(["size": 10, "offset": "18446744073709551615"], ["overflow.json"], into: &tree)
    insert(["size": 10, "link": "../../outside"], ["linked.json"], into: &tree)
    if unpackedProduct {
      insert(["size": product.count, "unpacked": true], ["cli", "product.json"], into: &tree)
      let file = resources.appendingPathComponent("app.asar.unpacked/cli/product.json")
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try product.write(to: file)
    }
    let header = try JSONSerialization.data(withJSONObject: tree)
    let padding = (4 - header.count % 4) % 4
    let pickleSize = header.count + padding + 8
    var archive = Data()
    for value in [4, pickleSize, pickleSize - 4, header.count] {
      var word = UInt32(value).littleEndian
      withUnsafeBytes(of: &word) { archive.append(contentsOf: $0) }
    }
    archive.append(header)
    archive.append(Data(repeating: 0, count: padding))
    archive.append(payload)
    try archive.write(to: resources.appendingPathComponent("app.asar"))
    return app
  }
}
