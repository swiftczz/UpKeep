import Foundation
import XCTest

@testable import Upkeep

final class ElectronReleaseNotesTests: XCTestCase {
    func testQoderEmptyObjectDoesNotBecomeReleaseNoteText() throws {
        let manifest = try XCTUnwrap(
            ElectronBuilderYAML.parseManifest(
                """
                version: 0.4.7
                files:
                  - url: https://download.qoder.com.cn/qoder-app/releases/0.4.7/Qoder-mac-arm64.zip
                    sha512: expected-checksum
                    size: 302304493
                releaseDate: 2026-10-14T06:32:57.567Z
                releaseNotes: {}
                """))
        XCTAssertNil(manifest.releaseNotes)
        XCTAssertEqual(manifest.version, "0.4.7")
        XCTAssertNotNil(manifest.releaseDate)
        let feed = try XCTUnwrap(
            URL(string: "https://download.qoder.com.cn/qoder-app/releases/latest-mac.yml"))
        let package = try XCTUnwrap(
            manifest.selectedPackage(relativeTo: feed, architecture: .arm64))
        XCTAssertEqual(package.url.lastPathComponent, "Qoder-mac-arm64.zip")
        XCTAssertEqual(package.sha512, "expected-checksum")
        XCTAssertEqual(package.size, 302_304_493)
    }

    func testEmptyReleaseNoteMarkersAreAbsent() throws {
        for value in ["{}", "{ }", "[]", "[ ]", "null", "Null", "NULL", "~", "''", "\"\"", ""] {
            let manifest = try XCTUnwrap(
                ElectronBuilderYAML.parseManifest("version: 1.0\nreleaseNotes: \(value)\n"))
            XCTAssertNil(manifest.releaseNotes, value)
        }
        let absent = try XCTUnwrap(ElectronBuilderYAML.parseManifest("version: 1.0"))
        XCTAssertNil(absent.releaseNotes)
    }

    func testPreservesInlineNotesContainingJSONOrNullWords() throws {
        for notes in [
            "修复连接问题", "Fixed null values and empty {} objects", "Use [] for an empty list",
        ] {
            let manifest = try XCTUnwrap(
                ElectronBuilderYAML.parseManifest("version: 1.0\nreleaseNotes: '\(notes)'\n"))
            XCTAssertEqual(manifest.releaseNotes, notes)
        }
    }

    func testPreservesMultilineMarkdownAndIgnoresWhitespaceOnlyBlock() throws {
        let notes = try XCTUnwrap(
            ElectronBuilderYAML.parseManifest(
                """
                version: 1.0
                releaseNotes: |
                  ## Fixes
                  - Fixed null handling
                  - JSON example: {}
                """))
        XCTAssertEqual(notes.releaseNotes, "## Fixes\n- Fixed null handling\n- JSON example: {}")
        let blank = try XCTUnwrap(
            ElectronBuilderYAML.parseManifest("version: 1.0\nreleaseNotes: |\n  \n"))
        XCTAssertNil(blank.releaseNotes)
    }
}
