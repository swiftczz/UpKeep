import CryptoKit
import Foundation
import XCTest

@testable import AppMint

final class ProtocolUpdateParserTests: XCTestCase {
  func testParsesElectronBuilderLatestMacManifestAndPrefersNativeZip() throws {
    let text = """
      version: 26.8.0
      files:
        - url: ChatWise-26.8.0-x64.zip
          sha512: x64zip
          size: 10
        - url: ChatWise-26.8.0-arm64.zip
          sha512: armzip
          size: 11
        - url: ChatWise-26.8.0-arm64.dmg
          sha512: armdmg
          size: 12
      path: ChatWise-26.8.0-x64.zip
      sha512: x64zip
      releaseNotes: |
        - add gemini 3.7 flash, grok 4.6
      releaseDate: '2026-08-13T23:34:09.226Z'
      """

    let manifest = try XCTUnwrap(ElectronBuilderYAML.parseManifest(text))
    XCTAssertEqual(manifest.version, "26.8.0")
    XCTAssertEqual(manifest.releaseNotes, "- add gemini 3.7 flash, grok 4.6")
    XCTAssertEqual(manifest.files.count, 3)

    let package = try XCTUnwrap(
      manifest.selectedPackage(
        relativeTo: URL(string: "https://releases.chatwise.app/latest-mac.yml")!,
        architecture: .arm64
      )
    )
    XCTAssertEqual(
      package.url.absoluteString,
      "https://releases.chatwise.app/ChatWise-26.8.0-arm64.zip"
    )
    XCTAssertEqual(package.sha512, "armzip")
  }

  func testRejectsCustomAndInsecureElectronBuilderConfigurations() {
    XCTAssertNil(
      ElectronBuilderDetector.metadata(
        from: """
          provider: custom
          url: https://example.com
          """
      )
    )
    XCTAssertNil(
      ElectronBuilderDetector.metadata(
        from: """
          provider: generic
          url: http://localhost:8080
          """
      )
    )
    XCTAssertNil(
      ElectronBuilderDetector.metadata(
        from: """
          provider: github
          owner: example
          repo: app
          private: true
          """
      )
    )
  }

  func testParsesTauriLatestJSONAndPrefersAppleSilicon() throws {
    let data = Data(
      """
      {
        "version": "v0.2.24",
        "notes": "Grok App v0.2.24",
        "pub_date": "2026-08-21T04:09:05Z",
        "platforms": {
          "darwin-aarch64": {
            "signature": "sig",
            "url": "https://example.com/Grok_0.2.24_aarch64.app.tar.gz"
          },
          "darwin-x86_64": {
            "url": "https://example.com/Grok_0.2.24_x64.app.tar.gz"
          },
          "windows-x86_64": {
            "url": "https://example.com/setup.exe"
          }
        }
      }
      """.utf8
    )

    let manifest = try XCTUnwrap(TauriUpdateManifest.parse(data))
    XCTAssertEqual(manifest.version, "0.2.24")
    XCTAssertEqual(manifest.notes, "Grok App v0.2.24")
    XCTAssertEqual(
      manifest.selectedPlatform(architecture: .arm64)?.url.lastPathComponent,
      "Grok_0.2.24_aarch64.app.tar.gz"
    )
  }

  func testParsesGoStyleLatestJSONAndPrefersDarwinArm64() throws {
    let data = Data(
      """
      {
        "version": "v1.31.1",
        "notes": "",
        "pub_date": "",
        "release_notes_url": "https://reasonix.io/changelog/v1.31.1/",
        "platforms": {
          "darwin-amd64": {
            "url": "https://dl.reasonix.io/desktop-v1.31.1/Reasonix-darwin-amd64.zip",
            "sha256": "aaa"
          },
          "darwin-arm64": {
            "url": "https://dl.reasonix.io/desktop-v1.31.1/Reasonix-darwin-arm64.zip",
            "sha256": "bbb"
          }
        }
      }
      """.utf8
    )

    let manifest = try XCTUnwrap(TauriUpdateManifest.parse(data))
    XCTAssertEqual(manifest.version, "1.31.1")
    XCTAssertNil(manifest.notes)
    XCTAssertEqual(
      manifest.releaseNotesURL?.absoluteString,
      "https://reasonix.io/changelog/v1.31.1/"
    )
    let platform = try XCTUnwrap(manifest.selectedPlatform(architecture: .arm64))
    XCTAssertEqual(platform.url.lastPathComponent, "Reasonix-darwin-arm64.zip")
    XCTAssertEqual(platform.sha256, "bbb")
  }

