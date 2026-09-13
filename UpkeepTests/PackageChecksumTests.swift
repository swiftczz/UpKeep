import Foundation
import XCTest

@testable import Upkeep

final class PackageChecksumTests: XCTestCase {
  // SHA-512 of the fixed input "abc", independently checked with hashlib.
  private let hex =
    "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
    + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
  private let base64 =
    "3a81oZNherrMQXNJriBBMRLm+k6JqX6iCp7u5ktV05ohkpkqJ0/BqDa6PCOj/uu9RU1EI2Q86A4qmslPpUyknw=="

  func testAcceptsLowercaseAndUppercaseHexSHA512() throws {
    try withPackage { url in
      for expected in [hex, hex.uppercased()] {
        XCTAssertNoThrow(try ApplicationPackageInstaller.verifySHA512(of: url, expected: expected))
      }
    }
  }

  func testPreservesBase64SHA512Support() throws {
    try withPackage { url in
      XCTAssertNoThrow(try ApplicationPackageInstaller.verifySHA512(of: url, expected: base64))
    }
  }

  func testAcceptsWhitespaceInBothEncodings() throws {
    try withPackage { url in
      for expected in [hex, base64] {
        let wrapped = " \n" + expected.prefix(32) + "\n" + expected.dropFirst(32) + "\t"
        XCTAssertNoThrow(try ApplicationPackageInstaller.verifySHA512(of: url, expected: wrapped))
      }
    }
  }

  func testRejectsInvalidCharactersAndWrongDigestLengths() throws {
    try withPackage { url in
      for expected in [
        "", "not-a-hash", String(hex.dropLast()), hex + "00",
        "g" + hex.dropFirst(), String(repeating: "Ａ", count: 128),
        String(base64.dropLast()), "!" + base64, base64 + "!",
        Data(repeating: 0, count: 63).base64EncodedString(),
        Data(repeating: 0, count: 65).base64EncodedString(),
      ] {
        XCTAssertThrowsError(
          try ApplicationPackageInstaller.verifySHA512(of: url, expected: expected)
        ) {
          guard case ApplicationPackageInstallerError.checksumMismatch = $0 else {
            return XCTFail("Expected checksum mismatch, got \($0)")
          }
        }
      }
    }
  }

  func testModifiedPackageStillFailsBothEncodings() throws {
    try withPackage { url in
      try Data("abd".utf8).write(to: url)
      for expected in [hex, base64] {
        XCTAssertThrowsError(
          try ApplicationPackageInstaller.verifySHA512(of: url, expected: expected))
      }
    }
  }

  func testLegacyManifestWithHexSHA512CanVerifyItsSelectedPackage() throws {
    let manifest = try XCTUnwrap(
      ElectronBuilderYAML.parseManifest(
        """
        version: 3.4.1
        path: ../../3.4.1/darwin/TradingView.zip
        sha512: \(hex)
        """))
    let feed = try XCTUnwrap(URL(string: "https://example.com/stable/latest/darwin/stable-mac.yml"))
    let package = try XCTUnwrap(manifest.selectedPackage(relativeTo: feed))
    let expected = try XCTUnwrap(package.sha512)
    try withPackage { url in
      XCTAssertNoThrow(try ApplicationPackageInstaller.verifySHA512(of: url, expected: expected))
    }
  }

  private func withPackage(_ body: (URL) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("Upkeep-checksum-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("abc".utf8).write(to: url)
    try body(url)
  }
}
