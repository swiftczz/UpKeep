import Foundation
import XCTest

@testable import Upkeep

@MainActor
final class AppLibraryUpdateTests: XCTestCase {
    func testInformationalSparkleUpdateOpensWebsiteWithoutInstallingOrQuitting() async throws {
        let application = AppRecord(
            name: "Resomark",
            bundleIdentifier: "com.resomark",
            applicationURL: URL(fileURLWithPath: "/Applications/Resomark.app"),
            currentVersion: "0.6.9",
            buildVersion: "1502",
            updateConfiguration: UpdateConfiguration(
                mechanism: .sparkle, feedURL: URL(string: "https://update.resomark.com/appcast.xml")
            ),
            status: .updateAvailable,
            latestVersion: "0.6.10",
            latestBuildVersion: "1503",
            updatePageURL: URL(string: "https://resomark.com/private-beta?ref=updater&from=0.6.9")
        )
        let restored = try JSONDecoder().decode(
            AppRecord.self, from: JSONEncoder().encode(application))
        XCTAssertEqual(restored.manualUpdateURL, application.updatePageURL)
        let library = try makeLibrary(
            applications: [restored], runningBundleIdentifiers: [application.bundleIdentifier]
        )
        let requiresConfirmation = await library.requiresRelaunchConfirmation(for: restored)
        XCTAssertFalse(requiresConfirmation)
        XCTAssertTrue(library.automaticUpdates.isEmpty)
        let destination = await library.performPrimaryAction(for: application.id)
        XCTAssertEqual(destination, application.updatePageURL)

        var checking = application
        checking.status = .checking
        checking.updatePageURL = nil
        let merged = try XCTUnwrap(
            AppLibrary.mergeKeepingCheckResults([checking], previous: [application]).first
        )
        XCTAssertEqual(merged.manualUpdateURL, application.updatePageURL)

        var current = application
        current.status = .upToDate
        XCTAssertNil(current.manualUpdateURL)
        current.status = .updateAvailable
        current.canAutomaticallyUpdate = true
        XCTAssertNil(current.manualUpdateURL)
        current.canAutomaticallyUpdate = false
        current.updatePageURL = URL(string: "file:///tmp/App.app")
        XCTAssertNil(current.manualUpdateURL)
    }

    func testRequiresRelaunchConfirmationWhenUpdatableApplicationIsRunning() async throws {
        let application = makeUpdateApplication(
            name: "Running", bundleIdentifier: "com.example.running")
        let library = try makeLibrary(
            applications: [application],
            runningBundleIdentifiers: ["com.example.running"]
        )

        let requiresConfirmation = await library.requiresRelaunchConfirmation(for: application)
        XCTAssertTrue(requiresConfirmation)
        let runningApplications = await library.prepareUpdateAll().runningApplications
        XCTAssertEqual(runningApplications.map(\.id), [application.id])
    }

    func testDoesNotRequireRelaunchConfirmationWhenApplicationIsNotRunning() async throws {
        let application = makeUpdateApplication(
            name: "Closed", bundleIdentifier: "com.example.closed")
        let library = try makeLibrary(
            applications: [application],
            runningBundleIdentifiers: []
        )

        let requiresConfirmation = await library.requiresRelaunchConfirmation(for: application)
        XCTAssertFalse(requiresConfirmation)
        let runningApplications = await library.prepareUpdateAll().runningApplications
        XCTAssertTrue(runningApplications.isEmpty)
    }

    func testDoesNotRequireRelaunchConfirmationWhenPrimaryActionOpensTheApp() async throws {
        let application = AppRecord(
            name: "Open",
            bundleIdentifier: "com.example.open",
            applicationURL: URL(fileURLWithPath: "/Applications/Open.app"),
            currentVersion: "1.0",
            updateConfiguration: UpdateConfiguration(mechanism: .sparkle),
            status: .upToDate
        )
        let library = try makeLibrary(
            applications: [application],
            runningBundleIdentifiers: ["com.example.open"]
        )

        let requiresConfirmation = await library.requiresRelaunchConfirmation(for: application)
        XCTAssertFalse(requiresConfirmation)
    }

