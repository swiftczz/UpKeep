import Foundation
import XCTest

@testable import Upkeep

final class CraftReleaseDiscoveryTests: XCTestCase {
    func testNewCraftApplicationUsesExistingReleaseRequestAndDesktopPackage() async throws {
        let application = try makeApplication()
        let network = ReleaseResponses([
            .response(
                200,
                releaseData(assets: [
                    "futurecraft-cli-1.0.0-macos-universal.zip",
                    "futurecraft-web-1.0.0.zip", "futurecraft-server-1.0.0-macos-arm64.tar.gz",
                    "futurecraft-1.0.0-macos-universal.dmg",
                ]))
        ])
        let provider = provider(network: network)

        let checked = await provider.check(application)

        XCTAssertEqual(checked.latestVersion, "1.0.0")
        XCTAssertEqual(checked.releaseNotes, "New desktop features")
        XCTAssertEqual(checked.status, .updateAvailable)
        XCTAssertTrue(checked.canAutomaticallyUpdate)
        let requests = await network.requests
        XCTAssertEqual(requests, [application.updateConfiguration.feedURL!])
    }

    func testOnlyDesktopAssetsFromTheMatchingRepositoryAreInstallable() async throws {
        for (assets, repository) in [
            (
                ["futurecraft-web-1.0.0.zip", "futurecraft-cli-1.0.0-macos-universal.zip"],
                "storytold/futurecraft"
            ),
            (["futurecraft-server-1.0.0-macos-universal.dmg"], "storytold/futurecraft"),
            (
                ["futurecraft-1.0.0-windows-x64.zip", "futurecraft-1.0.0-linux-aarch64.tar.gz"],
                "storytold/futurecraft"
            ),
            (["futurecraft-1.0.0-macos-universal.dmg"], "someone-else/futurecraft"),
            (["anothercraft-1.0.0-macos-universal.dmg"], "storytold/futurecraft"),
        ] {
            let network = ReleaseResponses([
                .response(200, releaseData(assets: assets, repository: repository))
            ])
            let checked = await provider(network: network).check(try makeApplication())
            XCTAssertFalse(checked.canAutomaticallyUpdate, "\(assets) in \(repository)")
        }
    }

    func testMissingReleaseIsCachedUntilExpiryThenNewReleaseIsDiscovered() async throws {
        let clock = DiscoveryClock()
        let cache = GitHubMissingReleaseCache(now: { clock.now })
        let network = ReleaseResponses([
            .response(404, Data()),
            .response(200, releaseData(assets: ["futurecraft-1.0.0-macos-universal.dmg"])),
        ])
        let provider = provider(network: network, cache: cache)
        let application = try makeApplication()

        let missing = await provider.check(application)
        XCTAssertFalse(missing.canAutomaticallyUpdate)
        guard case .unavailable(let message) = missing.status else {
            return XCTFail("Missing release was accepted")
        }
        XCTAssertTrue(message.contains("404"))
        _ = await provider.check(application)
        let beforeExpiry = await network.requests
        XCTAssertEqual(beforeExpiry.count, 1)

        clock.advance(by: GitHubMissingReleaseCache.lifetime + 1)
        let checked = await provider.check(missing)
        XCTAssertTrue(checked.canAutomaticallyUpdate)
        let afterExpiry = await network.requests
        XCTAssertEqual(afterExpiry.count, 2)
        let stillMissing = await cache.contains(application.updateConfiguration.feedURL!)
        XCTAssertFalse(stillMissing)
    }

