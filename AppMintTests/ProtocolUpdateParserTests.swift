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

  func testIgnoresLocalhostTauriJSONURL() {
    XCTAssertTrue(
      TauriUpdaterDetector.updaterJSONURLs(in: "https://localhost:3000/latest.json").isEmpty
    )
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
}