    func testAutomaticUpdatesRequiringRelaunchIgnoresClosedAndIgnoredApps() async throws {
        let running = makeUpdateApplication(
            name: "Running", bundleIdentifier: "com.example.running")
        let closed = makeUpdateApplication(name: "Closed", bundleIdentifier: "com.example.closed")
        let ignored = makeUpdateApplication(
            name: "Ignored", bundleIdentifier: "com.example.ignored")
        let library = try makeLibrary(
            applications: [running, closed, ignored],
            runningBundleIdentifiers: ["com.example.running", "com.example.ignored"]
        )
        library.ignoreUpdates(for: ignored.id)

        let runningApplications = await library.prepareUpdateAll().runningApplications
        XCTAssertEqual(runningApplications.map(\.name), ["Running"])
    }

    func testIPhoneAppStoreUpdateOpensUpdatesPage() async throws {
        let application = AppRecord(
            name: "Minis",
            bundleIdentifier: "com.openminis.app",
            applicationURL: URL(fileURLWithPath: "/Applications/Minis.app"),
            currentVersion: "1.12",
            updateConfiguration: UpdateConfiguration(
                mechanism: .appStore,
                feedURL: URL(string: "https://apps.apple.com/cn/app/minis/id123456789")),
            appStorePlatform: .iPhone,
            status: .updateAvailable,
            latestVersion: "1.13",
            canAutomaticallyUpdate: false
        )
        let library = try makeLibrary(
            applications: [application],
            runningBundleIdentifiers: []
        )

        let destination = await library.performPrimaryAction(for: application.id)

        XCTAssertEqual(destination?.scheme, "macappstore")
        XCTAssertEqual(destination?.host, "showUpdatesPage")
        XCTAssertTrue(library.automaticUpdates.isEmpty)
    }

    func testAppStoreUpdateOpensUpdatesPageWhenAppStoreCountryDiffersFromAccount() async throws {
        let application = AppRecord(
            name: "Clash",
            bundleIdentifier: "com.hako.network",
            applicationURL: URL(fileURLWithPath: "/Applications/Clash.app"),
            currentVersion: "1.0.6",
            updateConfiguration: UpdateConfiguration(
                mechanism: .appStore,
                feedURL: URL(string: "https://apps.apple.com/us/app/clash/id6794257189")),
            appStorePlatform: .mac,
            appStoreCountryCode: "us",
            appStoreAccountCountryCode: "cn",
            status: .updateAvailable,
            latestVersion: "1.0.7",
            canAutomaticallyUpdate: false
        )
        let library = try makeLibrary(
            applications: [application],
            runningBundleIdentifiers: []
        )

        let destination = await library.performPrimaryAction(for: application.id)

        XCTAssertEqual(destination?.scheme, "macappstore")
        XCTAssertEqual(destination?.host, "showUpdatesPage")
        XCTAssertTrue(library.automaticUpdates.isEmpty)
    }

    func testAppStoreUpdateOpensAppPageWhenAppStoreCountryMatchesAccount() async throws {
        let application = AppRecord(
            name: "Sequel Ace",
            bundleIdentifier: "com.sequel-ace.sequel-ace",
            applicationURL: URL(fileURLWithPath: "/Applications/Sequel Ace.app"),
            currentVersion: "5.3.1",
            updateConfiguration: UpdateConfiguration(
                mechanism: .appStore,
                feedURL: URL(string: "https://apps.apple.com/us/app/sequel-ace/id1518036000")),
            appStorePlatform: .mac,
            appStoreCountryCode: "us",
            appStoreAccountCountryCode: "USA",
            status: .updateAvailable,
            latestVersion: "5.4.0",
            canAutomaticallyUpdate: false
        )
        let library = try makeLibrary(
            applications: [application],
            runningBundleIdentifiers: []
        )

        let destination = await library.performPrimaryAction(for: application.id)

        XCTAssertEqual(destination?.scheme, "macappstore")
        XCTAssertEqual(destination?.host, "apps.apple.com")
        XCTAssertEqual(destination?.path, "/us/app/sequel-ace/id1518036000")
        XCTAssertTrue(library.automaticUpdates.isEmpty)
    }