  func testFindsUpdaterJSONURLAfterFirstMegabyte() throws {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AppMint-updater-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: fileURL) }

    var data = Data(count: 1_200_000)
    data.append(contentsOf: "https://dl.reasonix.io/latest/latest.json".utf8)
    try data.write(to: fileURL)

    XCTAssertEqual(
      TauriUpdaterDetector.updaterJSONURL(inFile: fileURL)?.absoluteString,
      "https://dl.reasonix.io/latest/latest.json"
    )
  }

  func testIgnoresTemplateLatestJSONURLInExecutable() throws {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AppMint-updater-template-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: fileURL) }

    try Data("https://example.com/%s/%s/latest.json".utf8).write(to: fileURL)
    XCTAssertNil(TauriUpdaterDetector.updaterJSONURL(inFile: fileURL))
  }

  func testExtractsTauriJSONURLFromConcatenatedBinaryText() {
    let urls = TauriUpdaterDetector.updaterJSONURLs(
      in: "icon.icohttps://github.com/RongleCat/grok-app/releases/download/grok-desktop-latest/latest.jsontrailing"
    )
    XCTAssertEqual(
      urls.map(\.absoluteString),
      ["https://github.com/RongleCat/grok-app/releases/download/grok-desktop-latest/latest.json"]
    )
  }

  func testIgnoresGPUIExecutableWithLatestJSON() throws {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AppMint-gpui-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: fileURL) }

    try Data(
      """
      gpui::app https://assets.example.com/github/release/desktop/latest.json crates/auto_update
      """.utf8
    ).write(to: fileURL)

    XCTAssertNil(TauriUpdaterDetector.updaterJSONURL(inFile: fileURL))
  }

  func testStillDetectsTauriWhenGPUIStringsAreAlsoPresent() throws {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AppMint-tauri-gpui-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: fileURL) }

    try Data(
      """
      gpui::app tauri_plugin_updater https://example.com/updates/latest.json
      """.utf8
    ).write(to: fileURL)

    XCTAssertEqual(
      TauriUpdaterDetector.updaterJSONURL(inFile: fileURL)?.absoluteString,
      "https://example.com/updates/latest.json"
    )
  }

  func testIgnoresLatestJSONURLSplitByBinaryBytes() throws {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AppMint-binary-url-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: fileURL) }

    var data = Data("https://assets.lbkrs.com/github/release/longbridge-desktop/".utf8)
    data.append(contentsOf: [0xC0, 0x0C])
    data.append(contentsOf: "/latest.json".utf8)
    try data.write(to: fileURL)

    XCTAssertNil(TauriUpdaterDetector.updaterJSONURL(inFile: fileURL))
  }

  func testVerifiesElectronBuilderSHA512() throws {
    let fileManager = FileManager.default
    let fileURL = fileManager.temporaryDirectory.appendingPathComponent(
      "AppMint-sha512-\(UUID().uuidString)"
    )
    defer { try? fileManager.removeItem(at: fileURL) }

    let payload = Data("hello-appmint".utf8)
    try payload.write(to: fileURL)
    let digest = Data(SHA512.hash(data: payload)).base64EncodedString()

    XCTAssertNoThrow(try ApplicationPackageInstaller.verifySHA512(of: fileURL, expected: digest))
    XCTAssertThrowsError(
      try ApplicationPackageInstaller.verifySHA512(of: fileURL, expected: "not-a-hash")
    )
  }

  func testVerifiesHexSHA256() throws {
    let fileManager = FileManager.default
    let fileURL = fileManager.temporaryDirectory.appendingPathComponent(
      "AppMint-sha256-\(UUID().uuidString)"
    )
    defer { try? fileManager.removeItem(at: fileURL) }

    let payload = Data("hello-appmint".utf8)
    try payload.write(to: fileURL)
    let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

    XCTAssertNoThrow(try ApplicationPackageInstaller.verifySHA256(of: fileURL, expected: digest))
    XCTAssertThrowsError(
      try ApplicationPackageInstaller.verifySHA256(of: fileURL, expected: "abcd")
    )
  }

  func testParsesVSCodeUpdatePayloadAndIgnoresCommitNotes() throws {
    let data = Data(
      """
      {
        "url": "https://vscode.download.prss.microsoft.com/stable/abc/VSCode-darwin-arm64.zip",
        "name": "1.134.0",
        "version": "110a328ea54b42367b803ec53ee0bf52ef26b419",
        "productVersion": "1.134.0",
        "timestamp": 1787078154886,
        "sha256hash": "6df181646588f0132339d19f5bdfb20bd0d6db05e5801061f12e0dc93c85fa70",
        "notes": "110a328ea54b42367b803ec53ee0bf52ef26b419"
      }
      """.utf8
    )

    let payload = try XCTUnwrap(VSCodeUpdatePayload.parse(data))
    XCTAssertEqual(payload.productVersion, "1.134.0")
    XCTAssertEqual(payload.commit, "110a328ea54b42367b803ec53ee0bf52ef26b419")
    XCTAssertEqual(
      payload.packageURL?.lastPathComponent,
      "VSCode-darwin-arm64.zip"
    )
    XCTAssertEqual(
      payload.sha256,
      "6df181646588f0132339d19f5bdfb20bd0d6db05e5801061f12e0dc93c85fa70"
    )
    XCTAssertNil(payload.notes)
    XCTAssertEqual(payload.timestamp, Date(timeIntervalSince1970: 1_787_078_154.886))
    XCTAssertTrue(payload.shouldOfferUpdate(against: "1.133.0"))
    XCTAssertTrue(payload.shouldOfferUpdate(against: "1.134.0"))
    XCTAssertFalse(payload.shouldOfferUpdate(against: "1.135.0"))
  }

  func testReconstructsStableReleaseJSONURLSplitByBinaryBytes() throws {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AppMint-release-json-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: fileURL) }

    var data = Data("https://assets.lbkrs.com/github/release/longbridge-desktop/".utf8)
    data.append(contentsOf: [0xC0, 0x0C])
    data.append(contentsOf: "/latest.json".utf8)
    try data.write(to: fileURL)

    XCTAssertEqual(
      ReleaseJSONDetector.endpoint(inFile: fileURL)?.absoluteString,
      "https://assets.lbkrs.com/github/release/longbridge-desktop/stable/latest.json"
    )
  }

  func testInsertsStableChannelWhenLatestJSONIsMissing() throws {
    let url = try XCTUnwrap(
      URL(string: "https://assets.lbkrs.com/github/release/longbridge-desktop/latest.json")
    )
    XCTAssertEqual(
      ReleaseJSONDetector.stableChannelURL(from: url)?.absoluteString,
      "https://assets.lbkrs.com/github/release/longbridge-desktop/stable/latest.json"
    )
    XCTAssertNil(
      ReleaseJSONDetector.stableChannelURL(
        from: try XCTUnwrap(
          URL(
            string:
              "https://assets.lbkrs.com/github/release/longbridge-desktop/stable/latest.json"
          )
        )
      )
    )
  }

  func testIgnoresPrereleaseReleaseJSONChannel() throws {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AppMint-release-json-beta-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: fileURL) }

    try Data("https://example.com/updates/beta/latest.json".utf8).write(to: fileURL)
    XCTAssertNil(ReleaseJSONDetector.endpoint(inFile: fileURL))
  }

  func testParsesReleaseJSONAssetsAndPrefersAppleSiliconDMG() throws {
    let data = Data(
      """
      {
        "version": "v0.19.1",
        "published_at": "2026-08-20T07:46:53Z",
        "release_notes": {
          "en": "### Improvements",
          "zh-CN": "### 优化"
        },
        "assets": [
          {
            "name": "app-v0.19.1-linux-x86_64.tar.gz",
            "url": "https://example.com/app-v0.19.1-linux-x86_64.tar.gz",
            "sha256": "aa"
          },
          {
            "name": "app-v0.19.1-windows-x86_64.exe",
            "url": "https://example.com/app-v0.19.1-windows-x86_64.exe",
            "sha256": "bb"
          },
          {
            "name": "app-v0.19.1-macos-x86_64.dmg",
            "url": "https://example.com/app-v0.19.1-macos-x86_64.dmg",
            "sha256": "cc"
          },
          {
            "name": "app-v0.19.1-macos-aarch64.dmg",
            "url": "https://example.com/app-v0.19.1-macos-aarch64.dmg",
            "sha256": "dd"
          }
        ]
      }
      """.utf8
    )

    let manifest = try XCTUnwrap(ReleaseJSONManifest.parse(data, languageCode: "zh-Hans"))
    XCTAssertEqual(manifest.version, "0.19.1")
    XCTAssertEqual(manifest.notes, "### 优化")
    XCTAssertEqual(manifest.publicationDate, ISO8601Parsing.date(from: "2026-08-20T07:46:53Z"))

    let armPackage = try XCTUnwrap(manifest.selectedPackage(architecture: .arm64))
    XCTAssertEqual(armPackage.url.lastPathComponent, "app-v0.19.1-macos-aarch64.dmg")
    XCTAssertEqual(armPackage.sha256, "dd")

    let intelPackage = try XCTUnwrap(manifest.selectedPackage(architecture: .x64))
    XCTAssertEqual(intelPackage.url.lastPathComponent, "app-v0.19.1-macos-x86_64.dmg")

    XCTAssertNil(ReleaseJSONManifest.parse(Data(#"{"version":"1.0","platforms":{}}"#.utf8)))
  }

  func testBuildsVSCodeUpdaterCheckURL() throws {
    let updateURL = try XCTUnwrap(URL(string: "https://update.code.visualstudio.com/"))
    XCTAssertEqual(
      VSCodeUpdaterDetector.checkURL(
        updateURL: updateURL,
        platform: "darwin-arm64",
        quality: "stable",
        commit: "abc123"
      )?.absoluteString,
      "https://update.code.visualstudio.com/api/update/darwin-arm64/stable/abc123"
    )
    XCTAssertEqual(
      VSCodeUpdaterDetector.parseSourceIdentifier("stable/abc123")?.commit,
      "abc123"
    )
  }
}
