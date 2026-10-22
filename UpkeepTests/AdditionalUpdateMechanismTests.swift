import Foundation
import XCTest

@testable import Upkeep

final class AdditionalUpdateMechanismTests: XCTestCase, @unchecked Sendable {
    func testDictionaryAssetsResolvePackagesAndRetainChecksums() throws {
        let data = try json([
            "version": "1.2.0", "published": "2026-10-19T00:00:00Z", "notes": "New release",
            "assets": [
                "editor-darwin-arm64.zip": [
                    "url": "https://example.com/editor-darwin-arm64.zip", "sha256": "abc",
                    "size": 123,
                ],
                "editor-cli-darwin-arm64.zip": [
                    "url": "https://example.com/editor-cli-darwin-arm64.zip"
                ],
                "editor-linux-arm64.tar.gz": [
                    "url": "https://example.com/editor-linux-arm64.tar.gz"
                ],
                "editor-server-macos-arm64.zip": [
                    "url": "https://example.com/editor-server-macos-arm64.zip"
                ],
            ],
        ])
        let manifest = try XCTUnwrap(HeuristicJSONReleaseParser.parse(data))
        let package = try XCTUnwrap(manifest.selectedPackage(architecture: .arm64))
        XCTAssertEqual(package.name, "editor-darwin-arm64.zip")
        XCTAssertEqual(package.sha256, "abc")
        XCTAssertEqual(package.size, 123)
        XCTAssertNotNil(manifest.publicationDate)
        XCTAssertNil(manifest.selectedPackage(architecture: .x64))
    }

    func testUnsafeAssetURLsAreRejected() throws {
        for download in [
            "/api/download/Editor-macos-arm64.dmg", "//evil.example.com/app.dmg",
            "http://example.com/app.dmg", "https://user:secret@example.com/app.dmg",
        ] {
            XCTAssertNil(
                HeuristicJSONReleaseParser.parse(
                    try json(["version": "1.0", "assets": [["url": download]]])))
        }
    }

    func testLorcaTemplatePersistsDesktopChannelAcrossSnapshotAndAlternateSource() throws {
        let metadata = try XCTUnwrap(
            GitHubReleasesDetector.metadata(
                in:
                    "https://github.com/egoist/lorca/releases/download/desktop-v{version}/update-darwin-arm64.json"
            ))
        XCTAssertEqual(metadata.identifier, "egoist/lorca")
        XCTAssertEqual(metadata.tagPrefix, "desktop-v")
        XCTAssertEqual(metadata.apiURL.path, "/repos/egoist/lorca/releases")
        var application = record(mechanism: .githubReleases, url: metadata.apiURL.absoluteString)
        application.updateConfiguration.githubReleaseTagPrefix = metadata.tagPrefix
        let decoded = try JSONDecoder().decode(
            AppRecord.self, from: JSONEncoder().encode(application))
        XCTAssertEqual(decoded.updateConfiguration.githubReleaseTagPrefix, "desktop-v")
        var brew = application
        brew.updateConfiguration.mechanism = .homebrew
        brew.rememberAlternateUpdateConfiguration(from: application)
        XCTAssertEqual(
            brew.alternateUpdateCheckRecord?.updateConfiguration.githubReleaseTagPrefix, "desktop-v"
        )
        XCTAssertNil(
            GitHubReleasesDetector.metadata(
                in:
                    "https://github.com/egoist/lorca/releases/download/desktop-v0.1.16/update-darwin-arm64.json"
            ))
    }

    func testChannelLookupIgnoresCLIAndMobileAndChoosesNewestStableDesktop() async throws {
        let data = try json([
            release("cli-v9.0.0"), release("mobile-v8.0.0"), release("desktop-v0.1.14"),
            release("desktop-v0.2.0", prerelease: true), release("desktop-v0.1.16"),
            release("desktop-v0.3.0", draft: true),
        ])
        let provider = GitHubReleasesUpdateProvider(fetchResponse: { url in
            XCTAssertEqual(url.path, "/repos/egoist/lorca/releases")
            XCTAssertTrue(url.query?.contains("page=1") == true)
            return (200, data)
        })
        var application = record(
            mechanism: .githubReleases,
            url: "https://api.github.com/repos/egoist/lorca/releases?per_page=100")
        application.currentVersion = "0.1.14"
        application.updateConfiguration.githubReleaseTagPrefix = "desktop-v"
        let checked = await provider.check(application)
        XCTAssertEqual(checked.latestVersion, "0.1.16")
        XCTAssertEqual(checked.releaseNotes, "desktop-v0.1.16")
        XCTAssertEqual(checked.status, .updateAvailable)
        application.currentVersion = "0.1.16"
        let current = await provider.check(application)
        XCTAssertEqual(current.status, .upToDate)
    }

