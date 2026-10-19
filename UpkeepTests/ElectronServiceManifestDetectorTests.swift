import Foundation
import XCTest

@testable import Upkeep

final class ElectronServiceManifestDetectorTests: XCTestCase {
  func testFindsTheReferencedProductionOriginAndUsesStablePlatformQueries() throws {
    let app = try fixture()
    for (architecture, platform) in [
      (MacCPUArchitecture.arm64, "darwin-aarch64"), (.x64, "darwin-x86_64"),
    ] {
      let metadata = try XCTUnwrap(
        ElectronServiceManifestDetector.detect(in: app, architecture: architecture))
      let components = try XCTUnwrap(
        URLComponents(url: metadata.feedURL, resolvingAgainstBaseURL: false))
      XCTAssertEqual(components.host, "updates.example.com")
      XCTAssertEqual(components.path, "/api/v1/releases/electron/manifest")
      XCTAssertEqual(
        components.queryItems,
        [
          URLQueryItem(name: "platform", value: platform),
          URLQueryItem(name: "channel", value: "1"),
        ])
      XCTAssertEqual(metadata.homepageURL?.absoluteString, "https://updates.example.com/home")
    }
    let record = try XCTUnwrap(ApplicationScanner.makeRecord(from: app))
    XCTAssertEqual(record.updateConfiguration.channel, .website)
    XCTAssertEqual(record.updateConfiguration.mechanism, .electronBuilder)
    var cached = record
    cached.updateConfiguration = UpdateConfiguration(mechanism: .selfManaged)
    cached.status = .selfManaged
    XCTAssertEqual(
      ApplicationScanner.makeRecord(from: app, reusing: cached)?.updateConfiguration,
      record.updateConfiguration)
  }

  func testPublicConfigurationWinsAndFallbackOnlyUsesPlaceholderGenericFeeds() throws {
    let app = try fixture(
      configuration: "provider: generic\nurl: https://standard.example.com/releases")
    XCTAssertEqual(ElectronBuilderDetector.detect(in: app)?.feedURL.host, "standard.example.com")
    for configuration in [
      "provider: generic\nurl: http://localhost:8081",
      "provider: generic\nurl: http://127.0.0.1:8081",
      "provider: generic\nurl: http://[::1]:8081",
      "provider: generic\nurl: ''",
    ] {
      XCTAssertEqual(
        ElectronBuilderDetector.detect(in: try fixture(configuration: configuration))?.feedURL.host,
        "updates.example.com")
    }
    for configuration in [
      "provider: generic\nurl: http://localhost:8081\nprivate: true",
      "provider: generic\nurl: http://insecure.example.com",
      "provider: custom\nurl: http://localhost:8081",
    ] {
      XCTAssertNil(ElectronBuilderDetector.detect(in: try fixture(configuration: configuration)))
    }
  }

  func testRequiresProviderEvidenceAndAMatchingPublicHomepage() throws {
    for code in [
      script.replacingOccurrences(of: "ManifestUpdateProvider", with: "UnrelatedProvider"),
      script.replacingOccurrences(of: "buildElectronManifestUrl", with: "unrelatedUrlBuilder"),
      script.replacingOccurrences(of: "provider:\"custom\"", with: "provider:\"generic\""),
      script.replacingOccurrences(of: "mapElectronReleaseArch", with: "unrelatedArchMapper"),
      script.replacingOccurrences(
        of: "searchParams.set(\"channel\",", with: "searchParams.set(\"test\","),
    ] {
      XCTAssertNil(ElectronBuilderDetector.detect(in: try fixture(code: code)))
    }
    XCTAssertNil(ElectronBuilderDetector.detect(in: try fixture(hasUpdaterDependency: false)))
    for origin in [
      "http://updates.example.com", "https://test.example.com", "https://localhost",
      "https://user:password@updates.example.com", "https://updates.example.com/?token=secret",
    ] {
      XCTAssertNil(ElectronBuilderDetector.detect(in: try fixture(shared: shared(origin: origin))))
    }
  }

  func testRejectsComputedAmbiguousMissingAndUnreferencedOrigins() throws {
    for shared in [
      "var production = getOrigin(); export {production as releaseRoot};",
      "var production = `https://updates.example.com`; export {production as releaseRoot};",
      Self.shared + "export {production as releaseRoot};",
      Self.shared.replacingOccurrences(of: "releaseRoot", with: "otherExport"),
      "var production = 'https://updates.example.com'; var production = 'https://test.example.com'; export {production as releaseRoot};",
    ] {
      XCTAssertNil(ElectronBuilderDetector.detect(in: try fixture(shared: shared)))
    }
    let noImport = script.replacingOccurrences(
      of: "import{releaseRoot as endpoint}from\"./chunk-runtime.js\";", with: "")
    XCTAssertNil(ElectronBuilderDetector.detect(in: try fixture(code: noImport)))
    let duplicate = script + "import{releaseRoot as endpoint}from\"./chunk-runtime.js\";"
    XCTAssertNil(ElectronBuilderDetector.detect(in: try fixture(code: duplicate)))
  }

