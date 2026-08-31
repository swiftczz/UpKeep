import CoreServices
import XCTest

@testable import Upkeep

final class ApplicationChangeMonitorTests: XCTestCase {
  func testApplicationBundlePathsAreRelevant() {
    XCTAssertTrue(ApplicationChangeMonitor.affectsApplicationBundle("/Applications/Example.app"))
    XCTAssertTrue(
      ApplicationChangeMonitor.affectsApplicationBundle(
        "/Applications/Example.app/Contents/Info.plist"
      )
    )
    XCTAssertTrue(
      ApplicationChangeMonitor.affectsApplicationBundle(
        "/Users/me/Applications/Example.app/Contents/MacOS/Example"
      )
    )
  }

  func testNonApplicationPathsAreIgnored() {
    XCTAssertFalse(ApplicationChangeMonitor.affectsApplicationBundle("/Applications"))
    XCTAssertFalse(ApplicationChangeMonitor.affectsApplicationBundle("/Applications/readme.txt"))
    XCTAssertFalse(
      ApplicationChangeMonitor.affectsApplicationBundle(
        "/Users/me/Applications/Example.appdownload/partial"
      )
    )
  }

  func testDroppedEventsForceRescanEvenWithoutApplicationPath() {
    let flags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)

    XCTAssertTrue(
      ApplicationChangeMonitor.requiresApplicationRescan(path: "/Applications", flags: flags)
    )
  }

  func testOrdinaryDirectoryEventsAreIgnored() {
    XCTAssertFalse(
      ApplicationChangeMonitor.requiresApplicationRescan(path: "/Applications", flags: 0)
    )
  }
}