    func testFailedUpdateKeepsOriginalSelectionAndReportsFailure() async throws {
        var eudic = makeUpdateApplication(
            name: "欧路词典",
            bundleIdentifier: "com.eusoft.eudic"
        )
        eudic.installedUpdateConfiguration = UpdateConfiguration(mechanism: .homebrew)
        let tencent = makeUpdateApplication(
            name: "腾讯视频",
            bundleIdentifier: "com.tencent.tenvideo"
        )
        let suiteName = "UpkeepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let library = AppLibrary(
            applications: [eudic, tencent],
            scanner: UpdateSelectionScanner(applications: [tencent, eudic]),
            coordinator: FailingUpdateCoordinator(),
            userDefaults: defaults,
            libraryStore: .memory()
        )
        library.selectedApplicationID = eudic.id

        _ = await library.performPrimaryAction(for: eudic.id)

        XCTAssertEqual(library.selectedApplicationID, eudic.id)
        XCTAssertEqual(library.selectedApplication?.name, "欧路词典")
        XCTAssertEqual(library.alertMessage, "模拟更新失败")
        XCTAssertEqual(
            library.updateStatesByID[eudic.id]?.outcome, .failed(message: "模拟更新失败"))
        XCTAssertEqual(
            library.selectedApplication?.installedUpdateConfiguration?.mechanism, .homebrew)
    }

    func testUpdateAllPlansOnlyUpdatesNotAlreadyRunning() async throws {
        let first = makeUpdateApplication(name: "First", bundleIdentifier: "com.example.first")
        let second = makeUpdateApplication(name: "Second", bundleIdentifier: "com.example.second")
        let gate = UpdateGate()
        let library = try makeLibrary(
            applications: [first, second], coordinator: GatedUpdateCoordinator(gate: gate),
            runningBundleIdentifiers: [])

        let single = Task { await library.performPrimaryAction(for: first.id) }
        while !library.updatingApplicationIDs.contains(first.id) {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(library.remainingAutomaticUpdates.map(\.id), [second.id])
        let plan = await library.prepareUpdateAll()
        XCTAssertEqual(plan.applicationIDs, [second.id])

        await gate.open()
        _ = await single.value
        XCTAssertEqual(library.remainingAutomaticUpdates.count, 2)
    }

    func testUpdateAllRunsAtMostFiveUpdatesAtOnce() async throws {
        let applications = (1...7).map {
            makeUpdateApplication(name: "App\($0)", bundleIdentifier: "com.example.app\($0)")
        }
        let tracker = ConcurrencyTracker()
        let library = try makeLibrary(
            applications: applications,
            coordinator: ConcurrencyTrackingCoordinator(tracker: tracker),
            runningBundleIdentifiers: [])

        await library.updateAll()

        let peak = await tracker.peak
        let finished = await tracker.finished
        XCTAssertEqual(peak, 5)
        XCTAssertEqual(finished, 7)
        XCTAssertNil(library.updateAllProgress)
    }

    func testUpdateAllFollowsTheConcurrencySetting() async throws {
        let applications = (1...4).map {
            makeUpdateApplication(name: "App\($0)", bundleIdentifier: "com.example.app\($0)")
        }
        let suiteName = "UpkeepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(2, forKey: UpdateAllConcurrency.defaultsKey)
        let tracker = ConcurrencyTracker()
        let library = AppLibrary(
            applications: applications,
            scanner: UpdateSelectionScanner(applications: applications),
            coordinator: ConcurrencyTrackingCoordinator(tracker: tracker),
            userDefaults: defaults,
            libraryStore: .memory()
        )

        await library.updateAll()

        let peak = await tracker.peak
        let finished = await tracker.finished
        XCTAssertEqual(peak, 2)
        XCTAssertEqual(finished, 4)
    }

    func testConcurrencySettingDefaultsAndStaysInRange() throws {
        let suiteName = "UpkeepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(UpdateAllConcurrency.limit(in: defaults), 5)
        defaults.set(0, forKey: UpdateAllConcurrency.defaultsKey)
        XCTAssertEqual(UpdateAllConcurrency.limit(in: defaults), 1)
        defaults.set(99, forKey: UpdateAllConcurrency.defaultsKey)
        XCTAssertEqual(UpdateAllConcurrency.limit(in: defaults), 10)
        defaults.set(3, forKey: UpdateAllConcurrency.defaultsKey)
        XCTAssertEqual(UpdateAllConcurrency.limit(in: defaults), 3)
    }

    func testHomebrewUpgradesRunOneAtATime() async throws {
        let queue = HomebrewUpgradeQueue()
        let tracker = ConcurrencyTracker()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    try await queue.run {
                        await tracker.enter()
                        try await Task.sleep(for: .milliseconds(20))
                        await tracker.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        let peak = await tracker.peak
        let finished = await tracker.finished
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(finished, 4)
    }

    func testPrereleaseChoiceIsSavedAndRechecksTheApplication() async throws {
        let application = AppRecord(
            name: "Preview",
            bundleIdentifier: "com.example.Preview",
            applicationURL: URL(fileURLWithPath: "/Applications/Preview.app"),
            currentVersion: "1.0",
            updateConfiguration: UpdateConfiguration(
                mechanism: .sparkle, feedURL: URL(string: "https://example.com/appcast.xml")),
            status: .upToDate
        )
        let suiteName = "UpkeepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let library = AppLibrary(
            applications: [application],
            scanner: UpdateSelectionScanner(applications: [application]),
            coordinator: PrereleaseAwareCoordinator(),
            userDefaults: defaults,
            libraryStore: .memory()
        )

        await library.setPrereleasePolicy(.includePrereleases, for: application.id)
        XCTAssertEqual(library.prereleasePolicy(for: application), .includePrereleases)
        XCTAssertEqual(
            defaults.dictionary(forKey: "prereleasePolicies") as? [String: String],
            ["com.example.preview": "includePrereleases"])
        XCTAssertEqual(library.applications.first?.latestVersion, "2.0-beta.1")
        XCTAssertEqual(library.applications.first?.status, .updateAvailable)

        await library.setPrereleasePolicy(.automatic, for: application.id)
        XCTAssertEqual(library.prereleasePolicy(for: application), .automatic)
        XCTAssertEqual(
            defaults.dictionary(forKey: "prereleasePolicies") as? [String: String], [:])
        XCTAssertEqual(library.applications.first?.status, .upToDate)
    }

    func testDownloadProgressRecordsThePackageSize() async throws {
        let application = makeUpdateApplication(
            name: "Sized", bundleIdentifier: "com.example.sized")
        XCTAssertNil(application.packageByteCount)
        let suiteName = "UpkeepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let library = AppLibrary(
            applications: [application],
            scanner: UpdateSelectionScanner(applications: [application]),
            coordinator: FailingUpdateCoordinator(progress: [
                UpdateProgress(fractionCompleted: nil, status: "正在下载…", totalBytes: 0),
                UpdateProgress(
                    fractionCompleted: 0.5, status: "正在下载…", completedBytes: 1_000,
                    totalBytes: 2_000),
                UpdateProgress.indeterminate("正在安装…"),
            ]),
            userDefaults: defaults,
            libraryStore: .memory()
        )

        _ = await library.performPrimaryAction(for: application.id)

        let record = try XCTUnwrap(library.applications.first { $0.id == application.id })
        XCTAssertEqual(record.packageByteCount, 2_000)
        XCTAssertEqual(record.packageSizeDescription, "2 KB")
    }

    func testSuccessfulUpdateDoesNotSettleBeforeInstalledVersionAppears() async throws {
        let application = makeUpdateApplication(
            name: "Settled",
            bundleIdentifier: "com.example.settled"
        )
        let scanner = CountingUpdateScanner(applications: [application])
        let suiteName = "UpkeepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let library = AppLibrary(
            applications: [application],
            scanner: scanner,
            coordinator: SuccessfulUpdateCoordinator(),
            userDefaults: defaults,
            libraryStore: .memory()
        )

        _ = await library.performPrimaryAction(for: application.id)
        let scanCount = await scanner.numberOfScans()

        XCTAssertEqual(library.availableUpdates.map(\.id), [application.id])
        XCTAssertEqual(library.applications.first?.currentVersion, "1.0")
        XCTAssertEqual(library.applications.first?.status, .updateAvailable)
        XCTAssertTrue(library.applications.first?.canAutomaticallyUpdate ?? false)
        XCTAssertNil(library.applications.first?.lastInstalledAt)
        XCTAssertNil(library.applications.first?.installedUpdateConfiguration?.mechanism)
        XCTAssertEqual(scanCount, 0)
    }

    func testSuccessfulUpdateSettlesAfterInstalledVersionAppearsWithoutScanning() async throws {
        let applicationURL = try makeApplicationBundle(
            name: "Installed",
            bundleIdentifier: "com.example.installed",
            version: "1.0"
        )
        let application = AppRecord(
            name: "Installed",
            bundleIdentifier: "com.example.installed",
            applicationURL: applicationURL,
            currentVersion: "1.0",
            buildVersion: "1",
            updateConfiguration: UpdateConfiguration(mechanism: .sparkle),
            status: .updateAvailable,
            latestVersion: "2.0",
            latestBuildVersion: "2",
            canAutomaticallyUpdate: true
        )
        let scanner = CountingUpdateScanner(applications: [application])
        let suiteName = "UpkeepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let library = AppLibrary(
            applications: [application],
            scanner: scanner,
            coordinator: InstallingUpdateCoordinator(
                applicationURL: applicationURL,
                version: "2.0",
                buildVersion: "2"
            ),
            userDefaults: defaults,
            libraryStore: .memory()
        )

        _ = await library.performPrimaryAction(for: application.id)
        let scanCount = await scanner.numberOfScans()

        XCTAssertTrue(library.availableUpdates.isEmpty)
        XCTAssertEqual(library.applications.first?.currentVersion, "2.0")
        XCTAssertEqual(library.applications.first?.status, .upToDate)
        XCTAssertFalse(library.applications.first?.canAutomaticallyUpdate ?? true)
        XCTAssertNotNil(library.applications.first?.lastInstalledAt)
        XCTAssertEqual(scanCount, 0)
        let installedID = try XCTUnwrap(library.applications.first?.id)
        XCTAssertEqual(
            library.updateStatesByID[installedID]?.outcome, .succeeded(version: "2.0"))
    }

    func testSuccessfulUpdateRecordsActualChannelForEverySource() async throws {
        for mechanism in UpdateMechanism.allCases where mechanism != .selfManaged {
            let applicationURL = try makeApplicationBundle(
                name: "Channel-\(mechanism.rawValue)", bundleIdentifier: "com.example.channel",
                version: "1.0"
            )
            // The installed app advertises Sparkle, even when another channel installs it.
            try FileManager.default.createDirectory(
                at: applicationURL.appendingPathComponent("Contents/Frameworks/Sparkle.framework"),
                withIntermediateDirectories: true
            )
            let application = AppRecord(
                name: "Channel",
                bundleIdentifier: "com.example.channel",
                applicationURL: applicationURL,
                currentVersion: "1.0",
                buildVersion: "1",
                updateConfiguration: UpdateConfiguration(mechanism: mechanism),
                status: .updateAvailable,
                latestVersion: "2.0",
                latestBuildVersion: "2",
                canAutomaticallyUpdate: true,
                installedUpdateConfiguration: UpdateConfiguration(mechanism: .githubReleases)
            )
            let library = try makeLibrary(
                applications: [application],
                coordinator: InstallingUpdateCoordinator(
                    applicationURL: applicationURL, version: "2.0", buildVersion: "2"
                ),
                runningBundleIdentifiers: []
            )

            _ = await library.performPrimaryAction(for: application.id)

            let installed = try XCTUnwrap(library.applications.first)
            XCTAssertEqual(installed.currentVersion, "2.0", mechanism.rawValue)
            XCTAssertEqual(
                installed.installedUpdateConfiguration?.mechanism, mechanism, mechanism.rawValue)
            // The source shown is the route that installed it, not the one detected later.
            let route = UpdateConfiguration(mechanism: mechanism)
            XCTAssertEqual(installed.channelTitle, route.channel.title, mechanism.rawValue)
            XCTAssertEqual(
                installed.channelSystemImage, route.channel.systemImage, mechanism.rawValue)
            let restored = try JSONDecoder().decode(
                AppRecord.self, from: JSONEncoder().encode(installed))
            XCTAssertEqual(
                restored.installedUpdateConfiguration?.mechanism, mechanism, mechanism.rawValue)

            let scanned = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
            XCTAssertEqual(scanned.updateConfiguration.mechanism, .sparkle)
            let refreshed = try XCTUnwrap(
                AppLibrary.mergeKeepingCheckResults([scanned], previous: [restored]).first
            )
            XCTAssertEqual(
                refreshed.installedUpdateConfiguration?.mechanism, mechanism, mechanism.rawValue)
            XCTAssertEqual(refreshed.channelTitle, route.channel.title, mechanism.rawValue)
        }
    }

    private func makeLibrary(
        applications: [AppRecord],
        coordinator: any UpdateCoordinating = UpdateCoordinator(),
        runningBundleIdentifiers: Set<String>
    ) throws -> AppLibrary {
        let suiteName = "UpkeepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        return AppLibrary(
            applications: applications,
            scanner: UpdateSelectionScanner(applications: applications),
            coordinator: coordinator,
            process: ApplicationProcessClient(
                isRunning: { runningBundleIdentifiers.contains($0.bundleIdentifier) },
                quit: { _ in },
                launch: { _ in }
            ),
            userDefaults: defaults,
            libraryStore: .memory()
        )
    }

    private func makeUpdateApplication(
        name: String,
        bundleIdentifier: String
    ) -> AppRecord {
        AppRecord(
            name: name,
            bundleIdentifier: bundleIdentifier,
            applicationURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            currentVersion: "1.0",
            updateConfiguration: UpdateConfiguration(mechanism: .sparkle),
            status: .updateAvailable,
            latestVersion: "2.0",
            canAutomaticallyUpdate: true
        )
    }

    private func makeApplicationBundle(
        name: String,
        bundleIdentifier: String,
        version: String
    ) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "UpkeepTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let applicationURL = rootURL.appendingPathComponent("\(name).app", isDirectory: true)
        let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        try InstallingUpdateCoordinator.writeInfoPlist(
            at: applicationURL,
            bundleIdentifier: bundleIdentifier,
            version: version,
            buildVersion: "1"
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }
        return applicationURL
    }
}

