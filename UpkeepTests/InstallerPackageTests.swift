import CryptoKit
import Foundation
import XCTest

@testable import Upkeep
@testable import UpkeepPrivilegedHelperProtocol

final class InstallerPackageTests: XCTestCase {
    func testPKGRequiresExplicitDownloadOptIn() {
        let url = URL(string: "https://example.com/App.pkg")!
        XCTAssertNil(
            ApplicationPackageInstaller.supportedPackageFileName(
                suggestedFilename: nil, sourceURL: url))
        XCTAssertEqual(
            ApplicationPackageInstaller.supportedPackageFileName(
                suggestedFilename: nil, sourceURL: url, allowsInstallerPackage: true), "App.pkg")
        XCTAssertFalse(ApplicationPackageInstaller.isPotentiallyInstallablePackageURL(url))
    }

    func testSignedPackageArchiveVerifiesBeforeExtractingAndCannotRotateKeys() throws {
        let root = try directory()
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("package".utf8).write(to: source.appendingPathComponent("Update.pkg"))
        let archive = root.appendingPathComponent("Update.zip")
        _ = try DeveloperPackageValidation.commandOutput(
            "/usr/bin/ditto", ["-ck", source.path, archive.path])
        let data = try Data(contentsOf: archive)
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: data).base64EncodedString()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        for (signatureValue, keyValue) in [
            (nil, publicKey), (signature, nil),
            (
                signature,
                Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
            ),
        ] as [(String?, String?)] {
            let destination = root.appendingPathComponent(UUID().uuidString)
            XCTAssertThrowsError(
                try ApplicationPackageInstaller.extractAndVerifyInstallerPackage(
                    from: archive, into: destination, signature: signatureValue, publicKey: keyValue
                ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
        let package = try ApplicationPackageInstaller.extractAndVerifyInstallerPackage(
            from: archive, into: root.appendingPathComponent("extracted"), signature: signature,
            publicKey: publicKey)
        XCTAssertEqual(try Data(contentsOf: package), Data("package".utf8))
    }

    func testAmbiguousMissingAndSymlinkPackagesAreRejected() throws {
        for mode in ["multiple", "missing", "symlink", "directory"] {
            let root = try directory()
            let source = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let package = source.appendingPathComponent("Update.pkg")
            switch mode {
            case "multiple":
                try Data().write(to: package)
                try Data().write(to: source.appendingPathComponent("Another.pkg"))
            case "symlink":
                let target = source.appendingPathComponent("real")
                try Data().write(to: target)
                try FileManager.default.createSymbolicLink(at: package, withDestinationURL: target)
            case "directory":
                try FileManager.default.createDirectory(
                    at: package, withIntermediateDirectories: false)
            default: try Data().write(to: source.appendingPathComponent("Readme.txt"))
            }
            let archive = root.appendingPathComponent("Update.tar.gz")
            _ = try DeveloperPackageValidation.commandOutput(
                "/usr/bin/tar", ["-czf", archive.path, "-C", source.path, "."])
            XCTAssertThrowsError(
                try ApplicationPackageInstaller.extractInstallerPackage(
                    from: archive, into: root.appendingPathComponent("extracted")), mode)
        }
    }

    func testSparklePackagesRequireSignatureVersionAndInstalledKey() async throws {
        let feed = URL(string: "https://example.com/appcast.xml")!
        let xml = """
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
              <sparkle:shortVersionString>2.0</sparkle:shortVersionString><sparkle:version>200</sparkle:version>
              <enclosure url="https://example.com/Update.dmg" sparkle:installationType="package" sparkle:edSignature="signature"/>
            </item></channel></rss>
            """
        var candidate = try XCTUnwrap(SparkleAppcastParser(data: Data(xml.utf8)).parse().first)
        XCTAssertEqual(candidate.installationKind, .installerPackage)
        XCTAssertNotNil(candidate.supportedPackageURL(relativeTo: feed))
        for name in ["Update.pkg", "Update.zip", "Update.tar.gz"] {
            candidate.downloadURL = URL(string: "https://example.com/" + name)
            XCTAssertNotNil(candidate.supportedPackageURL(relativeTo: feed))
        }
        candidate.installationType = nil
        candidate.downloadURL = URL(string: "https://example.com/Update.pkg")
        XCTAssertEqual(candidate.installationKind, .installerPackage)
        candidate.edSignature = nil
        XCTAssertNil(candidate.supportedPackageURL(relativeTo: feed))
        candidate.edSignature = "signature"
        candidate.shortVersion = nil
        candidate.buildVersion = nil
        XCTAssertNil(candidate.supportedPackageURL(relativeTo: feed))

        let root = try directory()
        let app = root.appendingPathComponent("Example.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: String] = [
            "CFBundleIdentifier": "com.example.pkg", "SUPublicEDKey": "installed-key",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let provider = SparkleUpdateProvider(fetchData: { _ in Data(xml.utf8) })
        var record = AppRecord(
            name: "Example", bundleIdentifier: "com.example.pkg", applicationURL: app,
            currentVersion: "1.0", buildVersion: "100",
            updateConfiguration: UpdateConfiguration(mechanism: .sparkle, feedURL: feed))
        let result = await provider.check(record)
        XCTAssertTrue(result.canAutomaticallyUpdate)
        XCTAssertEqual(result.status, .updateAvailable)
        record = AppRecord(
            name: "Example", bundleIdentifier: "com.example.pkg",
            applicationURL: root.appendingPathComponent("NoKey.app"), currentVersion: "1.0",
            updateConfiguration: UpdateConfiguration(mechanism: .sparkle, feedURL: feed))
        let missingKey = await provider.check(record)
        XCTAssertFalse(missingKey.canAutomaticallyUpdate)
    }

    func testInstallerCertificateAndGatekeeperMustEstablishDeveloperTrust() throws {
        XCTAssertEqual(
            DeveloperPackageValidation.packageTeam(
                in:
                    " 1. Developer ID Installer: Example (EXAMPLE123)\n 2. Developer ID Certification Authority"
            ), "EXAMPLE123")
        XCTAssertNil(
            DeveloperPackageValidation.packageTeam(
                in: "1. Developer ID Application: Example (EXAMPLE123)"))
        XCTAssertNil(
            DeveloperPackageValidation.packageTeam(
                in: "2. Developer ID Installer: Example (EXAMPLE123)"))
        for (verdict, source, override, expected) in [
            (true, "Notarized Developer ID", false, true),
            (true, "Developer ID", false, true),
            (false, "Notarized Developer ID", false, false),
            (true, "Notarized Developer ID", true, false),
            (true, "Unknown", false, false),
        ] {
            var authority: [String: Any] = ["assessment:authority:source": source]
            if override { authority["assessment:authority:override"] = "security disabled" }
            let data = try PropertyListSerialization.data(
                fromPropertyList: [
                    "assessment:verdict": verdict, "assessment:authority": authority,
                ], format: .xml, options: 0)
            XCTAssertEqual(DeveloperPackageValidation.acceptedAssessment(data), expected)
        }
    }

    func testPackageMetadataMustMatchTargetBundleAndBothVersions() throws {
        let root = try directory()
        let info = root.appendingPathComponent("PackageInfo")
        try Data(
            """
            <pkg-info><bundle id="com.example.pkg" CFBundleShortVersionString="2.0" CFBundleVersion="200"/></pkg-info>
            """.utf8
        ).write(to: info)
        let package = root.appendingPathComponent("Update.pkg")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xar")
        process.currentDirectoryURL = root
        process.arguments = ["-cf", package.path, "PackageInfo"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        for (id, version, build, succeeds) in [
            ("com.example.pkg", "2.0", "200", true),
            ("com.other.pkg", "2.0", "200", false),
            ("com.example.pkg", "3.0", "200", false),
            ("com.example.pkg", "2.0", "201", false),
        ] {
            let validate = {
                try DeveloperPackageValidation.validateContents(
                    packageURL: package, bundleIdentifier: id,
                    version: version, buildVersion: build,
                    command: DeveloperPackageValidation.commandOutput)
            }
            if succeeds {
                XCTAssertNoThrow(try validate())
            } else {
                XCTAssertThrowsError(try validate())
            }
        }
    }

    func testUnsafeMetadataPathsAreRejectedBeforeExtraction() {
        for path in ["../PackageInfo", "/PackageInfo", "--option/PackageInfo"] {
            var calls = 0
            XCTAssertThrowsError(
                try DeveloperPackageValidation.validateContents(
                    packageURL: URL(fileURLWithPath: "/tmp/Test.pkg"),
                    bundleIdentifier: "com.example.pkg",
                    version: "2.0", buildVersion: "200",
                    command: { executable, arguments in
                        calls += 1
                        XCTAssertEqual(executable, "/usr/bin/xar")
                        XCTAssertEqual(arguments.first, "-tf")
                        return Data(path.utf8)
                    }))
            XCTAssertEqual(calls, 1)
        }
    }

    func testUnsignedInstalledApplicationCannotAuthorizePackage() throws {
        let root = try directory()
        let app = root.appendingPathComponent("Unsigned.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.pkg"],
            format: .xml, options: 0
        ).write(to: contents.appendingPathComponent("Info.plist"))
        for id in ["com.example.pkg", "com.other.pkg"] {
            XCTAssertThrowsError(
                try DeveloperPackageValidation.validate(
                    packageURL: root.appendingPathComponent("Update.pkg"), applicationURL: app,
                    bundleIdentifier: id, version: "2.0", buildVersion: "200",
                    command: { _, _ in
                        XCTFail("Untrusted app must be rejected first")
                        return Data()
                    }))
        }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
