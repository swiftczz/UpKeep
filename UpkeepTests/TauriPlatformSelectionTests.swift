import Foundation
import XCTest

@testable import Upkeep

final class TauriPlatformSelectionTests: XCTestCase {
  func testIntelRejectsARMOnlyManifest() throws {
    for key in ["darwin-aarch64", "darwin-aarch64-app", "darwin-arm64", "aarch64-apple-darwin"] {
      let manifest = try manifest([key: "arm.app.tar.gz"])
      XCTAssertNil(manifest.selectedPlatform(architecture: .x64), key)
      XCTAssertNotNil(manifest.selectedPlatform(architecture: .arm64), key)
    }
  }

  func testUnknownDarwinArchitectureIsNotAssumedCompatible() throws {
    for key in ["darwin", "darwin-riscv64", "darwin-custom", "linux-x86_64"] {
      let manifest = try manifest([key: "update.app.tar.gz"])
      XCTAssertNil(manifest.selectedPlatform(architecture: .x64), key)
      XCTAssertNil(manifest.selectedPlatform(architecture: .arm64), key)
    }
  }

  func testEachMacPrefersItsNativePackage() throws {
    let manifest = try manifest([
      "darwin-aarch64": "arm.app.tar.gz",
      "darwin-x86_64": "intel.app.tar.gz",
      "darwin-universal": "universal.app.tar.gz",
    ])
    XCTAssertEqual(
      manifest.selectedPlatform(architecture: .x64)?.url.lastPathComponent, "intel.app.tar.gz"
    )
    XCTAssertEqual(
      manifest.selectedPlatform(architecture: .arm64)?.url.lastPathComponent, "arm.app.tar.gz"
    )
  }

  func testIntelFallsBackToUniversalWhenOnlyARMAndUniversalAreAvailable() throws {
    for key in ["darwin-universal", "universal-apple-darwin"] {
      let manifest = try manifest([
        "darwin-aarch64": "arm.app.tar.gz",
        key: "universal.app.tar.gz",
      ])
      XCTAssertEqual(
        manifest.selectedPlatform(architecture: .x64)?.url.lastPathComponent,
        "universal.app.tar.gz", key
      )
    }
  }

  func testUnusableIntelPackageDoesNotFallBackToARM() throws {
    let manifest = try manifest([
      "darwin-x86_64": "release-notes.html",
      "darwin-aarch64": "arm.app.tar.gz",
    ])
    XCTAssertNil(manifest.selectedPlatform(architecture: .x64))
  }

  func testAppleSiliconKeepsUniversalThenIntelFallback() throws {
    let universal = try manifest([
      "darwin-x86_64": "intel.app.tar.gz",
      "darwin-universal": "universal.app.tar.gz",
    ])
    XCTAssertEqual(
      universal.selectedPlatform(architecture: .arm64)?.url.lastPathComponent,
      "universal.app.tar.gz"
    )
    let intelOnly = try manifest(["darwin-x86_64-app": "intel.app.tar.gz"])
    XCTAssertEqual(
      intelOnly.selectedPlatform(architecture: .arm64)?.url.lastPathComponent,
      "intel.app.tar.gz"
    )
  }

  private func manifest(_ packages: [String: String]) throws -> TauriUpdateManifest {
    let data = try JSONSerialization.data(withJSONObject: [
      "version": "2.0.0",
      "platforms": packages.mapValues { ["url": "https://example.com/\($0)"] },
    ])
    return try XCTUnwrap(TauriUpdateManifest.parse(data))
  }
}