private struct UpdateSelectionScanner: ApplicationScanning {
    let applications: [AppRecord]

    func scan() async -> [AppRecord] {
        applications
    }
}

private struct FailingUpdateCoordinator: UpdateCoordinating {
    var progress: [UpdateProgress] = []

    func enrich(_ applications: [AppRecord]) async -> [AppRecord] {
        applications
    }

    func check(_ application: AppRecord) async -> AppRecord {
        application
    }

    func update(
        _ application: AppRecord,
        progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws {
        for frame in self.progress {
            progress(frame)
            // Real downloads report over time; the relay coalesces bursts.
            try await Task.sleep(for: .milliseconds(150))
        }
        throw ProcessRunnerError.failed(status: 1, message: "模拟更新失败")
    }
}

/// Offers a beta only to records that accept pre-releases.
private struct PrereleaseAwareCoordinator: UpdateCoordinating {
    func enrich(_ applications: [AppRecord]) async -> [AppRecord] {
        applications
    }

    func check(_ application: AppRecord) async -> AppRecord {
        var checked = application
        if application.acceptsPrereleases {
            checked.applyRemoteRelease(version: "2.0-beta.1", canInstall: true)
        } else {
            checked.applyInstalledRelease()
        }
        return checked
    }

    func update(
        _ application: AppRecord,
        progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws {}
}

private actor ConcurrencyTracker {
    private(set) var peak = 0
    private(set) var finished = 0
    private var current = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() {
        current -= 1
        finished += 1
    }
}

private struct ConcurrencyTrackingCoordinator: UpdateCoordinating {
    let tracker: ConcurrencyTracker

