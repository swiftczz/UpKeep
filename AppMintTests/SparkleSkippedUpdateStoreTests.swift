import Foundation
import XCTest

@testable import AppMint

final class SparkleSkippedUpdateStoreTests: XCTestCase {
  func testClearsSkippedVersionsAndRestoresThemWithoutTouchingOtherKeys() throws {
    let domain = "app.appmint.tests.sparkle-skip.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }

    defaults.set("1013", forKey: "SUSkippedVersion")
    defaults.set("3.0", forKey: "SUSkippedMajorVersion")
    defaults.set("keep-me", forKey: "UnrelatedKey")

    let store = SparkleSkippedUpdateStore(domain: domain)
    let snapshot = store.snapshot()
    store.clear()

    XCTAssertNil(defaults.object(forKey: "SUSkippedVersion"))
    XCTAssertNil(defaults.object(forKey: "SUSkippedMajorVersion"))
    XCTAssertEqual(defaults.string(forKey: "UnrelatedKey"), "keep-me")

    store.restore(snapshot)

    XCTAssertEqual(defaults.string(forKey: "SUSkippedVersion"), "1013")
    XCTAssertEqual(defaults.string(forKey: "SUSkippedMajorVersion"), "3.0")
    XCTAssertEqual(defaults.string(forKey: "UnrelatedKey"), "keep-me")
  }

  func testRestoreLeavesSkipClearedWhenSnapshotIsEmpty() throws {
    let domain = "app.appmint.tests.sparkle-skip.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }

    defaults.set("1013", forKey: "SUSkippedVersion")

    let store = SparkleSkippedUpdateStore(domain: domain)
    store.restore([:])

    XCTAssertNil(defaults.object(forKey: "SUSkippedVersion"))
  }
}