  func testLiteralModuleReadsStayInsideTheArchiveAndRespectLimits() throws {
    let app = try fixture()
    let archive = try XCTUnwrap(ElectronApplicationArchive(bundleURL: app))
    let package: [String: Any] = ["main": "./out/main/index.js"]
    XCTAssertEqual(
      archive.mainStringLiteral(named: "endpoint", in: package), "https://updates.example.com")
    XCTAssertNil(archive.mainStringLiteral(named: "endpoint()", in: package))
    let traversal = script.replacingOccurrences(
      of: "./chunk-runtime.js", with: "../chunk-runtime.js")
    XCTAssertNil(ElectronBuilderDetector.detect(in: try fixture(code: traversal)))
    XCTAssertNil(
      ElectronBuilderDetector.detect(
        in: try fixture(shared: String(repeating: " ", count: 8 * 1024 * 1024 + 1))))
    let cyclic =
      "import{releaseRoot as production}from\"./chunk-runtime.js\";export{production as releaseRoot};"
    XCTAssertNil(ElectronBuilderDetector.detect(in: try fixture(shared: cyclic)))
    let deepModules = Dictionary(
      uniqueKeysWithValues: (0..<6).map { index in
        (
          "chunk-\(index).js",
          "import{releaseRoot as production}from\"./chunk-\(index + 1).js\";export{production as releaseRoot};"
        )
      })
    XCTAssertNil(
      ElectronBuilderDetector.detect(
        in: try fixture(
          code: script.replacingOccurrences(of: "chunk-runtime.js", with: "chunk-0.js"),
          additionalModules: deepModules)))
  }

  func testManifestReusesPackageChecksumDateAndDecodedMarkdownParsing() throws {
    let metadata = try XCTUnwrap(ElectronBuilderDetector.detect(in: fixture()))
    let notes = "## 更新说明\n\n- 支持 **Markdown** 与 \"引号\"\n- 保留反斜杠 \\ 和中文"
    let escaped = String(
      decoding: try JSONSerialization.data(withJSONObject: notes, options: .fragmentsAllowed),
      as: UTF8.self)
    let manifest = try XCTUnwrap(
      ElectronBuilderYAML.parseManifest(
        """
        version: 3.15.3
        files:
            - url: https://cdn.example.com/3.15.3/Example-mac-arm64.zip
              sha512: expected-sha512
              size: 249654319
            - url: https://cdn.example.com/3.15.3/Example-mac-arm64.dmg
              sha512: dmg-checksum
              size: 261254133
        releaseNotes: \(escaped)
        releaseNotesByLocale:
            en-US:
                title: English notes
                markdown: localized notes
        releaseDate: "2026-10-13T08:48:00.440Z"
        """))
    XCTAssertEqual(manifest.version, "3.15.3")
    XCTAssertEqual(manifest.releaseNotes, notes)
    XCTAssertEqual(manifest.releaseDate, ISO8601Parsing.date(from: "2026-10-13T08:48:00.440Z"))
    let package = try XCTUnwrap(
      manifest.selectedPackage(relativeTo: metadata.feedURL, architecture: .arm64))
    XCTAssertEqual(
      package.url.absoluteString, "https://cdn.example.com/3.15.3/Example-mac-arm64.zip")
    XCTAssertEqual(package.sha512, "expected-sha512")
    XCTAssertEqual(package.size, 249_654_319)
    XCTAssertEqual(
      String(try XCTUnwrap(ReleaseNotesMarkdown.parse(notes).first).text.characters), "更新说明")
  }

  private var script: String {
    """
    import{releaseRoot as endpoint}from"./chunk-runtime.js";
    var manifestPath="/api/v1/releases/electron/manifest";
    function channel(c){return c==="preview"?"3":"1"}n(channel,"mapReleaseChannelToApiValue");
    function arch(a){switch(a){case"arm64":return"aarch64";case"x64":return"x86_64";default:return a}}n(arch,"mapElectronReleaseArch");
    function build(c){let u=c.manifestUrl?new URL(c.manifestUrl):new URL(manifestPath,c.endpointOrigin);u.searchParams.set("platform",c.platform);u.searchParams.set("channel",channel(c.channel));return u}n(build,"buildElectronManifestUrl");
    var Provider=class{static{n(this,"ManifestUpdateProvider")}};
    updater.setFeedURL({provider:"custom",updateProvider:Provider,endpointOrigin:endpoint,releasePlatform:platform()});
    """
  }

  private static let shared = """
    var testOrigin="https://test.example.com",production="https://updates.example.com";
    export{testOrigin as testRoot,production as releaseRoot};
    """

  private func shared(origin: String) -> String {
    Self.shared.replacingOccurrences(of: "https://updates.example.com", with: origin)
  }

  private func fixture(
    configuration: String = "provider: generic\nurl: http://localhost:8081",
    code: String? = nil, shared: String = ElectronServiceManifestDetectorTests.shared,
    hasUpdaterDependency: Bool = true,
    additionalModules: [String: String] = [:]
  ) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Example.app")
    let resources = app.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": "dev.example.desktop", "CFBundleName": "Example",
        "CFBundleShortVersionString": "3.15.1", "CFBundleVersion": "3.15.1.8093",
        "CFBundlePackageType": "APPL",
      ], format: .xml, options: 0
    ).write(to: app.appendingPathComponent("Contents/Info.plist"))
    try Data(configuration.utf8).write(to: resources.appendingPathComponent("app-update.yml"))
    var files = [
      "package.json": try JSONSerialization.data(withJSONObject: [
        "main": "./out/main/index.js", "homepage": "https://updates.example.com/home",
        "dependencies": hasUpdaterDependency ? ["electron-updater": "^6.8.3"] : [:],
      ]),
      "out/main/index.js": Data((code ?? script).utf8),
      "out/main/chunk-runtime.js": Data(shared.utf8),
    ]
    for (name, value) in additionalModules { files["out/main/" + name] = Data(value.utf8) }
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