    func testChannelLookupContinuesWhenFirstPageContainsOnlyOtherProducts() async throws {
        let firstPage = try json(Array(repeating: release("cli-v9.0.0"), count: 100))
        let secondPage = try json([release("desktop-v1.2.0")])
        let provider = GitHubReleasesUpdateProvider(fetchResponse: { url in
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "page" })?.value
            XCTAssertTrue(page == "1" || page == "2")
            return (200, page == "1" ? firstPage : secondPage)
        })
        var application = record(
            mechanism: .githubReleases, url: "https://api.github.com/repos/egoist/lorca/releases")
        application.updateConfiguration.githubReleaseTagPrefix = "desktop-v"
        let checked = await provider.check(application)
        XCTAssertEqual(checked.latestVersion, "1.2.0")
        XCTAssertEqual(checked.status, .updateAvailable)
    }

    func testMissingDesktopChannelDoesNotFallBackToCLILatest() async throws {
        let data = try json([release("cli-v9.0.0")])
        let provider = GitHubReleasesUpdateProvider(fetchResponse: { url in
            XCTAssertFalse(url.path.hasSuffix("/latest"))
            return (200, data)
        })
        var application = record(
            mechanism: .githubReleases, url: "https://api.github.com/repos/egoist/lorca/releases")
        application.updateConfiguration.githubReleaseTagPrefix = "desktop-v"
        let checked = await provider.check(application)
        guard case .unavailable = checked.status else {
            return XCTFail("Missing channel was accepted")
        }
        XCTAssertNil(checked.latestVersion)
    }

    func testDetectsAPILatestWithoutJSONFileExtension() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try bundle(
            at: directory.appendingPathComponent("Editor.app"), executable: "Editor",
            content: "go string https://example.com/api/latestanother go string")
        let detected = try XCTUnwrap(ApplicationScanner.makeRecord(from: app))
        XCTAssertEqual(detected.updateConfiguration.mechanism, .customAPI)
        XCTAssertEqual(
            detected.updateConfiguration.feedURL?.absoluteString, "https://example.com/api/latest")
    }

    func testHelperEndpointIsFoundButEscapingSymlinksAreIgnored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try bundle(
            at: directory.appendingPathComponent("Editor.app"), executable: "editor-desktop",
            content: "main")
        let helper = try bundle(
            at: app.appendingPathComponent("Contents/Helpers/EditorAgent.app"), executable: "agent",
            content: "go string https://editor.example.com/api/latest\0")
        var detected = try XCTUnwrap(ApplicationScanner.makeRecord(from: app))
        XCTAssertEqual(detected.updateConfiguration.mechanism, .customAPI)
        XCTAssertEqual(
            detected.updateConfiguration.feedURL?.absoluteString,
            "https://editor.example.com/api/latest")
        let executable = helper.appendingPathComponent("Contents/MacOS/agent")
        try FileManager.default.moveItem(
            at: executable, to: directory.appendingPathComponent("outside"))
        try FileManager.default.createSymbolicLink(
            at: executable, withDestinationURL: directory.appendingPathComponent("outside"))
        detected = try XCTUnwrap(ApplicationScanner.makeRecord(from: app))
        XCTAssertEqual(detected.updateConfiguration.mechanism, .selfManaged)
    }

    func testInstalledApplicationsUseExpectedUpdateProtocolsWhenPresent() throws {
        for (name, mechanism, host) in [
            ("magpie", UpdateMechanism.customAPI, "usemagpie.ai"),
            ("Lorca", .githubReleases, "api.github.com"),
            ("FluxDown", .customAPI, "fluxdown.com"),
            ("WorkBuddy", .customAPI, "www.workbuddy.cn"),
            ("WorkBuddy AI", .customAPI, "www.workbuddy.ai"),
            ("ZCode", .electronBuilder, "zcode.z.ai"),
            ("GigaMoney", .electronBuilder, "download.longbridgewhale.com"),
            ("Clash Verge Ninja", .tauri, "github.com"),
        ] {
            let url = URL(fileURLWithPath: "/Applications/\(name).app")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let detected = try XCTUnwrap(ApplicationScanner.makeRecord(from: url))
            XCTAssertEqual(detected.updateConfiguration.mechanism, mechanism, name)
            XCTAssertEqual(detected.updateConfiguration.feedURL?.host, host, name)
            if name == "Clash Verge Ninja" {
                XCTAssertEqual(detected.updateConfiguration.identifier, "rule:clash-verge-rev")
            }
            if name == "Lorca" {
                XCTAssertEqual(detected.updateConfiguration.githubReleaseTagPrefix, "desktop-v")
            }
        }
    }

    private func record(mechanism: UpdateMechanism, url: String) -> AppRecord {
        AppRecord(
            name: "Editor",
            bundleIdentifier: "com.example.editor",
            applicationURL: URL(fileURLWithPath: "/Applications/Editor.app"),
            currentVersion: "1.0",
            updateConfiguration: UpdateConfiguration(
                mechanism: mechanism, feedURL: URL(string: url)),
            status: .checking
        )
    }

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func release(_ tag: String, prerelease: Bool = false, draft: Bool = false) -> [String:
        Any]
    {
        [
            "tag_name": tag, "body": tag, "prerelease": prerelease, "draft": draft,
            "assets": [
                [
                    "name": "Editor-macos-arm64.dmg",
                    "browser_download_url": "https://example.com/Editor.dmg",
                ]
            ],
        ]
    }

    @discardableResult
    private func bundle(at url: URL, executable: String, content: String) throws -> URL {
        let contents = url.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleName": url.deletingPathExtension().lastPathComponent,
            "CFBundleIdentifier": "com.example.\(executable)", "CFBundleShortVersionString": "1.0",
            "CFBundleExecutable": executable, "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let binary = macOS.appendingPathComponent(executable)
        try Data(content.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return url
    }
}
