import Foundation
import XCTest

@testable import Upkeep

final class ApplicationArchiveTests: XCTestCase {
    func testXZPackagesUseTheSharedSelectionAndDownloadFileNameRules() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/Example.TAR.XZ"))
        XCTAssertGreaterThan(
            ApplicationPackageInstaller.packageKindScore(of: url.lastPathComponent), 0)
        XCTAssertTrue(ApplicationPackageInstaller.isPotentiallyInstallablePackageURL(url))
        XCTAssertEqual(
            ApplicationPackageInstaller.supportedPackageFileName(
                suggestedFilename: nil, sourceURL: url), "Example.TAR.XZ")
        XCTAssertEqual(
            ApplicationPackageInstaller.supportedPackageFileName(
                suggestedFilename: "Example.tar.xz",
                sourceURL: URL(
                    string: "https://api.github.com/repos/example/app/releases/assets/123")!),
            "Example.tar.xz")
    }

    func testSystemTarExtractsBothXZAndExistingGzipApplicationPackages() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source")
        let contents = source.appendingPathComponent("Example.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.example.archive", "CFBundleShortVersionString": "1.0",
            ], format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        for (suffix, flags) in [("tar.xz", "-cJf"), ("tar.gz", "-czf"), ("tgz", "-czf")] {
            let archive = root.appendingPathComponent("Example." + suffix)
            try tar([flags, archive.path, "-C", source.path, "Example.app"])
            let result = try ApplicationPackageInstaller.extractApplication(
                from: archive, into: root.appendingPathComponent("extracted-" + suffix))
            XCTAssertEqual(result.lastPathComponent, "Example.app")
            XCTAssertEqual(
                try Data(contentsOf: result.appendingPathComponent("Contents/Info.plist")), info)
        }
    }

    func testXZWithoutAnApplicationStillFailsAndUnsupportedFormatsRemainRejected() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("No app bundle".utf8).write(to: source.appendingPathComponent("readme.txt"))
        let archive = root.appendingPathComponent("Empty.tar.xz")
        try tar(["-cJf", archive.path, "-C", source.path, "readme.txt"])
        XCTAssertThrowsError(
            try ApplicationPackageInstaller.extractApplication(
                from: archive, into: root.appendingPathComponent("empty"))
        ) {
            guard case ApplicationPackageInstallerError.missingApplication = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
        for name in ["App.xz", "App.tar", "App.tar.xz.sig", "App.tar.xz.blockmap", "App.pkg"] {
            XCTAssertEqual(ApplicationPackageInstaller.packageKindScore(of: name), 0)
        }
    }

    func testSparkleXZApplicationReleaseRemainsDirectlyUpdatable() async throws {
        let feed = URL(string: "https://example.com/appcast.xml")!
        let xml = """
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
              <title>0.82.0</title><sparkle:version>820099</sparkle:version>
              <sparkle:shortVersionString>0.82.0</sparkle:shortVersionString>
              <description>Release notes</description>
              <enclosure url="https://example.com/Example-0.82.0.tar.xz" length="41754460" sparkle:edSignature="signed-update"/>
            </item></channel></rss>
            """
        let candidate = try XCTUnwrap(SparkleAppcastParser(data: Data(xml.utf8)).parse().first)
        XCTAssertEqual(candidate.edSignature, "signed-update")
        XCTAssertNotNil(candidate.supportedPackageURL(relativeTo: feed))
        let result = await SparkleUpdateProvider(fetchData: { url in
            XCTAssertEqual(url, feed)
            return Data(xml.utf8)
        }).check(
            AppRecord(
                name: "Example", bundleIdentifier: "com.example.archive",
                applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
                currentVersion: "0.81.0", buildVersion: "140",
                updateConfiguration: UpdateConfiguration(mechanism: .sparkle, feedURL: feed)))
        XCTAssertEqual(result.status, .updateAvailable)
        XCTAssertTrue(result.canAutomaticallyUpdate)
        XCTAssertEqual(result.latestVersion, "0.82.0")
        XCTAssertEqual(result.latestBuildVersion, "820099")
        XCTAssertEqual(result.packageByteCount, 41_754_460)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func tar(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
