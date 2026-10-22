import Foundation
import XCTest

@testable import Upkeep

final class UpdateSourceRuleTests: XCTestCase {
    func testBuiltInRulesDecodeAndValidate() {
        XCTAssertFalse(UpdateSourceRuleSet.builtIn.rules.isEmpty)
        XCTAssertEqual(UpdateSourceRuleSet.builtIn.issues, [])
    }

    func testFieldPathsAcceptOnePathOrAlternatives() throws {
        let rule = try decodeRule(
            #"""
            {"id": "editor", "kind": "jsonFeed", "match": {"bundleIdentifier": "com.example.editor"},
             "feed": "https://example.com/latest.json",
             "fields": {"version": "release.version", "notes": ["notes.zh-CN", "notes.en"]}}
            """#)
        XCTAssertEqual(rule.fields?.version.paths, ["release.version"])
        XCTAssertEqual(rule.fields?.notes?.paths, ["notes.zh-CN", "notes.en"])
        XCTAssertEqual(rule.effectivePrecedence, .beforeHeuristics)
    }

    func testInvalidRulesAreReportedAndSkipped() {
        let valid = jsonRule(id: "valid")
        var badID = jsonRule(id: "Bad ID")
        badID.id = "Bad ID"
        var bothMatches = jsonRule(id: "both")
        bothMatches.match.bundleIdentifierPattern = "com\\.example\\..*"
        var insecureFeed = jsonRule(id: "insecure")
        insecureFeed.feed = "http://example.com/latest.json"
        var unknownPlaceholder = jsonRule(id: "placeholder")
        unknownPlaceholder.feed = "https://example.com/{channel}.json"
        var missingVersion = jsonRule(id: "no-version")
        missingVersion.fields = nil
        let badRepository = UpdateSourceRule(
            id: "repository", kind: .githubReleases,
            match: .init(bundleIdentifier: "com.example.editor"), repository: "example")

        let rules = UpdateSourceRuleSet(rules: [
            valid, badID, bothMatches, insecureFeed, unknownPlaceholder, missingVersion,
            badRepository, valid,
        ])

        XCTAssertEqual(rules.rules.map(\.id), ["valid"])
        XCTAssertEqual(rules.issues.count, 7)
        XCTAssertTrue(rules.issues.last?.message.contains("重复") ?? false)
    }

    func testPatternMustMatchWholeIdentifierAndExposesNamedGroups() throws {
        let rule = UpdateSourceRule(
            id: "suite", kind: .githubReleases,
            match: .init(bundleIdentifierPattern: #"com\.example\.(?<slug>[a-z]+)"#),
            repository: "example/{slug}", assetNamePrefix: "{slug}-")
        let rules = UpdateSourceRuleSet(rules: [rule])

        let match = try XCTUnwrap(rules.firstMatch(for: "com.example.editor"))
        XCTAssertEqual(match.captures, ["slug": "editor"])
        for identifier in [
            "com.example.editor\n", "com.example.editor.beta", "org.com.example.editor",
            "COM.EXAMPLE.EDITOR",
        ] {
            XCTAssertNil(rules.firstMatch(for: identifier), identifier)
        }

        let metadata = try XCTUnwrap(rules.gitHubReleasesMetadata(for: "com.example.editor"))
        XCTAssertEqual(metadata.identifier, "example/editor")
        XCTAssertEqual(
            metadata.apiURL.absoluteString,
            "https://api.github.com/repos/example/editor/releases/latest")
        XCTAssertEqual(match.assetNamePrefix(values: match.captures), "editor-")
    }

    func testTemplateValuesCannotAddPathSegmentsOrQueryItems() throws {
        var rule = jsonRule(id: "editor")
        rule.feed = "https://example.com/update/{arch}?version={version}"
        let match = try XCTUnwrap(
            UpdateSourceRuleSet(rules: [rule]).firstMatch(for: "com.example.editor"))

        let url = try XCTUnwrap(
            match.feedURL(
                values: match.values(
                    version: "1.0 beta/2&x=1", build: nil, bundleIdentifier: "com.example.editor",
                    architecture: .arm64)))

        XCTAssertEqual(
            url.absoluteString, "https://example.com/update/arm64?version=1.0%20beta%2F2%26x%3D1")
        XCTAssertNil(match.feedURL(values: [:]))
    }

    func testStoreLoadsUserFilesOverridesBuiltInsAndReportsBrokenFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write(
            #"""
            [{"id": "storyteller-craft", "kind": "githubReleases",
              "match": {"bundleIdentifier": "ai.storyteller.photocraft"},
              "repository": "fork/photocraft"},
             {"id": "editor", "kind": "jsonFeed", "match": {"bundleIdentifier": "com.example.editor"},
              "feed": "https://example.com/latest.json", "fields": {"version": "version"}}]
            """#, to: directory.appendingPathComponent("a.json"))
        try write("{not json", to: directory.appendingPathComponent("b.json"))
        try write(
            #"{"id": "missing", "kind": "jsonFeed", "feed": "https://example.com"}"#,
            to: directory.appendingPathComponent("c.json"))
        try write("ignored", to: directory.appendingPathComponent("notes.txt"))

        let rules = UpdateSourceRuleStore(directory: directory).current()

        XCTAssertEqual(
            rules.gitHubReleasesMetadata(for: "ai.storyteller.photocraft")?.identifier,
            "fork/photocraft")
        // Reusing a built-in id replaces that rule entirely.
        XCTAssertNil(rules.gitHubReleasesMetadata(for: "ai.storyteller.vectorcraft"))
        XCTAssertNotNil(rules.firstMatch(for: "com.example.editor"))
        XCTAssertEqual(
            rules.issues,
            [
                .init(source: "b.json", message: "不是有效的 JSON。"),
                .init(source: "c.json", message: "缺少字段 match。"),
            ])
    }

    func testStoreReloadsWhenRuleFilesChange() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UpdateSourceRuleStore(directory: directory, builtIn: .empty)
        XCTAssertTrue(store.current().rules.isEmpty)

        let file = directory.appendingPathComponent("editor.json")
        try write(try encode(jsonRule(id: "editor")), to: file)
        XCTAssertEqual(store.current().rules.map(\.id), ["editor"])

        try write(try encode([jsonRule(id: "editor"), jsonRule(id: "viewer")]), to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        XCTAssertEqual(store.current().rules.map(\.id), ["editor", "viewer"])
    }

    func testUpdaterFeedRulesHandTheirFeedToTheNamedUpdater() throws {
        for format in UpdateSourceRule.Format.allCases {
            let rule = UpdateSourceRule(
                id: "updater", kind: .updaterFeed,
                match: .init(bundleIdentifier: "com.example.editor"), format: format,
                feed: "https://example.com/{version}/feed",
                homepage: "https://example.com/download")
            let match = try XCTUnwrap(
                UpdateSourceRuleSet(rules: [rule]).firstMatch(for: "com.example.editor"))

            let configuration = try XCTUnwrap(
                match.configuration(
                    values: match.values(
                        version: "1.2", build: nil, bundleIdentifier: "com.example.editor")))

            XCTAssertEqual(configuration.mechanism, format.mechanism)
            XCTAssertEqual(configuration.identifier, "rule:updater")
            XCTAssertEqual(configuration.feedURL?.absoluteString, "https://example.com/1.2/feed")
            XCTAssertEqual(configuration.homepageURL?.absoluteString, "https://example.com/download")
            XCTAssertTrue(configuration.isRuleAssigned)
        }

        let missingFormat = UpdateSourceRule(
            id: "no-format", kind: .updaterFeed,
            match: .init(bundleIdentifier: "com.example.editor"),
            feed: "https://example.com/latest-mac.yml")
        var insecure = missingFormat
        insecure.id = "insecure"
        insecure.format = .electronBuilder
        insecure.feed = "http://example.com/latest-mac.yml"
        let rules = UpdateSourceRuleSet(rules: [missingFormat, insecure])
        XCTAssertTrue(rules.rules.isEmpty)
        XCTAssertEqual(rules.issues.count, 2)
        XCTAssertTrue(rules.issues[0].message.contains("format"), rules.issues[0].message)
    }

    func testAiCoinUsesItsElectronBuilderFeedSetInCode() throws {
        let url = try makeApplication(bundleIdentifier: "com.aicoin.desktop", version: "2.16.27")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let resources = url.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try write(
            "provider: custom\nupdaterCacheDirName: aicoin-updater\n",
            to: resources.appendingPathComponent("app-update.yml"))

        for record in [
            ApplicationScanner.makeRecord(from: url),
            ApplicationScanner.makeRecord(from: url, sourceDetection: .installedOnly),
        ] {
            let configuration = try XCTUnwrap(record).updateConfiguration
            XCTAssertEqual(configuration.mechanism, .electronBuilder)
            XCTAssertEqual(configuration.identifier, "rule:aicoin")
            XCTAssertEqual(
                configuration.feedURL?.absoluteString,
                "https://pc-package-1326437257.cos.ap-hongkong.myqcloud.com/download/latest-mac.yml")
            XCTAssertEqual(configuration.channel, .website)
        }
    }

    func testAiCoinManifestSelectsThePackageForEachArchitecture() throws {
        let feed = try XCTUnwrap(
            URL(string: "https://pc-package-1326437257.cos.ap-hongkong.myqcloud.com/download/latest-mac.yml"))
        let manifest = try XCTUnwrap(
            ElectronBuilderYAML.parseManifest(
                """
                version: 2.16.28
                files:
                  - url: AiCoin-2.16.28-mac.zip
                    sha512: x64zip
                    size: 259854189
                  - url: AiCoin-2.16.28-arm64-mac.zip
                    sha512: arm64zip
                    size: 256982598
                  - url: AiCoin-2.16.28-arm64-mac.zip
                    sha512: arm64zip
                    size: 256982598
                  - url: AiCoin-2.16.28.dmg
                    sha512: x64dmg
                    size: 265515893
                  - url: AiCoin-2.16.28-arm64.dmg
                    sha512: arm64dmg
                    size: 262636508
                path: AiCoin-2.16.28-mac.zip
                sha512: x64zip
                releaseDate: '2026-10-13T08:45:00.000Z'
                """))

        XCTAssertEqual(manifest.version, "2.16.28")
        let arm64 = try XCTUnwrap(manifest.selectedPackage(relativeTo: feed, architecture: .arm64))
        XCTAssertEqual(arm64.url.lastPathComponent, "AiCoin-2.16.28-arm64-mac.zip")
        XCTAssertEqual(arm64.sha512, "arm64zip")
        XCTAssertEqual(
            arm64.url.deletingLastPathComponent().absoluteString,
            "https://pc-package-1326437257.cos.ap-hongkong.myqcloud.com/download/")
        let x64 = try XCTUnwrap(manifest.selectedPackage(relativeTo: feed, architecture: .x64))
        XCTAssertEqual(x64.url.lastPathComponent, "AiCoin-2.16.28-mac.zip")
    }

    func testRulesOutrankAnEmbeddedSparkleFrameworkButNotADeclaredFeed() throws {
        let url = try makeApplication(bundleIdentifier: "com.example.editor", version: "1.4")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Contents/Frameworks/Sparkle.framework"),
            withIntermediateDirectories: true)
        let rule = UpdateSourceRule(
            id: "editor", kind: .updaterFeed,
            match: .init(bundleIdentifier: "com.example.editor"), format: .sparkle,
            feed: "https://example.com/appcast.xml")
        let rules = UpdateSourceRuleSet(rules: [rule])

        let unassigned = try XCTUnwrap(ApplicationScanner.makeRecord(from: url, rules: .empty))
        XCTAssertEqual(unassigned.updateConfiguration.mechanism, .sparkle)
        XCTAssertNil(unassigned.updateConfiguration.feedURL)
        XCTAssertEqual(unassigned.status, .selfManaged)

        let assigned = try XCTUnwrap(ApplicationScanner.makeRecord(from: url, rules: rules))
        XCTAssertEqual(assigned.updateConfiguration.identifier, "rule:editor")
        XCTAssertEqual(
            assigned.updateConfiguration.feedURL?.absoluteString, "https://example.com/appcast.xml")
        XCTAssertEqual(assigned.status, .checking)
        let reused = try XCTUnwrap(
            ApplicationScanner.makeRecord(from: url, sourceDetection: .installedOnly, rules: rules))
        XCTAssertEqual(reused.updateConfiguration, assigned.updateConfiguration)

        // Once the vendor declares a feed in Info.plist, the cached rule route is replaced.
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        var info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil)
                as? [String: Any])
        info["SUFeedURL"] = "https://vendor.example.com/appcast.xml"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: infoURL)
        let declared = try XCTUnwrap(
            ApplicationScanner.makeRecord(from: url, reusing: assigned, rules: rules))
        XCTAssertEqual(
            declared.updateConfiguration.feedURL?.absoluteString,
            "https://vendor.example.com/appcast.xml")
        XCTAssertFalse(declared.updateConfiguration.isRuleAssigned)
    }

    func testInstallerRequiresASignedMatchingDeveloperForRuleSources() {
        let ruleSource = UpdateConfiguration(
            mechanism: .electronBuilder, feedURL: URL(string: "https://example.com/latest-mac.yml"),
            identifier: "rule:editor")
        let declaredSource = UpdateConfiguration(
            mechanism: .electronBuilder, feedURL: URL(string: "https://example.com/latest-mac.yml"),
            identifier: "https://example.com")

        let signedInstall = ApplicationPackageInstaller.signatureRequirements(
            for: ruleSource, requiresValidSignature: false, requiresTeamIdentifier: false,
            installedTeamIdentifier: { "R4A6UKF8S5" })
        XCTAssertTrue(signedInstall.requiresValidSignature)
        XCTAssertTrue(signedInstall.requiresTeamIdentifier)

        let unsignedInstall = ApplicationPackageInstaller.signatureRequirements(
            for: ruleSource, requiresValidSignature: false, requiresTeamIdentifier: false,
            installedTeamIdentifier: { nil })
        XCTAssertTrue(unsignedInstall.requiresValidSignature)
        XCTAssertFalse(unsignedInstall.requiresTeamIdentifier)

        let declared = ApplicationPackageInstaller.signatureRequirements(
            for: declaredSource, requiresValidSignature: false, requiresTeamIdentifier: false,
            installedTeamIdentifier: {
                XCTFail("Declared sources keep their provider's policy")
                return nil
            })
        XCTAssertFalse(declared.requiresValidSignature)
        XCTAssertFalse(declared.requiresTeamIdentifier)

        // An installed copy signed by one developer never accepts another's build.
        XCTAssertFalse(
            ApplicationPackageInstaller.teamIdentifiersMatch(
                installed: "R4A6UKF8S5", candidate: nil,
                requiresTeamIdentifier: signedInstall.requiresTeamIdentifier,
                hasVerifiedUpdateSignature: false))
    }

    // MARK: - Parsing

    func testFluxDownReadsItsReleaseAPIWithTheBuiltInRule() throws {
        let url = try makeApplication(bundleIdentifier: "com.fluxdown.app", version: "0.6.0")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let configuration = try XCTUnwrap(ApplicationScanner.makeRecord(from: url))
            .updateConfiguration
        XCTAssertEqual(configuration.mechanism, .customAPI)
        XCTAssertEqual(configuration.identifier, "rule:fluxdown")
        let feed = try XCTUnwrap(configuration.feedURL)
        XCTAssertEqual(feed.absoluteString, "https://fluxdown.com/api/release?channel=stable")

        let fields = try XCTUnwrap(
            UpdateSourceRuleSet.builtIn.match(
                configurationIdentifier: configuration.identifier,
                bundleIdentifier: "com.fluxdown.app")?.rule.fields)

        func asset(_ name: String) -> [String: Any] {
            [
                "name": name, "size": 42,
                "github_download_url":
                    "https://github.com/zerx-lab/FluxDown/releases/download/v0.6.1/\(name)",
                "download_url": "/api/download/\(name)",
            ]
        }
        let release = try XCTUnwrap(
            RuleJSONReleaseParser(fields: fields).parse(
                try json([
                    "version": "0.6.1",
                    "published_at": "2026-10-22T07:14:29Z",
                    "assets": [
                        "setup": asset("FluxDown-0.6.1-windows-x64-setup.exe"),
                        "extension": asset("FluxDown-0.6.1-chrome.zip"),
                        "macos_dmg_arm64": asset("FluxDown-0.6.1-macos-arm64.dmg"),
                        "macos_dmg_x64": asset("FluxDown-0.6.1-macos-x64.dmg"),
                        "macos_tarball_arm64": asset("FluxDown-0.6.1-macos-arm64.tar.gz"),
                    ],
                ]), sourceURL: feed))

        XCTAssertEqual(release.version, "0.6.1")
        XCTAssertNotNil(release.publicationDate)
        let arm64 = try XCTUnwrap(release.selectedPackage(architecture: .arm64))
        XCTAssertEqual(arm64.name, "FluxDown-0.6.1-macos-arm64.dmg")
        XCTAssertEqual(
            arm64.url.absoluteString,
            "https://fluxdown.com/api/download/FluxDown-0.6.1-macos-arm64.dmg")
        XCTAssertEqual(arm64.size, 42)
        XCTAssertEqual(
            release.selectedPackage(architecture: .x64)?.name, "FluxDown-0.6.1-macos-x64.dmg")
    }

    func testRuleParserReadsOnlyTheNamedFields() throws {
        let fields = UpdateSourceRule.Fields(
            version: ["release.tag", "release.version"],
            notes: ["release.notes.zh-CN", "release.notes.en"],
            notesURL: "release.page",
            date: "release.time",
            assets: "release.files",
            assetURL: ["href", "url"],
            assetName: "file",
            assetSHA256: "sum",
            assetSize: "bytes")
        let data = try json([
            "version": "9.9.9",
            "release": [
                "version": "v2.1.0",
                "notes": ["zh-CN": "  ", "en": "Fixes"],
                "page": "https://example.com/releases/2.1.0",
                "time": 1_700_000_000_000,
                "files": [
                    ["file": "Editor-arm64.dmg", "href": "/download/arm64", "sum": "abc", "bytes": 42],
                    ["url": "//evil.example.net/Editor.dmg"],
                    ["url": "http://example.com/Editor.dmg"],
                    ["url": "https://other.example.com/Editor-x64.zip"],
                ],
            ],
        ])

        let release = try XCTUnwrap(
            RuleJSONReleaseParser(fields: fields).parse(
                data, sourceURL: URL(string: "https://example.com/api/update")))

        XCTAssertEqual(release.version, "2.1.0")
        XCTAssertEqual(release.notes, "Fixes")
        XCTAssertEqual(release.releaseURL?.absoluteString, "https://example.com/releases/2.1.0")
        XCTAssertEqual(release.publicationDate, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(
            release.assets.map(\.url.absoluteString),
            ["https://example.com/download/arm64", "https://other.example.com/Editor-x64.zip"])
        XCTAssertEqual(release.assets.first?.name, "Editor-arm64.dmg")
        XCTAssertEqual(release.assets.first?.sha256, "abc")
        XCTAssertEqual(release.assets.first?.size, 42)
    }

    func testRuleParserAcceptsKeyedAssetsOrTheResponseItself() throws {
        let keyed = try XCTUnwrap(
            RuleJSONReleaseParser(fields: .init(version: "version", assets: "downloads")).parse(
                try json([
                    "version": "3.0",
                    "downloads": [
                        "Editor-mac-arm64.zip": ["url": "https://example.com/a.zip"],
                        "Editor-mac-x64.zip": ["url": "https://example.com/b.zip"],
                    ],
                ])))
        XCTAssertEqual(keyed.assets.map(\.name), ["Editor-mac-arm64.zip", "Editor-mac-x64.zip"])
        XCTAssertEqual(keyed.selectedPackage(architecture: .arm64)?.name, "Editor-mac-arm64.zip")

        let single = try XCTUnwrap(
            RuleJSONReleaseParser(fields: .init(version: "v")).parse(
                try json(["v": 4, "url": "https://example.com/Editor.dmg"])))
        XCTAssertEqual(single.version, "4")
        XCTAssertEqual(single.assets.map(\.name), ["Editor.dmg"])

        XCTAssertNil(
            RuleJSONReleaseParser(fields: .init(version: "missing")).parse(try json(["v": 1])))
    }

    // MARK: - Detection

    func testJSONRuleOutranksHeuristicsButNotADeclaredSparkleFeed() throws {
        let url = try makeApplication(bundleIdentifier: "com.example.editor", version: "1.4")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var rule = jsonRule(id: "editor")
        rule.feed = "https://example.com/update?version={version}"
        let rules = UpdateSourceRuleSet(rules: [rule])

        for record in [
            ApplicationScanner.makeRecord(from: url, rules: rules),
            ApplicationScanner.makeRecord(from: url, sourceDetection: .installedOnly, rules: rules),
        ] {
            let record = try XCTUnwrap(record)
            XCTAssertEqual(record.updateConfiguration.mechanism, .customAPI)
            XCTAssertEqual(record.updateConfiguration.identifier, "rule:editor")
            XCTAssertEqual(
                record.updateConfiguration.feedURL?.absoluteString,
                "https://example.com/update?version=1.4")
            XCTAssertEqual(record.status, .checking)
        }

        let sparkle = try makeApplication(
            bundleIdentifier: "com.example.editor", version: "1.4",
            extraInfo: ["SUFeedURL": "https://example.com/appcast.xml"])
        defer { try? FileManager.default.removeItem(at: sparkle.deletingLastPathComponent()) }
        XCTAssertEqual(
            ApplicationScanner.makeRecord(from: sparkle, rules: rules)?.updateConfiguration
                .mechanism,
            .sparkle)
    }

    func testAddingOrRemovingARuleReplacesTheCachedSource() throws {
        let url = try makeApplication(bundleIdentifier: "com.example.editor", version: "1.4")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rules = UpdateSourceRuleSet(rules: [jsonRule(id: "editor")])
        let unknown = try XCTUnwrap(
            ApplicationScanner.makeRecord(from: url, sourceDetection: .installedOnly, rules: .empty))
        XCTAssertEqual(unknown.updateConfiguration.mechanism, .selfManaged)

        let added = try XCTUnwrap(
            ApplicationScanner.makeRecord(from: url, reusing: unknown, rules: rules))
        XCTAssertEqual(added.updateConfiguration.identifier, "rule:editor")

        let removed = try XCTUnwrap(
            ApplicationScanner.makeRecord(from: url, reusing: added, rules: .empty))
        XCTAssertEqual(removed.updateConfiguration.mechanism, .selfManaged)

        let unchanged = try XCTUnwrap(
            ApplicationScanner.makeRecord(from: url, reusing: added, rules: rules))
        XCTAssertEqual(unchanged.applicationModificationDate, added.applicationModificationDate)
        XCTAssertEqual(unchanged.updateConfiguration, added.updateConfiguration)
    }

    func testCustomDetectorsRunInRegistryOrder() throws {
        let url = try makeApplication(bundleIdentifier: "com.example.editor", version: "1.4")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let registry = UpdateSourceRegistry(
            providers: [],
            detectors: [
                FixedDetector(identifier: "first", matches: false),
                FixedDetector(identifier: "second", matches: true),
                FixedDetector(identifier: "third", matches: true),
            ])

        let record = try XCTUnwrap(
            ApplicationScanner.makeRecord(from: url, rules: .empty, registry: registry))

        XCTAssertEqual(record.updateConfiguration.identifier, "second")
    }

    // MARK: - Providers

    func testRuleFeedFollowsTheInstalledVersionAndUsesRuleFields() async throws {
        var rule = jsonRule(id: "editor", name: "Example Editor")
        rule.feed = "https://example.com/update?version={version}&arch={arch}"
        rule.fields = .init(version: "latest", notes: "changes", assets: "files")
        let rules = UpdateSourceRuleSet(rules: [rule])
        let response = try json([
            "latest": "2.0.0", "changes": "New editor",
            "files": [["url": "https://example.com/Editor-2.0.0-mac.zip"]],
        ])
        let requested = RequestLog()
        let provider = CustomAPIUpdateProvider(
            fetchResponse: { url in
                await requested.append(url)
                return (200, response)
            },
            rules: { rules })
        var application = makeRecord(version: "1.5")
        application.updateConfiguration.feedURL = URL(string: "https://example.com/update?version=1.0")

        let checked = await provider.check(application)

        let urls = await requested.urls
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(urls.first?.absoluteString.hasPrefix(
            "https://example.com/update?version=1.5&arch=") ?? false)
        XCTAssertEqual(checked.latestVersion, "2.0.0")
        XCTAssertEqual(checked.releaseNotes, "New editor")
        XCTAssertEqual(checked.status, .updateAvailable)
        XCTAssertTrue(checked.canAutomaticallyUpdate)
    }

    func testWorkBuddyRuleSendsTheInstalledVersionAndReadsItsOnePackage() async throws {
        let response = try json([
            "version": "5.8.4.41366630",
            "url":
                "https://download.codebuddy.cn/workbuddy/saas/darwin-arm64/WorkBuddy-darwin-arm64-5.8.4.41366630-73952edb.zip",
            "sha256hash": "8404d7ee", "timestamp": 1_792_089_830, "name": "",
        ])
        let requested = RequestLog()
        let provider = CustomAPIUpdateProvider(
            fetchResponse: { url in
                await requested.append(url)
                return url.query?.contains("version=5.8.4") == true ? (204, Data()) : (200, response)
            },
            rules: { .builtIn })
        var application = AppRecord(
            name: "WorkBuddy",
            bundleIdentifier: "com.tencent.workbuddy.mac",
            applicationURL: URL(fileURLWithPath: "/nonexistent/WorkBuddy.app"),
            currentVersion: "5.8.3",
            updateConfiguration: UpdateConfiguration(
                mechanism: .customAPI, identifier: "rule:workbuddy"))

        let checked = await provider.check(application)
        let urls = await requested.urls
        XCTAssertEqual(urls.first?.host, "www.workbuddy.cn")
        XCTAssertTrue(urls.first?.query?.hasSuffix("version=5.8.3") ?? false)
        XCTAssertTrue(urls.first?.query?.hasPrefix("platform=workbuddy-darwin-") ?? false)
        XCTAssertEqual(checked.latestVersion, "5.8.4.41366630")
        XCTAssertEqual(checked.status, .updateAvailable)
        XCTAssertTrue(checked.canAutomaticallyUpdate)

        application.currentVersion = "5.8.4"
        let current = await provider.check(application)
        XCTAssertEqual(current.status, .upToDate)
    }

    func testMissingRuleEndpointIsReportedWithoutChangingProtocol() async throws {
        let rules = UpdateSourceRuleSet(rules: [jsonRule(id: "editor", name: "Example Editor")])
        let provider = CustomAPIUpdateProvider(
            fetchResponse: { _ in (404, Data()) }, rules: { rules })

        let checked = await provider.check(makeRecord(version: "1.5"))

        XCTAssertEqual(checked.updateConfiguration.mechanism, .customAPI)
        guard case .unavailable(let message) = checked.status else {
            return XCTFail("Expected an unavailable status, got \(checked.status)")
        }
        XCTAssertTrue(message.contains("Example Editor"), message)
    }

    func testCoordinatorDispatchesThroughTheRegistry() async throws {
        let calls = RequestLog()
        let registry = UpdateSourceRegistry(
            providers: [RecordingProvider(mechanism: .customAPI, calls: calls)],
            enrichers: [RenamingEnricher()])
        let coordinator = UpdateCoordinator(
            registry: registry,
            process: ApplicationProcessClient(
                isRunning: { _ in false }, quit: { _ in }, launch: { _ in }))
        let application = makeRecord(version: "1.0")

        let checked = await coordinator.check(application)
        try await coordinator.update(application) { _ in }
        let enriched = await coordinator.enrich([application], cachePolicy: .reloadIgnoringCache)

        XCTAssertEqual(checked.latestVersion, "9.0")
        XCTAssertEqual(enriched.map(\.currentVersion), ["enriched"])
        let recorded = await calls.labels
        XCTAssertEqual(recorded, ["prepare:reload", "check", "upgrade"].sorted())

        var unsupported = application
        unsupported.updateConfiguration.mechanism = .tauri
        let unchanged = await coordinator.check(unsupported)
        XCTAssertEqual(unchanged, unsupported)
        do {
            try await coordinator.update(unsupported) { _ in }
            XCTFail("Expected an unsupported source to refuse installation")
        } catch UpdateSourceError.noInstallableSource {}
    }

    func testEveryMechanismDescribesItself() {
        for mechanism in UpdateMechanism.allCases {
            XCTAssertFalse(mechanism.title.isEmpty, mechanism.rawValue)
            XCTAssertFalse(mechanism.searchTerms.isEmpty, mechanism.rawValue)
            XCTAssertFalse(mechanism.traits.installHelp.isEmpty, mechanism.rawValue)
            XCTAssertNotNil(
                UpdateSourceRegistry.standard.providers.first { $0.mechanism == mechanism },
                mechanism.rawValue)
        }
        XCTAssertFalse(UpdateConfiguration(mechanism: .sparkle).isCheckable)
        XCTAssertTrue(
            UpdateConfiguration(mechanism: .sparkle, feedURL: URL(string: "https://example.com"))
                .isCheckable)
        XCTAssertEqual(
            UpdateConfiguration(
                mechanism: .customAPI, feedURL: URL(string: "https://api.github.com/x")
            ).channel,
            .github)
    }

    // MARK: - Helpers

    private func jsonRule(id: String, name: String? = nil) -> UpdateSourceRule {
        UpdateSourceRule(
            id: id, name: name, kind: .jsonFeed,
            match: .init(bundleIdentifier: "com.example.editor"),
            feed: "https://example.com/latest.json",
            fields: .init(version: "version"))
    }

    private func makeRecord(version: String) -> AppRecord {
        AppRecord(
            name: "Editor",
            bundleIdentifier: "com.example.editor",
            applicationURL: URL(fileURLWithPath: "/nonexistent/Editor.app"),
            currentVersion: version,
            updateConfiguration: UpdateConfiguration(
                mechanism: .customAPI, feedURL: URL(string: "https://example.com/latest.json"),
                identifier: "rule:editor"))
    }

    private func decodeRule(_ text: String) throws -> UpdateSourceRule {
        try JSONDecoder().decode(UpdateSourceRule.self, from: Data(text.utf8))
    }

    private func encode(_ value: some Encodable) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "UpdateSourceRuleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func makeApplication(
        bundleIdentifier: String, version: String, extraInfo: [String: Any] = [:]
    ) throws -> URL {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("Editor.app")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": "Editor",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
        ]
        info.merge(extraInfo) { _, new in new }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }
}

private struct FixedDetector: UpdateSourceDetector {
    let identifier: String
    let matches: Bool

    func detect(_ context: UpdateSourceDetectionContext) -> DetectedUpdateSource? {
        guard matches else { return nil }
        return DetectedUpdateSource(
            UpdateConfiguration(
                mechanism: .customAPI, feedURL: URL(string: "https://example.com/latest.json"),
                identifier: identifier))
    }
}

private actor RequestLog {
    private(set) var urls: [URL] = []
    private var events: [String] = []

    var labels: [String] { events.sorted() }

    func append(_ url: URL) { urls.append(url) }
    func record(_ label: String) { events.append(label) }
}

private struct RecordingProvider: UpdateSourceProvider {
    let mechanism: UpdateMechanism
    let calls: RequestLog

    func check(_ application: AppRecord, fallbackNotes: AppRecord?) async -> AppRecord {
        await calls.record("check")
        var checked = application
        checked.latestVersion = "9.0"
        return checked
    }

    func upgrade(
        _ application: AppRecord, progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws {
        await calls.record("upgrade")
    }

    func prepareForRefresh(cachePolicy: UpdateCachePolicy) async {
        await calls.record(cachePolicy == .reloadIgnoringCache ? "prepare:reload" : "prepare")
    }
}

private struct RenamingEnricher: UpdateLibraryEnricher {
    func enrich(_ applications: [AppRecord], cachePolicy: UpdateCachePolicy) async -> [AppRecord] {
        applications.map {
            var application = $0
            application.currentVersion = "enriched"
            return application
        }
    }
}
