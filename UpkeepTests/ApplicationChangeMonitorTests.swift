import CoreServices
import XCTest

@testable import Upkeep

final class ApplicationChangeMonitorTests: XCTestCase {
    func testApplicationBundlePathsAreRelevant() {
        XCTAssertTrue(
            ApplicationChangeMonitor.affectsApplicationBundle("/Applications/Example.app"))
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
        XCTAssertFalse(
            ApplicationChangeMonitor.affectsApplicationBundle("/Applications/readme.txt"))
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

    func testHomebrewReceiptWrittenAfterApplicationMoveTriggersRescan() {
        XCTAssertTrue(
            ApplicationChangeMonitor.requiresApplicationRescan(
                path: "/opt/homebrew/Caskroom/chatgpt/.metadata/INSTALL_RECEIPT.json", flags: 0
            ))
        XCTAssertTrue(
            ApplicationChangeMonitor.requiresApplicationRescan(
                path: "/usr/local/Caskroom/example/.metadata/INSTALL_RECEIPT.json", flags: 0
            ))
        XCTAssertFalse(
            ApplicationChangeMonitor.requiresApplicationRescan(
                path: "/opt/homebrew/Caskroom/example/.metadata/example.json", flags: 0
            ))
    }
}
