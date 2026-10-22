import Foundation
import Observation

@MainActor
@Observable
final class AppLibrary {
    var applications: [AppRecord] {
        didSet { rebuildApplicationSections() }
    }
    var selectedApplicationID: AppRecord.ID?
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            sidebarSections = applicationSections.matching(searchText)
        }
    }
    private var applicationSections = AppSidebarSections()
    private(set) var sidebarSections = AppSidebarSections()
    private(set) var automaticUpdates: [AppRecord] = []
    var phase: LibraryPhase = .idle
    var lastCheckedAt: Date?
    var alertMessage: String?
    private(set) var checkingApplicationIDs = Set<AppRecord.ID>()
    /// The size of the current check round, so progress can be shown as completed/total.
    private(set) var checkingTotalCount = 0
    private(set) var updateAllProgress: UpdateAllProgress?
    private(set) var updatingApplicationIDs = Set<AppRecord.ID>()
    private(set) var updateStatesByID: [AppRecord.ID: ApplicationUpdateState] = [:]
    private(set) var ignoredBundleIdentifiers: Set<String> {
        didSet { rebuildApplicationSections() }
    }

    private let scanner: any ApplicationScanning
    private let coordinator: any UpdateCoordinating
    @ObservationIgnored private let process: ApplicationProcessClient
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let libraryStore: ApplicationLibraryStore
    @ObservationIgnored private let notifier: UpdateNotifier
    @ObservationIgnored private var pendingCheckedApplications: [AppRecord] = []
    @ObservationIgnored private var pendingCheckedFlushTask: Task<Void, Never>?
    @ObservationIgnored private var requestedRefreshCachePolicy: UpdateCachePolicy = .allowed
    @ObservationIgnored private var refreshGeneration = 0
    private var hasLoaded: Bool
    private var refreshRequested = false
    private var installedApplicationRefreshRequested = false

    private static let ignoredBundleIdentifiersKey = "ignoredUpdateBundleIdentifiers"
    private static let maximumConcurrentChecks = 30
    private static let checkedResultBatchSize = 10
    private static let checkedResultFlushDelay = Duration.milliseconds(250)

    init(
        applications: [AppRecord] = [],
        scanner: any ApplicationScanning = ApplicationScanner(),
        coordinator: any UpdateCoordinating = UpdateCoordinator(),
        process: ApplicationProcessClient = .live,
        userDefaults: UserDefaults = .standard,
        libraryStore: ApplicationLibraryStore = .live(),
        notifier: UpdateNotifier = .live
    ) {
        let ignoredBundleIdentifiers = Set(
            userDefaults.stringArray(forKey: Self.ignoredBundleIdentifiersKey) ?? []
        )
        let loadedApplications: [AppRecord]
        let loadedCheckedAt: Date?
        if applications.isEmpty, let snapshot = libraryStore.load() {
            loadedApplications = snapshot.applications.filter {
                FileManager.default.fileExists(atPath: $0.applicationURL.path)
            }
            loadedCheckedAt = snapshot.lastCheckedAt
        } else {
            loadedApplications = applications
            loadedCheckedAt = applications.isEmpty ? nil : .now
        }

        self.applications = Self.uniqueApplications(loadedApplications)
        self.scanner = scanner
        self.coordinator = coordinator
        self.process = process
        self.userDefaults = userDefaults
        self.libraryStore = libraryStore
        self.notifier = notifier
        self.ignoredBundleIdentifiers = ignoredBundleIdentifiers
        self.hasLoaded = !applications.isEmpty
        self.lastCheckedAt = loadedCheckedAt
        self.selectedApplicationID = Self.preferredSelection(
            in: loadedApplications,
            ignoring: ignoredBundleIdentifiers
        )
        rebuildApplicationSections()
    }

    var selectedApplication: AppRecord? {
        guard let selectedApplicationID else { return nil }
        return applications.first { $0.id == selectedApplicationID }
    }

    var availableUpdates: [AppRecord] {
        applicationSections.availableUpdates
    }

    var ignoredUpdates: [AppRecord] {
        applicationSections.ignoredUpdates
    }

    var ignoredApplicationIDs: Set<AppRecord.ID> {
        applicationSections.ignoredApplicationIDs
    }

    private func rebuildApplicationSections() {
        applicationSections = AppSidebarSections(
            applications: applications, ignoredBundleIdentifiers: ignoredBundleIdentifiers
        )
        sidebarSections = applicationSections.matching(searchText)
        automaticUpdates = applicationSections.availableUpdates.filter(\.canAutomaticallyUpdate)
        let retainedIDs = applicationSections.applicationIDs.union(updatingApplicationIDs)
        for id in updateStatesByID.keys where !retainedIDs.contains(id) {
            updateStatesByID[id] = nil
        }
        for application in applications where updateStatesByID[application.id] == nil {
            updateStatesByID[application.id] = ApplicationUpdateState()
        }
    }

    func requiresRelaunchConfirmation(for application: AppRecord) async -> Bool {
        guard application.needsUpdate, application.canAutomaticallyUpdate else { return false }
        return await process.isRunning(application)
    }

    func prepareUpdateAll() async -> UpdateAllPlan {
        let updates = automaticUpdates
        let runningIDs = await process.runningApplicationIDs(updates)
        return UpdateAllPlan(
            applicationIDs: updates.map(\.id),
            runningApplications: updates.filter { runningIDs.contains($0.id) }
        )
    }

    var isRefreshing: Bool {
        phase != .idle
    }

    func isUpdateIgnored(_ application: AppRecord) -> Bool {
        ignoredBundleIdentifiers.contains(Self.ignoreIdentifier(for: application))
    }

    func ignoreUpdates(for applicationID: AppRecord.ID) {
        guard let application = applications.first(where: { $0.id == applicationID }) else {
            return
        }

        ignoredBundleIdentifiers.insert(Self.ignoreIdentifier(for: application))
        persistIgnoredBundleIdentifiers()
    }

    func stopIgnoringUpdates(for applicationID: AppRecord.ID) {
        guard let application = applications.first(where: { $0.id == applicationID }) else {
            return
        }

        ignoredBundleIdentifiers.remove(Self.ignoreIdentifier(for: application))
        persistIgnoredBundleIdentifiers()
    }

    func forgetUninstalled(_ application: AppRecord) {
        applications.removeAll {
            $0.id == application.id
                || ($0.bundleIdentifier == application.bundleIdentifier
                    && $0.applicationURL.standardizedFileURL
                        == application.applicationURL.standardizedFileURL)
        }

        if selectedApplicationID == application.id {
            selectedApplicationID = Self.preferredSelection(
                in: applications,
                ignoring: ignoredBundleIdentifiers
            )
        }
        persistSnapshot()
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await refresh(cachePolicy: .allowed)
    }

    func refreshIfStale(after interval: TimeInterval = 60) async {
        guard hasLoaded, phase == .idle, updatingApplicationIDs.isEmpty else { return }
        if let lastCheckedAt, Date.now.timeIntervalSince(lastCheckedAt) < interval {
            return
        }
        await refresh(cachePolicy: .allowed)
    }

    func refreshInstalledApplications() async {
        guard !Task.isCancelled, hasLoaded, updatingApplicationIDs.isEmpty else { return }
        installedApplicationRefreshRequested = true
        guard phase == .idle else { return }

        // Each scan owns its state, including when a manual refresh supersedes it.
        refreshGeneration += 1
        let generation = refreshGeneration
        defer { finishRefresh(generation: generation) }

        repeat {
            installedApplicationRefreshRequested = false
            let previousSelection = selectedApplicationID
            let previousApplications = applications
            phase = .scanning

            let installedApplications = await scanner.scanInstalledApplications(
                reusing: previousApplications
            )
            guard isCurrentRefresh(generation) else { return }

            publish(
                Self.mergeInstalledApplicationChanges(
                    installedApplications,
                    previous: previousApplications
                ),
                selecting: previousSelection
            )
            phase = .idle
            persistSnapshot()
        } while installedApplicationRefreshRequested

        if refreshRequested {
            await refresh(cachePolicy: requestedRefreshCachePolicy)
        }
    }

    private func refreshPendingInstalledApplications() async {
        guard installedApplicationRefreshRequested else { return }
        await refreshInstalledApplications()
    }

    private func finishRefresh(generation: Int) {
        guard generation == refreshGeneration else { return }
        pendingCheckedFlushTask?.cancel()
        pendingCheckedFlushTask = nil
        pendingCheckedApplications.removeAll(keepingCapacity: true)
        checkingApplicationIDs.removeAll(keepingCapacity: true)
        phase = .idle
    }

    func refreshReleaseMetadataIfNeeded(for applicationID: AppRecord.ID) async {
        guard phase == .idle,
            !updatingApplicationIDs.contains(applicationID),
            let existingIndex = applications.firstIndex(where: { $0.id == applicationID })
        else {
            return
        }

        let application = applications[existingIndex]
        guard application.hasIncompleteReleaseMetadata else {
            return
        }
        guard application.isCheckable else { return }

        let checked = await coordinator.check(application)
        // A scan or another check may have replaced the record while this request was in flight.
        guard !Task.isCancelled,
            !updatingApplicationIDs.contains(applicationID),
            let currentIndex = applications.firstIndex(where: { $0.id == applicationID }),
            applications[currentIndex] == application
        else {
            return
        }

        applications[currentIndex] = Self.coalesceCheckResult(
            checked,
            over: applications[currentIndex]
        )
        persistSnapshot()
    }

    func refresh() async {
        await refresh(cachePolicy: .reloadIgnoringCache)
    }

    func restartRefresh() async {
        guard !Task.isCancelled, updatingApplicationIDs.isEmpty else { return }
        refreshGeneration += 1
        refreshRequested = false
        requestedRefreshCachePolicy = .allowed
        await performRefresh(
            cachePolicy: .reloadIgnoringCache,
            generation: refreshGeneration
        )
        await refreshPendingInstalledApplications()
    }

    private func refresh(cachePolicy: UpdateCachePolicy) async {
        guard !Task.isCancelled, updatingApplicationIDs.isEmpty else { return }
        guard phase == .idle else {
            refreshRequested = true
            requestedRefreshCachePolicy = requestedRefreshCachePolicy.merging(cachePolicy)
            return
        }

        var activeCachePolicy = cachePolicy
        repeat {
            refreshRequested = false
            requestedRefreshCachePolicy = .allowed
            let completed = await performRefresh(
                cachePolicy: activeCachePolicy,
                generation: refreshGeneration
            )
            guard completed else { return }
            activeCachePolicy = requestedRefreshCachePolicy
        } while refreshRequested
        await refreshPendingInstalledApplications()
    }

    @discardableResult
    private func performRefresh(
        cachePolicy: UpdateCachePolicy,
        generation: Int
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        // This full scan covers local changes already queued before it starts.
        installedApplicationRefreshRequested = false
        defer { finishRefresh(generation: generation) }
        let previousSelection = selectedApplicationID
        let previousApplications = applications
        pendingCheckedFlushTask?.cancel()
        pendingCheckedFlushTask = nil
        pendingCheckedApplications.removeAll(keepingCapacity: true)
        checkingApplicationIDs.removeAll(keepingCapacity: true)
        phase = .scanning
        alertMessage = nil

        if previousApplications.isEmpty {
            let installedApplications = await scanner.scanInstalledApplications(
                reusing: previousApplications
            )
            guard isCurrentRefresh(generation) else { return false }
            if !installedApplications.isEmpty {
                publish(installedApplications, selecting: previousSelection)
                await Task.yield()
            }
        }

        let scannedApplications = await scanner.scan(reusing: previousApplications)
        guard isCurrentRefresh(generation) else { return false }

        guard !scannedApplications.isEmpty else {
            applications = []
            selectedApplicationID = nil
            checkingApplicationIDs.removeAll(keepingCapacity: true)
            phase = .idle
            lastCheckedAt = .now
            persistSnapshot()
            return true
        }

        publish(
            Self.mergeKeepingCheckResults(scannedApplications, previous: previousApplications),
            selecting: previousSelection
        )
        phase = .checking
        beginChecking(Self.checkableApplications(applications))
        await Task.yield()

        let enrichedApplications = await coordinator.enrich(applications, cachePolicy: cachePolicy)
        guard isCurrentRefresh(generation) else { return false }
        publish(
            Self.mergeKeepingCheckResults(enrichedApplications, previous: applications),
            selecting: selectedApplicationID
        )

        let applicationsToCheck = Self.checkableApplications(
            applications,
            prioritizing: selectedApplicationID
        )
        beginChecking(applicationsToCheck)
        await checkApplications(applicationsToCheck, generation: generation)
        guard isCurrentRefresh(generation) else { return false }
        flushPendingChecked()
        checkingApplicationIDs.removeAll(keepingCapacity: true)

        let claimedApplications = await coordinator.enrich(applications, cachePolicy: .allowed)
        guard isCurrentRefresh(generation) else { return false }
        publish(
            Self.mergeKeepingCheckResults(claimedApplications, previous: applications),
            selecting: selectedApplicationID
        )

        lastCheckedAt = .now
        phase = .idle
        persistSnapshot()
        return true
    }

    private func checkApplications(_ applications: [AppRecord], generation: Int) async {
        guard !applications.isEmpty else { return }

        let coordinator = coordinator
        await withTaskGroup(of: AppRecord.self) { group in
            var iterator = applications.makeIterator()

            for _ in 0..<min(Self.maximumConcurrentChecks, applications.count) {
                guard let application = iterator.next() else { break }
                group.addTask {
                    await coordinator.check(application)
                }
            }

            while let checked = await group.next() {
                guard isCurrentRefresh(generation) else {
                    group.cancelAll()
                    return
                }
                queueChecked(checked)

                if let application = iterator.next() {
                    group.addTask {
                        await coordinator.check(application)
                    }
                }
            }
        }
    }

    private func beginChecking(_ applications: [AppRecord]) {
        checkingApplicationIDs = Set(applications.map(\.id))
        checkingTotalCount = checkingApplicationIDs.count
    }

    private func isCurrentRefresh(_ generation: Int) -> Bool {
        generation == refreshGeneration && !Task.isCancelled
    }

    private static func checkableApplications(
        _ applications: [AppRecord],
        prioritizing selection: AppRecord.ID? = nil
    ) -> [AppRecord] {
        let checkable = applications.filter(\.isCheckable)
        guard let selection,
            let selectedIndex = checkable.firstIndex(where: { $0.id == selection })
        else {
            return checkable
        }

        var prioritized = checkable
        prioritized.insert(prioritized.remove(at: selectedIndex), at: 0)
        return prioritized
    }

    private func publish(_ applications: [AppRecord], selecting selection: AppRecord.ID?) {
        self.applications = Self.uniqueApplications(applications)
        selectedApplicationID = Self.validSelection(
            selection,
            in: applications,
            ignoring: ignoredBundleIdentifiers
        )
    }

    private func queueChecked(_ application: AppRecord) {
        pendingCheckedApplications.append(application)
        if pendingCheckedApplications.count >= Self.checkedResultBatchSize {
            flushPendingChecked()
            return
        }
        guard pendingCheckedFlushTask == nil else { return }
        pendingCheckedFlushTask = Task { @MainActor in
            try? await Task.sleep(for: Self.checkedResultFlushDelay)
            guard !Task.isCancelled else { return }
            flushPendingChecked()
        }
    }

    private func flushPendingChecked() {
        pendingCheckedFlushTask?.cancel()
        pendingCheckedFlushTask = nil
        let pending = pendingCheckedApplications
        pendingCheckedApplications.removeAll(keepingCapacity: true)
        guard !pending.isEmpty else { return }
        checkingApplicationIDs.subtract(pending.lazy.map(\.id))

        var updated = applications
        for application in pending {
            guard !updatingApplicationIDs.contains(application.id),
                let index = updated.firstIndex(where: { $0.id == application.id })
            else {
                continue
            }
            updated[index] = Self.coalesceCheckResult(application, over: updated[index])
        }
        applications = updated
    }

    private func persistSnapshot() {
        let snapshot = ApplicationLibrarySnapshot(
            lastCheckedAt: lastCheckedAt,
            applications: applications
        )
        let save = libraryStore.save
        Task.detached {
            save(snapshot)
        }
    }

    // Old snapshots or overlapping scan results may contain the same path twice.
    // Keep distinct installations (different paths), even with the same bundle ID.
    static func uniqueApplications(_ applications: [AppRecord]) -> [AppRecord] {
        var seen = Set<AppRecord.ID>()
        return applications.filter { seen.insert($0.id).inserted }
    }

    static func mergeKeepingCheckResults(
        _ incoming: [AppRecord],
        previous: [AppRecord]
    ) -> [AppRecord] {
        let previousByID = Dictionary(
            previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return uniqueApplications(incoming).map { current in
            guard let previous = previousByID[current.id] else {
                return current
            }

            if previousReleaseIsIncompatible(previous, with: current) {
                return current
            }
            if current.updateConfiguration.mechanism == .selfManaged,
                previous.updateConfiguration.mechanism == .selfManaged
            {
                var cleaned = carryingMetadata(from: previous, onto: current)
                cleaned.discardRemoteRelease()
                return cleaned
            }

            // Homebrew enrichment has already checked this version. Do not replace
            // a fresh up-to-date result with a previously cached update.
            if current.updateConfiguration.mechanism == .homebrew,
                current.status == .updateAvailable || current.status == .upToDate
            {
                return carryingMetadata(from: previous, onto: current)
            }

            if previous.updateConfiguration.mechanism == .githubReleases,
                current.updateConfiguration.mechanism != .githubReleases
            {
                return carryingMetadata(from: previous, onto: current)
            }

            let versionChanged =
                current.currentVersion != previous.currentVersion
                || current.buildVersion != previous.buildVersion
                || (current.updateConfiguration.mechanism == .vscodeUpdater
                    && current.updateConfiguration.identifier
                        != previous.updateConfiguration.identifier)
            if versionChanged {
                return carryingPendingUpdate(from: previous, onto: current)
            }

            var merged = current
            if previous.status == .updateAvailable {
                switch current.status {
                case .checking, .selfManaged, .unavailable:
                    return carryingPendingUpdate(from: previous, onto: current)
                case .updateAvailable, .upToDate:
                    break
                }
            }

            if previous.updateConfiguration.mechanism == current.updateConfiguration.mechanism,
                previous.status != .checking
            {
                merged.copyCheckResult(from: previous)
            }
            return carryingMetadata(from: previous, onto: merged)
        }
    }

    static func mergeInstalledApplicationChanges(
        _ installedApplications: [AppRecord],
        previous: [AppRecord]
    ) -> [AppRecord] {
        let previousByID = Dictionary(
            previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return uniqueApplications(installedApplications).map { disk in
            guard let existing = previousByID[disk.id] else {
                return disk
            }

            let versionChanged =
                disk.currentVersion != existing.currentVersion
                || disk.buildVersion != existing.buildVersion
                || (disk.updateConfiguration.mechanism == .vscodeUpdater
                    && disk.updateConfiguration.identifier
                        != existing.updateConfiguration.identifier)
            guard versionChanged else {
                return carryingInstalledState(from: existing, onto: disk)
            }

            return installedDiskRecord(disk, replacing: existing, installedAt: .now)
        }
    }

    static func coalesceCheckResult(_ incoming: AppRecord, over existing: AppRecord) -> AppRecord {
        var incoming = incoming
        if incoming.updateConfiguration.mechanism == .selfManaged,
            existing.updateConfiguration.mechanism == .selfManaged
        {
            incoming.discardRemoteRelease()
        }
        let result: AppRecord
        if existing.status == .updateAvailable,
            existing.updateConfiguration.mechanism != .selfManaged
        {
            switch incoming.status {
            case .checking, .selfManaged, .unavailable:
                result = carryingPendingUpdate(from: existing, onto: incoming)
            default:
                result = incoming
            }
        } else {
            result = incoming
        }

        var merged = result
        if merged.lastInstalledAt == nil {
            merged.lastInstalledAt = existing.lastInstalledAt
        }
        if merged.installedUpdateConfiguration == nil, hasSameInstalledVersion(merged, existing) {
            merged.installedUpdateConfiguration = existing.installedUpdateConfiguration
        }
        if merged.updateConfiguration.mechanism != .selfManaged,
            !previousReleaseIsIncompatible(existing, with: merged)
        {
            merged.mergeReleaseMetadata(from: existing)
        }
        return merged
    }

    private static func hasSameInstalledVersion(_ lhs: AppRecord, _ rhs: AppRecord) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.currentVersion == rhs.currentVersion
            && lhs.buildVersion == rhs.buildVersion
    }

    private static func previousReleaseIsIncompatible(
        _ previous: AppRecord, with current: AppRecord
    )
        -> Bool
    {
        guard previous.bundleIdentifier == current.bundleIdentifier else { return true }
        if previous.updateConfiguration.mechanism == .githubReleases,
            current.updateConfiguration.mechanism == .githubReleases,
            previous.updateConfiguration.githubReleaseTagPrefix
                != current.updateConfiguration.githubReleaseTagPrefix
        {
            return true
        }
        guard !hasSameInstalledVersion(previous, current) else { return false }
        // Replacements can restart their numbering (for example, 1.x -> 0.x).
        // Preserve ordinary forward updates and the cheap scan's incomplete source detection.
        if previous.currentVersion != current.currentVersion,
            [previous.currentVersion, current.currentVersion].allSatisfy({
                $0.range(of: #"\A[0-9]+(?:\.[0-9]+)+\z"#, options: .regularExpression) != nil
            }),
            VersionComparator.isNewer(previous.currentVersion, than: current.currentVersion)
        {
            return true
        }
        // Homebrew and the embedded updater can describe the same installation.
        // Switching between these routes does not by itself replace the app.
        if previous.updateConfiguration.mechanism == .homebrew
            || current.updateConfiguration.mechanism == .homebrew
        {
            return false
        }
        return current.updateConfiguration.mechanism != .selfManaged
            && (current.updateConfiguration.mechanism != previous.updateConfiguration.mechanism
                || current.updateConfiguration.feedURL != previous.updateConfiguration.feedURL)
    }

    private static func carryingPendingUpdate(
        from previous: AppRecord,
        onto current: AppRecord
    ) -> AppRecord {
        guard !previousReleaseIsIncompatible(previous, with: current) else { return current }
        if current.updateConfiguration.mechanism == .selfManaged,
            previous.updateConfiguration.mechanism == .selfManaged
        {
            var cleaned = carryingMetadata(from: previous, onto: current)
            cleaned.discardRemoteRelease()
            return cleaned
        }
        guard previous.status == .updateAvailable, previous.hasNewerRelease(than: current) else {
            return carryingMetadata(from: previous, onto: current)
        }

        var merged = current
        merged.copyCheckResult(from: previous)
        merged.updatePageURL =
            previous.updateConfiguration.mechanism == current.updateConfiguration.mechanism
            ? previous.updatePageURL : nil
        merged.canAutomaticallyUpdate =
            previous.updateConfiguration.mechanism == current.updateConfiguration.mechanism
            ? previous.canAutomaticallyUpdate
            : current.canAutomaticallyUpdate
        return carryingMetadata(from: previous, onto: merged)
    }

    private static func carryingMetadata(
        from previous: AppRecord,
        onto current: AppRecord
    ) -> AppRecord {
        var merged = current
        if merged.updateConfiguration.feedURL == nil,
            previous.updateConfiguration.mechanism == merged.updateConfiguration.mechanism
        {
            merged.updateConfiguration.feedURL = previous.updateConfiguration.feedURL
        }
        if merged.updateConfiguration.identifier == nil,
            previous.updateConfiguration.mechanism == merged.updateConfiguration.mechanism
        {
            merged.updateConfiguration.identifier = previous.updateConfiguration.identifier
        }
        if merged.updateConfiguration.githubReleaseTagPrefix == nil,
            previous.updateConfiguration.feedURL == merged.updateConfiguration.feedURL,
            previous.updateConfiguration.mechanism == merged.updateConfiguration.mechanism
        {
            merged.updateConfiguration.githubReleaseTagPrefix =
                previous.updateConfiguration.githubReleaseTagPrefix
        }
        if merged.alternateUpdateConfiguration == nil {
            merged.alternateUpdateConfiguration = previous.alternateUpdateConfiguration
        }
        if merged.homebrewCaskToken == nil, merged.updateConfiguration.mechanism != .appStore {
            merged.homebrewCaskToken = previous.homebrewCaskToken
        }
        if merged.appStoreCountryCode == nil,
            previous.updateConfiguration.mechanism == merged.updateConfiguration.mechanism
        {
            merged.appStoreCountryCode = previous.appStoreCountryCode
        }
        if merged.appStoreAccountCountryCode == nil,
            previous.updateConfiguration.mechanism == merged.updateConfiguration.mechanism
        {
            merged.appStoreAccountCountryCode = previous.appStoreAccountCountryCode
        }
        merged.mergeReleaseMetadata(from: previous)
        if merged.lastInstalledAt == nil {
            merged.lastInstalledAt = previous.lastInstalledAt
        }
        if merged.installedUpdateConfiguration == nil, hasSameInstalledVersion(merged, previous) {
            merged.installedUpdateConfiguration = previous.installedUpdateConfiguration
        }
        return merged
    }

    private static func carryingInstalledState(
        from previous: AppRecord,
        onto disk: AppRecord
    ) -> AppRecord {
        if disk.updateConfiguration.mechanism != .selfManaged,
            disk.updateConfiguration.mechanism != previous.updateConfiguration.mechanism,
            previous.updateConfiguration.mechanism != .homebrew
        {
            return carryingMetadata(from: previous, onto: disk)
        }

        var merged = carryingMetadata(from: previous, onto: disk)
        let detectedRelease = merged
        if previous.updateConfiguration.mechanism == .homebrew {
            merged.rememberAlternateUpdateConfiguration(from: disk)
        }
        let detectedSameSource =
            disk.updateConfiguration.mechanism == previous.updateConfiguration.mechanism
        var configuration = previous.updateConfiguration
        configuration.homepageURL = merged.updateConfiguration.homepageURL
        if detectedSameSource {
            configuration.feedURL = disk.updateConfiguration.feedURL ?? configuration.feedURL
            configuration.identifier =
                disk.updateConfiguration.identifier ?? configuration.identifier
        }
        merged.updateConfiguration = configuration
        merged.appStorePlatform =
            detectedSameSource
            ? disk.appStorePlatform ?? previous.appStorePlatform
            : previous.appStorePlatform
        merged.appStoreCountryCode =
            detectedSameSource
            ? disk.appStoreCountryCode ?? previous.appStoreCountryCode
            : previous.appStoreCountryCode
        merged.appStoreAccountCountryCode =
            detectedSameSource
            ? disk.appStoreAccountCountryCode ?? previous.appStoreAccountCountryCode
            : previous.appStoreAccountCountryCode
        merged.status = previous.status
        merged.latestVersion = previous.latestVersion
        merged.latestBuildVersion = previous.latestBuildVersion
        if !merged.hasSameRelease(as: detectedRelease) { merged.clearReleaseMetadata() }
        merged.mergeReleaseMetadata(from: previous)
        merged.updatePageURL = previous.updatePageURL
        merged.canAutomaticallyUpdate = previous.canAutomaticallyUpdate
        return merged
    }

    private static func installedDiskRecord(
        _ disk: AppRecord,
        replacing application: AppRecord,
        installedAt: Date
    ) -> AppRecord {
        if previousReleaseIsIncompatible(application, with: disk) {
            var record = disk
            record.discardRemoteRelease()
            record.status =
                record.updateConfiguration.mechanism == .selfManaged ? .selfManaged : .upToDate
            record.lastInstalledAt = installedAt
            return record
        }
        var record = carryingInstalledState(from: application, onto: disk)
        record.lastInstalledAt = installedAt

        if application.hasNewerRelease(than: disk) {
            record.status = .updateAvailable
            record.canAutomaticallyUpdate = application.canAutomaticallyUpdate
        } else {
            if record.updateConfiguration.mechanism == .selfManaged {
                record.discardRemoteRelease()
            } else {
                record.applyInstalledRelease()
            }
        }
        return record
    }

    func performPrimaryAction(for applicationID: AppRecord.ID) async -> URL? {
        guard let application = applications.first(where: { $0.id == applicationID }) else {
            return nil
        }

        if application.needsUpdate, application.canAutomaticallyUpdate {
            await update(application)
            return nil
        }

        if application.needsUpdate,
            application.updateConfiguration.mechanism == .appStore,
            application.updateConfiguration.feedURL != nil
        {
            return Self.nativeAppStoreUpdateURL(for: application)
        }

        if let updatePageURL = application.manualUpdateURL {
            return updatePageURL
        }

        return application.applicationURL
    }

    func updateAll(applicationIDs: [AppRecord.ID]? = nil) async {
        guard !automaticUpdates.isEmpty else { return }
        let ids = applicationIDs ?? automaticUpdates.map(\.id)
        var failures: [String] = []
        var updatedNames: [String] = []
        var failedNames: [String] = []
        notifier.prepare()
        updateAllProgress = UpdateAllProgress(totalCount: ids.count)
        defer { updateAllProgress = nil }

        for id in ids {
            guard !Task.isCancelled else { break }
            guard let application = automaticUpdates.first(where: { $0.id == id }) else {
                updateAllProgress?.completedCount += 1
                continue
            }
            updateAllProgress?.currentApplicationName = application.name
            do {
                if try await performVisibleUpdate(application) != nil {
                    updatedNames.append(application.name)
                }
            } catch {
                failures.append("\(application.name)：\(error.localizedDescription)")
                failedNames.append(application.name)
            }
            updateAllProgress?.completedCount += 1
        }

        if !failures.isEmpty {
            alertMessage = failures.joined(separator: "\n")
        }
        notifyUpdateAllFinished(updated: updatedNames, failed: failedNames)
    }

    private func notifyUpdateAllFinished(updated: [String], failed: [String]) {
        let title: String
        switch (updated.count, failed.count) {
        case (0, 0):
            return
        case (1, 0):
            title = "「\(updated[0])」已更新"
        case (_, 0):
            title = "已更新 \(updated.count) 个应用"
        case (0, 1):
            title = "「\(failed[0])」更新失败"
        case (0, _):
            title = "\(failed.count) 个应用更新失败"
        default:
            title = "已更新 \(updated.count) 个应用，\(failed.count) 个失败"
        }
        let body =
            failed.isEmpty
            ? updated.map { "「\($0)」" }.joined(separator: "、")
            : "打开 Upkeep 查看失败原因。"
        notifier.notify(title, body)
    }

    func reportOpeningFailure(for url: URL) {
        alertMessage = "无法打开 \(url.lastPathComponent)。"
    }

    private func update(_ application: AppRecord) async {
        let selectionToRestore = selectedApplicationID == application.id ? application.id : nil
        var failureMessage: String?
        notifier.prepare()

        do {
            if let installed = try await performVisibleUpdate(application) {
                notifier.notify("「\(application.name)」已更新", "已更新到 \(installed.versionSummary)。")
            }
        } catch {
            failureMessage = error.localizedDescription
            notifier.notify("「\(application.name)」更新失败", error.localizedDescription)
        }

        if let selectionToRestore, selectedApplicationID == nil,
            applications.contains(where: { $0.id == selectionToRestore })
        {
            selectedApplicationID = selectionToRestore
        }
        if let failureMessage {
            alertMessage = failureMessage
        }
    }

    /// Returns the installed record, or nil when the update did not settle on disk.
    @discardableResult
    private func performVisibleUpdate(_ application: AppRecord) async throws -> AppRecord? {
        let applicationID = application.id
        guard updatingApplicationIDs.insert(applicationID).inserted else { return nil }
        let state = updateStatesByID[applicationID] ?? ApplicationUpdateState()
        if updateStatesByID[applicationID] == nil { updateStatesByID[applicationID] = state }
        state.begin()

        do {
            try await performCoordinatorUpdate(application, state: state)
            state.report(
                UpdateProgress(
                    fractionCompleted: 1,
                    status: "正在完成…"
                ))
            let diskRecord = await waitForInstalledDiskRecord(application)
            guard let diskRecord else {
                clearUpdateProgress(for: application)
                return nil
            }
            try? await Task.sleep(for: .milliseconds(300))
            return finishUpdating(application, diskRecord: diskRecord)
        } catch {
            clearUpdateProgress(for: application)
            if !(error is CancellationError) {
                updateStatesByID[applicationID]?.fail(error.localizedDescription)
            }
            throw error
        }
    }

    private func finishUpdating(_ application: AppRecord, diskRecord: AppRecord) -> AppRecord? {
        let installed = applyInstalledDiskRecord(diskRecord, replacing: application)
        clearUpdateProgress(for: application)
        if let installed {
            updateStatesByID[installed.id]?.succeed(version: installed.versionSummary)
        }
        return installed
    }

    private func clearUpdateProgress(for application: AppRecord) {
        updateStatesByID[application.id]?.finish()
        updatingApplicationIDs.remove(application.id)
        if !applications.contains(where: { $0.id == application.id }) {
            updateStatesByID[application.id] = nil
        }
    }

    private func performCoordinatorUpdate(
        _ application: AppRecord, state: ApplicationUpdateState
    ) async throws {
        let relay = UpdateProgressRelay()
        let consumeProgress = Task { @MainActor in
            for await progress in relay.stream {
                state.report(progress)
                recordPackageSize(from: progress, for: application)
            }
        }

        do {
            try await coordinator.update(application) { progress in
                relay.submit(progress)
            }
            relay.finish()
            await consumeProgress.value
        } catch {
            relay.finish()
            await consumeProgress.value
            throw error
        }
    }

    /// Only downloads report a total, which is the package size even when the check
    /// could not learn it, e.g. for a Homebrew cask hosted outside GitHub.
    private func recordPackageSize(from progress: UpdateProgress, for application: AppRecord) {
        guard let total = progress.totalBytes, total > 0,
            let index = applications.firstIndex(where: { $0.id == application.id }),
            applications[index].packageByteCount != total
        else { return }
        applications[index].packageByteCount = total
        persistSnapshot()
    }

    private func waitForInstalledDiskRecord(_ application: AppRecord) async -> AppRecord? {
        let applicationURL = application.applicationURL
        let rules = UpdateSourceRuleStore.shared.current()
        guard FileManager.default.fileExists(atPath: applicationURL.path),
            ApplicationScanner.makeRecord(from: applicationURL, rules: rules) != nil
        else {
            return nil
        }

        for attempt in 0..<48 {
            if Task.isCancelled { return nil }
            if let disk = ApplicationScanner.makeRecord(from: applicationURL, rules: rules) {
                let versionChanged =
                    disk.currentVersion != application.currentVersion
                    || disk.buildVersion != application.buildVersion
                if versionChanged {
                    return disk
                }
            }
            if attempt < 47 {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        return nil
    }

    @discardableResult
    private func applyInstalledDiskRecord(
        _ disk: AppRecord, replacing application: AppRecord
    ) -> AppRecord? {
        guard
            let index = applications.firstIndex(where: {
                $0.id == application.id || $0.bundleIdentifier == application.bundleIdentifier
            })
        else {
            return nil
        }

        var record = Self.installedDiskRecord(disk, replacing: application, installedAt: .now)
        record.installedUpdateConfiguration = application.updateConfiguration

        applications[index] = record
        persistSnapshot()
        return record
    }

    private func persistIgnoredBundleIdentifiers() {
        userDefaults.set(
            ignoredBundleIdentifiers.sorted(),
            forKey: Self.ignoredBundleIdentifiersKey
        )
    }

    private static func ignoreIdentifier(for application: AppRecord) -> String {
        application.bundleIdentifier.lowercased()
    }

    private static func nativeAppStoreUpdateURL(for application: AppRecord) -> URL? {
        if application.requiresAppStoreUpdatePageHandoff {
            return URL(string: "macappstore://showUpdatesPage")
        }
        guard let sourceURL = application.updateConfiguration.feedURL else {
            return nil
        }
        return nativeAppStoreURL(from: sourceURL)
    }

    private static func nativeAppStoreURL(from sourceURL: URL) -> URL {
        guard
            let host = sourceURL.host?.lowercased(),
            host == "apps.apple.com" || host == "itunes.apple.com",
            var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
        else {
            return sourceURL
        }

        components.scheme = "macappstore"
        return components.url ?? sourceURL
    }

    private static func validSelection(
        _ currentSelection: AppRecord.ID?,
        in applications: [AppRecord],
        ignoring ignoredBundleIdentifiers: Set<String>
    ) -> AppRecord.ID? {
        if let currentSelection,
            applications.contains(where: { $0.id == currentSelection })
        {
            return currentSelection
        }
        return preferredSelection(in: applications, ignoring: ignoredBundleIdentifiers)
    }

    private static func preferredSelection(
        in applications: [AppRecord],
        ignoring ignoredBundleIdentifiers: Set<String>
    ) -> AppRecord.ID? {
        let ignoredIDs = Set(
            applications.lazy
                .filter { ignoredBundleIdentifiers.contains(ignoreIdentifier(for: $0)) }
                .map(\.id)
        )
        return applications.availableUpdates(ignoredIDs: ignoredIDs).first?.id
            ?? applications.installedApplications(ignoredIDs: ignoredIDs).first?.id
            ?? applications.ignoredUpdates(ignoredIDs: ignoredIDs).first?.id
    }
}