    func enrich(_ applications: [AppRecord]) async -> [AppRecord] {
        applications
    }

    func check(_ application: AppRecord) async -> AppRecord {
        application
    }

    func update(
        _ application: AppRecord,
        progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws {
        await tracker.enter()
        try await Task.sleep(for: .milliseconds(50))
        await tracker.leave()
        throw ProcessRunnerError.failed(status: 1, message: "模拟更新失败")
    }
}

private actor UpdateGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Holds an update in progress until the test opens the gate, then fails it.
private struct GatedUpdateCoordinator: UpdateCoordinating {
    let gate: UpdateGate

    func enrich(_ applications: [AppRecord]) async -> [AppRecord] {
        applications
    }

    func check(_ application: AppRecord) async -> AppRecord {
        application
    }

    func update(
        _ application: AppRecord,
        progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws {
        await gate.wait()
        throw ProcessRunnerError.failed(status: 1, message: "模拟更新失败")
    }
}

private struct SuccessfulUpdateCoordinator: UpdateCoordinating {
    func enrich(_ applications: [AppRecord]) async -> [AppRecord] {
        applications
    }

    func check(_ application: AppRecord) async -> AppRecord {
        application
    }

    func update(
        _ application: AppRecord,
        progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws {
        progress(UpdateProgress(fractionCompleted: 1, status: "正在完成…"))
    }
}

private struct InstallingUpdateCoordinator: UpdateCoordinating {
    let applicationURL: URL
    let version: String
    let buildVersion: String

