import XCTest

@testable import Upkeep

final class VersionComparatorTests: XCTestCase {
  func testNumericVersionComparison() {
    XCTAssertTrue(VersionComparator.isNewer("2.10", than: "2.9"))
    XCTAssertFalse(VersionComparator.isNewer("2.9", than: "2.10"))
    XCTAssertFalse(VersionComparator.isNewer("3.1.0", than: "3.1.0"))
  }

  func testStableSuffixDoesNotCreateFalseUpdate() {
    XCTAssertFalse(
      VersionComparator.isNewer("2.19.0.2258 release", than: "2.19.0.2258")
    )
  }

  func testReleaseIsNewerThanPrereleaseWithSameComponents() {
    XCTAssertTrue(VersionComparator.isNewer("4.0", than: "4.0 beta"))
    XCTAssertTrue(VersionComparator.isNewer("4.0 rc1", than: "4.0 beta 2"))
  }

  func testDetectsPrereleaseVersions() {
    XCTAssertTrue(VersionComparator.isPrerelease("4.2.2-beta.2"))
    XCTAssertTrue(VersionComparator.isPrerelease("1.0 alpha"))
    XCTAssertTrue(VersionComparator.isPrerelease("2.0-rc.1"))
    XCTAssertFalse(VersionComparator.isPrerelease("4.2.1"))
    XCTAssertFalse(VersionComparator.isPrerelease("2.19.0.2258 release"))
  }

  func testHomebrewCaskVersionMatchingInstalledBuildIsNotNewer() {
    XCTAssertFalse(
      VersionComparator.isNewer("5.80.7.66659", than: "5.80.7", build: "66659")
    )
    XCTAssertTrue(VersionComparator.isNewer("5.80.7.66659", than: "5.80.7"))
    XCTAssertTrue(
      VersionComparator.isNewer("5.80.8.66660", than: "5.80.7", build: "66659")
    )
  }

  func testCaskVersionEqualToBundleVersionIsNotNewerThanShortVersion() {
    XCTAssertFalse(
      VersionComparator.isNewer("1.38.1", than: "1.38", build: "1.38.1")
    )
    XCTAssertTrue(
      VersionComparator.isNewer("1.38.2", than: "1.38", build: "1.38.1")
    )
  }
}