    func testManualInvalidationRechecksBeforeExpiry() async throws {
        let network = ReleaseResponses([
            .response(404, Data()),
            .response(200, releaseData(assets: ["futurecraft-1.0.0-macos-universal.dmg"])),
        ])
        let provider = provider(network: network)
        let application = try makeApplication()
        _ = await provider.check(application)
        await provider.invalidateMissingReleaseCache()
        let checked = await provider.check(application)
        XCTAssertEqual(checked.status, .updateAvailable)
        let requests = await network.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testTransientAndRateLimitFailuresAreNotCachedOrTreatedAsMissingRepositories() async throws
    {
        for failure in [ReleaseResponses.Step.response(403, Data()), .failure(.timedOut)] {
            let network = ReleaseResponses([
                failure,
                .response(200, releaseData(assets: ["futurecraft-1.0.0-macos-universal.dmg"])),
            ])
            let provider = provider(network: network)
            let application = try makeApplication()
            var previous = application
            previous.releaseNotes = "Previously fetched notes"
            let failed = await provider.check(previous)
            XCTAssertEqual(failed.releaseNotes, previous.releaseNotes)
            let checked = await provider.check(failed)
            XCTAssertTrue(checked.canAutomaticallyUpdate)
            let requests = await network.requests
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testMissingCacheDoesNotChangeOtherGitHubApplications() async throws {
        var application = try makeApplication()
        application = AppRecord(
            name: application.name,
            bundleIdentifier: "com.example.futurecraft",
            applicationURL: application.applicationURL,
            currentVersion: application.currentVersion,
            updateConfiguration: UpdateConfiguration(
                mechanism: .githubReleases, feedURL: application.updateConfiguration.feedURL)
        )
        let network = ReleaseResponses([.response(404, Data()), .response(404, Data())])
        let provider = provider(network: network)
        _ = await provider.check(application)
        _ = await provider.check(application)
        let requests = await network.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testCancelledLookupDoesNotCacheAMissingRelease() async throws {
        let cache = GitHubMissingReleaseCache()
        let provider = GitHubReleasesUpdateProvider(
            fetchResponse: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return (404, Data())
            },
            missingReleaseCache: cache
        )
        let application = try makeApplication()
        let task = Task { await provider.check(application) }
        let result = await task.value
        XCTAssertEqual(result.status, application.status)
        let cached = await cache.contains(application.updateConfiguration.feedURL!)
        XCTAssertFalse(cached)
    }

    func testMissingCacheSurvivesRestartAndExpires() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CraftCacheTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cache.json")
        let url = try XCTUnwrap(
            KnownGitHubReleaseSources.metadata(for: "ai.storyteller.futurecraft")?.apiURL)
        let clock = DiscoveryClock()
        let cache = GitHubMissingReleaseCache(fileURL: file, now: { clock.now })
        await cache.remember(url)
        let restored = GitHubMissingReleaseCache(fileURL: file, now: { clock.now })
        let found = await restored.contains(url)
        XCTAssertTrue(found)
        clock.advance(by: GitHubMissingReleaseCache.lifetime + 1)
        let expired = await restored.contains(url)
        XCTAssertFalse(expired)
    }

    private func makeApplication() throws -> AppRecord {
        let metadata = try XCTUnwrap(
            KnownGitHubReleaseSources.metadata(for: "ai.storyteller.futurecraft"))
        return AppRecord(
            name: "A localized application name",
            bundleIdentifier: "ai.storyteller.futurecraft",
            applicationURL: URL(fileURLWithPath: "/nonexistent/FutureCraft.app"),
            currentVersion: "0.9.0",
            updateConfiguration: UpdateConfiguration(
                mechanism: .githubReleases, feedURL: metadata.apiURL,
                identifier: metadata.identifier)
        )
    }

    private func provider(
        network: ReleaseResponses, cache: GitHubMissingReleaseCache = GitHubMissingReleaseCache()
    ) -> GitHubReleasesUpdateProvider {
        GitHubReleasesUpdateProvider(
            fetchResponse: { try await network.response(for: $0) },
            fetchData: { _ in
                XCTFail("No extra discovery or checksum requests expected")
                return nil
            },
            missingReleaseCache: cache
        )
    }

    private func releaseData(assets: [String], repository: String = "storytold/futurecraft") -> Data
    {
        try! JSONSerialization.data(withJSONObject: [
            "tag_name": "v1.0.0", "body": "New desktop features",
            "html_url": "https://github.com/\(repository)/releases/tag/v1.0.0",
            "assets": assets.map { name in
                [
                    "name": name,
                    "browser_download_url":
                        "https://github.com/\(repository)/releases/download/v1.0.0/\(name)",
                ]
            },
        ])
    }
}

private actor ReleaseResponses {
    enum Step: Sendable {
        case response(Int, Data)
        case failure(URLError.Code)
    }
    private var steps: [Step]
    private(set) var requests: [URL] = []
    init(_ steps: [Step]) { self.steps = steps }
    func response(for url: URL) throws -> (statusCode: Int, data: Data)? {
        requests.append(url)
        guard !steps.isEmpty else { throw URLError(.badServerResponse) }
        switch steps.removeFirst() {
        case .response(let status, let data): return (status, data)
        case .failure(let code): throw URLError(code)
        }
    }
}

private final class DiscoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)
    var now: Date { lock.withLock { date } }
    func advance(by seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}