    func enrich(_ applications: [AppRecord]) async -> [AppRecord] {
        applications
    }

    func check(_ application: AppRecord) async -> AppRecord {
        application
    }

    func update(
        _ application: AppRecord,
        progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws {
        try Self.writeInfoPlist(
            at: applicationURL,
            bundleIdentifier: application.bundleIdentifier,
            version: version,
            buildVersion: buildVersion
        )
        progress(UpdateProgress(fractionCompleted: 1, status: "正在完成…"))
    }

    static func writeInfoPlist(
        at applicationURL: URL,
        bundleIdentifier: String,
        version: String,
        buildVersion: String
    ) throws {
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleDisplayName": applicationURL.deletingPathExtension().lastPathComponent,
            "CFBundleName": applicationURL.deletingPathExtension().lastPathComponent,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": buildVersion,
            "CFBundleExecutable": "TestApplication",
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(
            to: applicationURL.appendingPathComponent("Contents/Info.plist"),
            options: .atomic
        )
    }
}

private actor CountingUpdateScanner: ApplicationScanning {
    let applications: [AppRecord]
    private var scanCount = 0

    init(applications: [AppRecord]) {
        self.applications = applications
    }

    func scan() async -> [AppRecord] {
        scanCount += 1
        return applications
    }

    func numberOfScans() -> Int {
        scanCount
    }
}
