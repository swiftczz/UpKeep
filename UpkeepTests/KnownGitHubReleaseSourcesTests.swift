import Foundation
import XCTest

@testable import Upkeep

final class KnownGitHubReleaseSourcesTests: XCTestCase {
    func testDetectsCraftRepositoriesWithoutEmbeddedUpdateURLs() throws {
        for slug in [
            "photocraft", "vectorcraft", "filmcraft", "lightcraft", "pdfcraft", "effectcraft",
            "designcraft", "wordcraft", "deckcraft", "gridcraft", "cadcraft", "soundcraft",
            "figcraft",
            "futurecraft", "new-designcraft", "3dcraft",
        ] {
            let url = try makeApplication(bundleIdentifier: "ai.storyteller.\(slug)")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let record = try XCTUnwrap(ApplicationScanner.makeRecord(from: url))

            XCTAssertEqual(record.updateConfiguration.mechanism, .githubReleases, slug)
            XCTAssertEqual(record.updateConfiguration.identifier, "storytold/\(slug)", slug)
            XCTAssertEqual(
                record.updateConfiguration.feedURL?.absoluteString,
                "https://api.github.com/repos/storytold/\(slug)/releases/latest", slug)
            XCTAssertEqual(
                record.updateConfiguration.homepageURL?.absoluteString,
                "https://github.com/storytold/\(slug)", slug)
            XCTAssertEqual(record.status, .checking, slug)
            XCTAssertEqual(record.currentVersion, "0.7.0", slug)
        }
    }

    func testRequiresCraftNamespaceAndSingleSafeRepositorySlugEvenWhenNameMatches() throws {
        for identifier in [
            "com.example.photocraft", "ai.storyteller.photocraft.beta", "ai.storyteller.editor",
            "ai.storyteller.craft", "ai.storyteller.-newcraft",
            "ai.storyteller.newcraft\n", "ai.storyteller.newcraft/othercraft",
            "ai.storyteller.newcraft?redirect=evilcraft", "ai.storyteller.%66igcraft",
            "ai.storyteller.\u{0440}hotocraft", "other.ai.storyteller.photocraft",
        ] {
            let url = try makeApplication(bundleIdentifier: identifier)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let record = try XCTUnwrap(ApplicationScanner.makeRecord(from: url))

            XCTAssertEqual(record.updateConfiguration.mechanism, .selfManaged, identifier)
            XCTAssertNil(record.updateConfiguration.feedURL, identifier)
        }
    }

    func testInstalledScanIdentifiesKnownRepositoryWithoutReadingExecutable() throws {
        let url = try makeApplication(bundleIdentifier: "ai.storyteller.futurecraft")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let record = try XCTUnwrap(ApplicationScanner.makeRecord(from: url, sourceDetection: .installedOnly))

        XCTAssertEqual(record.updateConfiguration.mechanism, .githubReleases)
        XCTAssertEqual(record.updateConfiguration.identifier, "storytold/futurecraft")
    }

    func testRecoversUnchangedApplicationPreviouslyCachedWithoutAnUpdateSource() throws {
        let url = try makeApplication(bundleIdentifier: "ai.storyteller.futurecraft")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var cached = try XCTUnwrap(ApplicationScanner.makeRecord(from: url))
        cached.updateConfiguration.mechanism = .selfManaged
        cached.updateConfiguration.feedURL = nil
        cached.updateConfiguration.identifier = nil
        cached.status = .selfManaged

        let record = try XCTUnwrap(ApplicationScanner.makeRecord(from: url, reusing: cached))

        XCTAssertEqual(record.applicationModificationDate, cached.applicationModificationDate)
        XCTAssertEqual(record.updateConfiguration.mechanism, .githubReleases)
        XCTAssertEqual(record.updateConfiguration.identifier, "storytold/futurecraft")
        XCTAssertEqual(record.status, .checking)
    }

    func testPreservesCheckedKnownSourceMetadataOnUnchangedApplication() throws {
        let url = try makeApplication(bundleIdentifier: "ai.storyteller.futurecraft")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var cached = try XCTUnwrap(ApplicationScanner.makeRecord(from: url))
        cached.latestVersion = "0.8.0"
        cached.releaseNotes = "New release"
        cached.status = .updateAvailable

        let record = try XCTUnwrap(ApplicationScanner.makeRecord(from: url, reusing: cached))

        XCTAssertEqual(record.latestVersion, "0.8.0")
        XCTAssertEqual(record.releaseNotes, "New release")
        XCTAssertEqual(record.status, .updateAvailable)
    }

    func testExplicitSparkleFeedTakesPriorityOverKnownRepository() throws {
        let feed = "https://example.com/appcast.xml"
        let url = try makeApplication(extraInfo: ["SUFeedURL": feed])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        for record in [
            ApplicationScanner.makeRecord(from: url),
            ApplicationScanner.makeRecord(from: url, sourceDetection: .installedOnly),
        ] {
            let record = try XCTUnwrap(record)
            XCTAssertEqual(record.updateConfiguration.mechanism, .sparkle)
            XCTAssertEqual(record.updateConfiguration.feedURL?.absoluteString, feed)
        }
    }

    func testAppStoreReceiptTakesPriorityOverKnownRepository() throws {
        let url = try makeApplication()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let receipt = url.appendingPathComponent("Contents/_MASReceipt/receipt")
        try FileManager.default.createDirectory(
            at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: receipt)

        for record in [
            ApplicationScanner.makeRecord(from: url),
            ApplicationScanner.makeRecord(from: url, sourceDetection: .installedOnly),
        ] {
            XCTAssertEqual(try XCTUnwrap(record).updateConfiguration.mechanism, .appStore)
        }
    }

    func testRecognizesInstalledCraftApplicationsWhenPresent() throws {
        var checked = 0
        for name in [
            "PhotoCraft", "VectorCraft", "FilmCraft", "PdfCraft", "WordCraft", "DeckCraft",
            "GridCraft",
            "FigCraft",
        ] {
            let url = URL(fileURLWithPath: "/Applications/\(name).app")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let record = try XCTUnwrap(ApplicationScanner.makeRecord(from: url))
            XCTAssertEqual(record.updateConfiguration.mechanism, .githubReleases, name)
            XCTAssertEqual(
                record.updateConfiguration.identifier, "storytold/\(name.lowercased())", name)
            checked += 1
        }
        if checked == 0 { throw XCTSkip("No Craft applications installed on this machine.") }
    }

    private func makeApplication(
        bundleIdentifier: String = "ai.storyteller.photocraft",
        extraInfo: [String: Any] = [:]
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "UpkeepCraftTests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("PhotoCraft.app")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": "PhotoCraft",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.7.0",
            "CFBundleVersion": "0.7.0",
        ]
        info.merge(extraInfo) { _, new in new }
        let data = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }
}
