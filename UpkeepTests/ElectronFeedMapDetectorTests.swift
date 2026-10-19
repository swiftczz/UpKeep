import Foundation
import XCTest

@testable import Upkeep

final class ElectronFeedMapDetectorTests: XCTestCase {
  func testReadsMatchingBrandAndOnlyProductionChannel() throws {
    let app = try fixture()
    let metadata = try XCTUnwrap(ElectronBuilderDetector.detect(in: app))
    XCTAssertEqual(
      metadata.feedURL.absoluteString, "https://downloads.example.com/desktop/prod/latest-mac.yml")
    XCTAssertEqual(metadata.homepageURL?.absoluteString, "https://example.com/home")
    let record = try XCTUnwrap(ApplicationScanner.makeRecord(from: app))
    XCTAssertEqual(record.updateConfiguration.channel, .website)
    XCTAssertEqual(record.updateConfiguration.mechanism, .electronBuilder)
    XCTAssertEqual(record.status, .checking)
    var cached = record
    cached.updateConfiguration = UpdateConfiguration(mechanism: .selfManaged)
    cached.status = .selfManaged
    XCTAssertEqual(
      ApplicationScanner.makeRecord(from: app, reusing: cached)?.updateConfiguration,
      record.updateConfiguration)
  }

  func testStandardConfigurationWinsAndPrivateOrOtherProvidersDoNotFallBack() throws {
    let app = try fixture(
      configuration: "provider: generic\nurl: https://standard.example.com/updates")
    XCTAssertEqual(ElectronBuilderDetector.detect(in: app)?.feedURL.host, "standard.example.com")
    for configuration in [
      "provider: generic\nurl: ''\nprivate: true",
      "provider: custom\nurl: ''",
      "provider: generic\nurl: http://insecure.example.com",
    ] {
      XCTAssertNil(ElectronBuilderDetector.detect(in: try fixture(configuration: configuration)))
    }
  }

  func testRequiresMatchingIdentityUnambiguousMappingAndUpdaterEvidence() throws {
    for code in [
      try script(tenantID: "com.example.some-other-app"),
      try script() + ",8:function(A){var map={\"./brand/feedmap.json\":\"2\"}}",
      try script() + ",9:function(A){var map={\"./brand/tenant.json\":\"1\"}}",
      try script().replacingOccurrences(of: "autoUpdater.setFeedURL", with: "unrelated.setFeedURL"),
      try script().replacingOccurrences(of: "config.feeds.prod", with: "config.feeds.beta"),
      try script().replacingOccurrences(of: "A.exports=JSON.parse", with: "A.exports=execute"),
    ] {
      XCTAssertNil(ElectronBuilderDetector.detect(in: try fixture(code: code)))
    }
  }

  func testRejectsInsecureCredentialedOrNonProductionFeeds() throws {
    for url in [
      "http://downloads.example.com/", "https://user:password@downloads.example.com/",
      "https://downloads.example.com/?token=private", "https://downloads.example.com/#beta",
    ] {
      XCTAssertNil(ElectronBuilderDetector.detect(in: try fixture(code: script(url: url))))
    }
    XCTAssertNil(ElectronBuilderDetector.detect(in: try fixture(code: script(channel: "beta"))))
    XCTAssertNil(ElectronBuilderDetector.detect(in: try fixture(code: script(includeProd: false))))
  }

  func testReadsLargeMainAndEscapedLiteralWithoutExecutingJavaScript() throws {
    // Real bundled mains can exceed 8 MiB; the selected-file read remains bounded at 16 MiB.
    let code =
      String(repeating: " ", count: 9 * 1024 * 1024) + (try script(product: "Example's 应用"))
    XCTAssertNotNil(ElectronBuilderDetector.detect(in: try fixture(code: code)))
  }

  func testProductionManifestUsesExistingArchitectureAndChecksumSelection() throws {
    let manifest = try XCTUnwrap(
      ElectronBuilderYAML.parseManifest(
        """
        version: 1.1.0
        files:
          - url: example-1.1.0-mac-x64.zip
            sha512: intel-checksum
            size: 20
          - url: example-1.1.0-mac-arm64.zip
            sha512: arm-checksum
            size: 19
        releaseDate: '2026-08-21T06:27:54.188Z'
        """))
    let feed = try XCTUnwrap(ElectronBuilderDetector.detect(in: fixture())?.feedURL)
    let package = try XCTUnwrap(manifest.selectedPackage(relativeTo: feed, architecture: .arm64))
    XCTAssertEqual(
      package.url.absoluteString,
      "https://downloads.example.com/desktop/prod/example-1.1.0-mac-arm64.zip")
    XCTAssertEqual(package.sha512, "arm-checksum")
    XCTAssertEqual(
      manifest.selectedPackage(relativeTo: feed, architecture: .x64)?.sha512, "intel-checksum")
  }

  private func script(
    tenantID: String = "com.example.brand",
    url: String = "https://downloads.example.com/desktop/prod/",
    channel: String = "latest", includeProd: Bool = true, product: String = "Example"
  ) throws -> String {
    func literal(_ object: [String: Any]) throws -> String {
      let data = try JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
      return "'"
        + String(decoding: data, as: UTF8.self)
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "'", with: "\\'") + "'"
    }
    let tenant = try literal(["bundleID": tenantID, "productName": product])
    var feeds: [String: Any] = [
      "beta": ["url": "https://wrong.example.com/beta/", "channel": "beta"]
    ]
    if includeProd { feeds["prod"] = ["url": url, "channel": channel] }
    let feed = try literal(feeds)
    let otherTenant = try literal(["bundleID": "com.example.other", "productName": "Other"])
    return """
      ({1:function(A){"use strict";A.exports=JSON.parse(\(tenant))},
      2:function(A){"use strict";A.exports=JSON.parse(\(feed))},
      3:function(A){"use strict";A.exports=JSON.parse(\(otherTenant))},
      4:function(A){var map={"./brand/tenant.json":"1","./other/tenant.json":"3"}},
      5:function(A){var map={"./brand/feedmap.json":"2","./other/feedmap.json":"2"}},
      6:function(A){var getFeed=function(){return config.feeds.prod};
      updater.autoUpdater.setFeedURL({provider:"generic",url:e,channel:g})}})
      """
  }

  private func fixture(
    configuration: String = "provider: generic\nurl: ''", code: String? = nil
  ) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Example.app")
    let resources = app.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": "com.example.brand", "CFBundleName": "Example",
        "CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "1.1.0.123",
        "CFBundlePackageType": "APPL",
      ], format: .xml, options: 0
    ).write(to: app.appendingPathComponent("Contents/Info.plist"))
    try Data(configuration.utf8).write(to: resources.appendingPathComponent("app-update.yml"))
    let files = [
      "package.json": try JSONSerialization.data(withJSONObject: [
        "main": "./main.js", "homepage": "https://example.com/home",
      ]),
      "main.js": Data(try (code ?? script()).utf8),
    ]
    var entries: [String: Any] = [:]
    var payload = Data()
    for name in files.keys.sorted() {
      let data = files[name]!
      entries[name] = ["size": data.count, "offset": String(payload.count)]
      payload.append(data)
    }
    let header = try JSONSerialization.data(withJSONObject: ["files": entries])
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
