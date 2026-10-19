import Darwin
import Foundation
import UpkeepPrivilegedHelperProtocol
import XCTest

@testable import UpkeepPrivilegedHelper

final class PrivilegedApplicationTrashOperationTests: XCTestCase {
    func testOnlyAcceptsDirectApplicationsChildren() {
        XCTAssertTrue(
            PrivilegedTrashPolicy.isSupportedApplicationPath("/Applications/Test Flight.app"))
        for path in [
            "/Applications", "/Applications/.app", "/Applications/Example.app/Contents",
            "/System/Applications/Example.app", "/Applications/../Example.app",
            "/Applications/Nested/Example.app", "/Applications//Example.app",
            "/Applications/Example.app\0/evil.app", "Applications/Example.app",
        ] {
            XCTAssertFalse(PrivilegedTrashPolicy.isSupportedApplicationPath(path), path)
        }
    }

    func testSystemAccountsCannotUseBiometricUninstall() {
        XCTAssertFalse(PrivilegedTrashPolicy.isAdministrator(0))
        XCTAssertFalse(PrivilegedTrashPolicy.isAdministrator(1))
    }

    func testMovesWholeBundleToTrashAndPreservesContents() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        try fixture.move()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.app.path))
        XCTAssertEqual(
            try Data(contentsOf: fixture.trash.appendingPathComponent("Example.app/data")),
            Data("application-content".utf8))
    }

    func testExistingTrashItemIsNeverOverwritten() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let existing = fixture.trash.appendingPathComponent("Example.app")
        try Data("keep-me".utf8).write(to: existing)
        try fixture.move()
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep-me".utf8))
        let items = try FileManager.default.contentsOfDirectory(
            at: fixture.trash, includingPropertiesForKeys: nil)
        XCTAssertEqual(items.count, 2)
        let moved = try XCTUnwrap(items.first { $0 != existing })
        XCTAssertEqual(moved.pathExtension, "app")
        XCTAssertEqual(
            try Data(contentsOf: moved.appendingPathComponent("data")),
            Data("application-content".utf8))
    }

    func testRejectsEntireUnsafeBatchBeforeMoving() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        XCTAssertThrowsError(
            try fixture.move(paths: ["/Applications/Example.app", "/Library/Important.app"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
    }

    func testRejectsDuplicateTargetsAndHostApplication() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        XCTAssertThrowsError(
            try fixture.move(paths: ["/Applications/Example.app", "/Applications/Example.app"]))
        XCTAssertThrowsError(
            try fixture.move(host: URL(fileURLWithPath: "/Applications/Example.app")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
    }

    func testAppSymlinkCannotMoveItsTarget() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let target = fixture.root.appendingPathComponent("Keep.app")
        try FileManager.default.moveItem(at: fixture.app, to: target)
        try FileManager.default.createSymbolicLink(at: fixture.app, withDestinationURL: target)
        XCTAssertThrowsError(try fixture.move())
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: target.appendingPathComponent("data").path))
    }

    func testTrashSymlinkIsRejected() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let other = fixture.root.appendingPathComponent("Other")
        try FileManager.default.moveItem(at: fixture.trash, to: other)
        try FileManager.default.createSymbolicLink(at: fixture.trash, withDestinationURL: other)
        XCTAssertThrowsError(try fixture.move())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
    }

    func testSymlinkInHomePathIsRejected() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let link = fixture.root.appendingPathComponent("LinkedHome")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.home)
        XCTAssertThrowsError(try fixture.move(home: link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
    }

    func testWrongUserOrWritableTrashIsRejected() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        XCTAssertThrowsError(try fixture.move(uid: geteuid() + 1))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777], ofItemAtPath: fixture.trash.path)
        XCTAssertThrowsError(try fixture.move())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
    }

    func testMissingTrashDoesNotCreateAnythingAsRoot() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.trash)
        XCTAssertThrowsError(try fixture.move())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.trash.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
    }

    func testRegularFileWithAppExtensionIsRejected() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.app)
        try Data("keep".utf8).write(to: fixture.app)
        XCTAssertThrowsError(try fixture.move())
        XCTAssertEqual(try Data(contentsOf: fixture.app), Data("keep".utf8))
    }
}

private struct TrashFixture {
    let root: URL
    let applications: URL
    let home: URL
    let trash: URL
    let app: URL

    init() throws {
        // Foundation preserves the /var alias even after resolvingSymlinksInPath.
        // Use the physical path so tests exercise the no-symlink directory walk.
        let physicalPath = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physicalPath) }
        root = URL(fileURLWithPath: String(cString: physicalPath))
            .appendingPathComponent("Upkeep-Trash-Test-\(UUID().uuidString)")
        applications = root.appendingPathComponent("Applications")
        home = root.appendingPathComponent("Home")
        trash = home.appendingPathComponent(".Trash")
        app = applications.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: trash, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try Data("application-content".utf8).write(to: app.appendingPathComponent("data"))
    }

    func move(
        paths: [String] = ["/Applications/Example.app"], uid: uid_t = geteuid(),
        home: URL? = nil, host: URL? = URL(fileURLWithPath: "/Applications/Upkeep.app")
    ) throws {
        try PrivilegedApplicationTrashOperation.moveApplications(
            paths, callerUID: uid,
            homeDirectory: home ?? self.home, hostApplicationURL: host,
            applicationsDirectory: applications)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
