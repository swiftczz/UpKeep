import Foundation
import XCTest

@testable import UpkeepPrivilegedHelper

final class PrivilegedPackageOperationTests: XCTestCase {
    func testDeveloperInstallValidatesPrivateCopyAndVerifiesResultWithoutStoreReceipt() throws {
        let (root, package, app) = try fixture()
        var steps: [String] = []
        var staged: URL?
        let error = PrivilegedPackageOperation.install(
            packageURL: package, receiptURL: nil, applicationURL: app,
            bundleIdentifier: "com.example.app", version: "2.0", buildVersion: "200", isRoot: true,
            validate: { copy, target, id, version, build in
                steps.append("validate")
                staged = copy
                XCTAssertNotEqual(copy, package)
                XCTAssertEqual(target, app)
                XCTAssertEqual(id, "com.example.app")
                XCTAssertEqual(version, "2.0")
                XCTAssertEqual(build, "200")
                XCTAssertEqual(try Data(contentsOf: copy), Data("original".utf8))
                let attributes = try FileManager.default.attributesOfItem(atPath: copy.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
                let directory = try FileManager.default.attributesOfItem(
                    atPath: copy.deletingLastPathComponent().path)
                XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
                try Data("changed".utf8).write(to: package)
                return "EXAMPLE123"
            },
            verifyInstalled: { target, id, team, version, build in
                steps.append("verify")
                XCTAssertEqual(target, app)
                XCTAssertEqual(id, "com.example.app")
                XCTAssertEqual(team, "EXAMPLE123")
                XCTAssertEqual(version, "2.0")
                XCTAssertEqual(build, "200")
            },
            runCommand: { command, arguments in
                if command == "/usr/sbin/installer" {
                    steps.append("installer")
                    XCTAssertEqual(arguments, ["-dumplog", "-pkg", staged!.path, "-target", "/"])
                    XCTAssertEqual(try? Data(contentsOf: staged!), Data("original".utf8))
                } else {
                    steps.append("metadata")
                    XCTAssertEqual(command, "/usr/bin/mdimport")
                }
                return nil
            })
        XCTAssertNil(error)
        XCTAssertEqual(steps, ["validate", "installer", "verify", "metadata"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(staged).path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Target.app/Contents/_MASReceipt").path))
    }

    func testValidationFailureNeverRunsInstallerAndRemovesPrivateCopy() throws {
        let (_, package, app) = try fixture()
        var staged: URL?
        let error = PrivilegedPackageOperation.install(
            packageURL: package, receiptURL: nil, applicationURL: app,
            bundleIdentifier: "com.example.app", version: "2.0", isRoot: true,
            validate: { copy, _, _, _, _ in
                staged = copy
                throw NSError(
                    domain: "test", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "untrusted package"])
            },
            runCommand: { _, _ in
                XCTFail("Must not execute installer")
                return nil
            })
        XCTAssertEqual(error, "untrusted package")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(staged).path))
    }

    func testInstallerAndPostInstallVerificationFailuresAreReported() throws {
        let (_, package, app) = try fixture()
        for installerFails in [true, false] {
            var verified = false
            let error = PrivilegedPackageOperation.install(
                packageURL: package, receiptURL: nil, applicationURL: app,
                bundleIdentifier: "com.example.app", version: "2.0", isRoot: true,
                validate: { _, _, _, _, _ in "EXAMPLE123" },
                verifyInstalled: { _, _, _, _, _ in
                    verified = true
                    throw NSError(
                        domain: "test", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "wrong installed version"])
                },
                runCommand: { command, _ in
                    XCTAssertEqual(command, "/usr/sbin/installer")
                    return installerFails ? "installer failed" : nil
                })
            XCTAssertEqual(error, installerFails ? "installer failed" : "wrong installed version")
            XCTAssertEqual(verified, !installerFails)
        }
    }

    func testMissingVersionAndSymlinkCannotReachInstaller() throws {
        let (root, package, app) = try fixture()
        XCTAssertEqual(
            PrivilegedPackageOperation.install(
                packageURL: package, receiptURL: nil, applicationURL: app,
                bundleIdentifier: "com.example.app", isRoot: true,
                runCommand: { _, _ in
                    XCTFail()
                    return nil
                }), "缺少目标应用版本。")
        let link = root.appendingPathComponent("link.pkg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package)
        XCTAssertNotNil(
            PrivilegedPackageOperation.install(
                packageURL: link, receiptURL: nil, applicationURL: app,
                bundleIdentifier: "com.example.app", version: "2.0", isRoot: true,
                validate: { _, _, _, _, _ in
                    XCTFail()
                    return ""
                },
                runCommand: { _, _ in
                    XCTFail()
                    return nil
                }))
    }

    private func fixture() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Target.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let package = root.appendingPathComponent("update.pkg")
        try Data("original".utf8).write(to: package)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, package, app)
    }
}
