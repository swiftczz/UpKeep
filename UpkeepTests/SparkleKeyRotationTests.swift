import CryptoKit
import Foundation
import XCTest

@testable import Upkeep

final class SparkleKeyRotationTests: XCTestCase {
  func testExistingArchiveSignatureStillVerifiesBeforeExtraction() throws {
    let fixture = try fixture(requiresPreverification: true)
    let key = Curve25519.Signing.PrivateKey()
    let signature = try key.signature(for: Data(contentsOf: fixture.archive)).base64EncodedString()
    let result = try ApplicationPackageInstaller.extractAndVerifyApplication(
      from: fixture.archive, into: fixture.extracted, matching: fixture.record,
      expectedEd25519Signature: signature,
      ed25519PublicKey: key.publicKey.rawRepresentation.base64EncodedString(),
      allowsSparkleKeyRotation: true)
    XCTAssertEqual(Bundle(url: result)?.bundleIdentifier, fixture.record.bundleIdentifier)
  }

  func testRotationRequiresExplicitSparkleOptIn() throws {
    let fixture = try fixture()
    assertInvalidSignature {
      _ = try ApplicationPackageInstaller.extractAndVerifyApplication(
        from: fixture.archive, into: fixture.extracted, matching: fixture.record,
        expectedEd25519Signature: fixture.signature, ed25519PublicKey: fixture.oldPublicKey)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.extracted.path))
  }

  func testInstalledPreverificationPolicyRejectsRotationBeforeExtraction() throws {
    for option in ["SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"] {
      let fixture = try fixture(policy: option)
      assertInvalidSignature {
        _ = try ApplicationPackageInstaller.extractAndVerifyApplication(
          from: fixture.archive, into: fixture.extracted, matching: fixture.record,
          expectedEd25519Signature: fixture.signature, ed25519PublicKey: fixture.oldPublicKey,
          allowsSparkleKeyRotation: true)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.extracted.path))
    }
  }

  func testNewKeyIsAcceptedOnlyAfterTheOriginalDeveloperIdentityIsTrusted() throws {
    let fixture = try fixture()
    var identityWasChecked = false
    XCTAssertNoThrow(
      try ApplicationPackageInstaller.verifySparkleKeyRotation(
        of: fixture.archive, containing: fixture.candidate, replacing: fixture.installed,
        signature: fixture.signature, previousPublicKey: fixture.oldPublicKey,
        matchesDeveloperID: { installed, candidate in
          XCTAssertEqual(installed, fixture.installed)
          XCTAssertEqual(candidate, fixture.candidate)
          identityWasChecked = true
          return true
        }))
    XCTAssertTrue(identityWasChecked)
  }

  func testUntrustedIdentityCannotAuthorizeANewPublicKey() throws {
    let fixture = try fixture()
    assertInvalidSignature {
      try ApplicationPackageInstaller.verifySparkleKeyRotation(
        of: fixture.archive, containing: fixture.candidate, replacing: fixture.installed,
        signature: fixture.signature, previousPublicKey: fixture.oldPublicKey,
        matchesDeveloperID: { _, _ in false })
    }
    // Exercise the production trust check too; unsigned bundles must never establish trust.
    assertInvalidSignature {
      _ = try ApplicationPackageInstaller.extractAndVerifyApplication(
        from: fixture.archive, into: fixture.extracted, matching: fixture.record,
        expectedEd25519Signature: fixture.signature, ed25519PublicKey: fixture.oldPublicKey,
        allowsSparkleKeyRotation: true)
    }
  }

  func testTrustedIdentityStillRequiresAValidNewArchiveSignature() throws {
    let fixture = try fixture()
    try Data("tampered archive".utf8).write(to: fixture.archive)
    assertInvalidSignature {
      try ApplicationPackageInstaller.verifySparkleKeyRotation(
        of: fixture.archive, containing: fixture.candidate, replacing: fixture.installed,
        signature: fixture.signature, previousPublicKey: fixture.oldPublicKey,
        matchesDeveloperID: { _, _ in true })
    }
  }

  func testAnUnchangedOrMissingKeyIsNotTreatedAsRotation() throws {
    for newKey in [nil, "unchanged"] {
      let fixture = try fixture(candidateKey: newKey)
      assertInvalidSignature {
        try ApplicationPackageInstaller.verifySparkleKeyRotation(
          of: fixture.archive, containing: fixture.candidate, replacing: fixture.installed,
          signature: fixture.signature, previousPublicKey: fixture.oldPublicKey,
          matchesDeveloperID: { _, _ in true })
      }
    }
  }

  func testMissingSignatureOrInstalledKeyCannotFallBackToRotation() throws {
    let fixture = try fixture()
    for (signature, key) in [
      (fixture.signature as String?, nil as String?),
      (nil, fixture.oldPublicKey),
    ] {
      assertInvalidSignature {
        _ = try ApplicationPackageInstaller.extractAndVerifyApplication(
          from: fixture.archive, into: fixture.extracted, matching: fixture.record,
          expectedEd25519Signature: signature, ed25519PublicKey: key,
          allowsSparkleKeyRotation: true)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.extracted.path))
    }
  }

  func testAdHocCodeSignaturesCannotAuthorizeKeyRotation() throws {
    let fixture = try fixture()
    for url in [fixture.installed, fixture.candidate] {
      let executable = url.appendingPathComponent("Contents/MacOS/Fixture")
      try FileManager.default.createDirectory(
        at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
      _ = try ProcessRunner.blockingRun(
        executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
        arguments: ["--force", "--sign", "-", url.path])
      XCTAssertTrue(ApplicationCodeSigning.signatureIsValid(at: url))
    }
    XCTAssertFalse(
      ApplicationCodeSigning.matchesDeveloperID(
        of: fixture.installed, candidateURL: fixture.candidate))
  }

  private func assertInvalidSignature(
    _ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(try operation(), file: file, line: line) {
      guard case ApplicationPackageInstallerError.invalidUpdateSignature = $0 else {
        return XCTFail("Unexpected error: \($0)", file: file, line: line)
      }
    }
  }

  private func fixture(
    requiresPreverification: Bool = false,
    policy: String? = nil,
    candidateKey: String? = "rotated"
  ) throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let oldKey = Curve25519.Signing.PrivateKey()
    let newKey = Curve25519.Signing.PrivateKey()
    let oldPublicKey = oldKey.publicKey.rawRepresentation.base64EncodedString()
    let installed = root.appendingPathComponent("installed/Fixture.app")
    let candidate = root.appendingPathComponent("source/Fixture.app")
    for (url, key) in [
      (installed, oldPublicKey as String?),
      (
        candidate,
        candidateKey.map {
          $0 == "unchanged"
            ? oldPublicKey : newKey.publicKey.rawRepresentation.base64EncodedString()
        }
      ),
    ] {
      let contents = url.appendingPathComponent("Contents")
      try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
      var info: [String: Any] = [
        "CFBundleIdentifier": "com.example.rotation", "CFBundleExecutable": "Fixture",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0",
      ]
      info["SUPublicEDKey"] = key
      if url == installed {
        if requiresPreverification { info["SUVerifyUpdateBeforeExtraction"] = true }
        if let policy { info[policy] = true }
      }
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    }
    let archive = root.appendingPathComponent("Fixture.tar.xz")
    _ = try ProcessRunner.blockingRun(
      executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
      arguments: [
        "-cJf", archive.path, "-C", candidate.deletingLastPathComponent().path, "Fixture.app",
      ])
    let signature = try newKey.signature(for: Data(contentsOf: archive)).base64EncodedString()
    return Fixture(
      installed: installed, candidate: candidate, archive: archive,
      extracted: root.appendingPathComponent("extracted"), signature: signature,
      oldPublicKey: oldPublicKey)
  }

  private struct Fixture {
    let installed: URL
    let candidate: URL
    let archive: URL
    let extracted: URL
    let signature: String
    let oldPublicKey: String

    var record: AppRecord {
      AppRecord(
        name: "Fixture", bundleIdentifier: "com.example.rotation", applicationURL: installed,
        currentVersion: "1.0", updateConfiguration: UpdateConfiguration(mechanism: .sparkle))
    }
  }
}
