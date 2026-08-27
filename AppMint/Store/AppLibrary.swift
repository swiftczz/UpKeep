import Foundation
import Observation

@MainActor
@Observable
final class AppLibrary {
  var applications: [AppRecord]
  var selectedApplicationID: AppRecord.ID?
  var phase: LibraryPhase = .idle
  var lastCheckedAt: Date?
  var alertMessage: String?
  private(set) var updatingApplicationIDs = Set<AppRecord.ID>()
  private(set) var updateProgressByID: [AppRecord.ID: UpdateProgress] = [:]
  private(set) var ignoredBundleIdentifiers: Set<String>

  private let scanner: any ApplicationScanning
  private let coordinator: any UpdateCoordinating
  @ObservationIgnored private let process: ApplicationProcessClient
  @ObservationIgnored private let userDefaults: UserDefaults
  @ObservationIgnored private let libraryStore: ApplicationLibraryStore
  @ObservationIgnored private var pendingCheckedApplications: [AppRecord] = []
  @ObservationIgnored private var pendingCheckedFlushTask: Task<Void, Never>?
  private var hasLoaded: Bool
  private var refreshRequested = false

  private static let ignoredBundleIdentifiersKey = "ignoredUpdateBundleIdentifiers"

  init(
    applications: [AppRecord] = [],
    scanner: any ApplicationScanning = ApplicationScanner(),
    coordinator: any UpdateCoordinating = UpdateCoordinator(),
    process: ApplicationProcessClient = .live,
    userDefaults: UserDefaults = .standard,
    libraryStore: ApplicationLibraryStore = .live()
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

    self.applications = loadedApplications
    self.scanner = scanner
    self.coordinator = coordinator
    self.process = process
    self.userDefaults = userDefaults
    self.libraryStore = libraryStore
    self.ignoredBundleIdentifiers = ignoredBundleIdentifiers
    self.hasLoaded = !applications.isEmpty
    self.lastCheckedAt = loadedCheckedAt
    self.selectedApplicationID = Self.preferredSelection(
      in: loadedApplications,
      ignoring: ignoredBundleIdentifiers
    )
  }

  var selectedApplication: AppRecord? {
    guard let selectedApplicationID else { return nil }
    return applications.first { $0.id == selectedApplicationID }
  }

  var availableUpdates: [AppRecord] {
    applications.availableUpdates(ignoredIDs: ignoredApplicationIDs)
  }

  var ignoredUpdates: [AppRecord] {
    applications.ignoredUpdates(ignoredIDs: ignoredApplicationIDs)
  }

  var ignoredApplicationIDs: Set<AppRecord.ID> {
    Set(
      applications.lazy
        .filter(isUpdateIgnored)
        .map(\.id)
    )
  }

  var automaticUpdates: [AppRecord] {
    availableUpdates.filter(\.canAutomaticallyUpdate)
  }

  func isRunning(_ application: AppRecord) -> Bool {
    process.isRunning(application)
  }

  func requiresRelaunchConfirmation(for application: AppRecord) -> Bool {
    application.needsUpdate
      && application.canAutomaticallyUpdate
      && isRunning(application)
  }

  func automaticUpdatesRequiringRelaunch() -> [AppRecord] {
    automaticUpdates.filter(isRunning)
  }

  var isRefreshing: Bool {
    phase != .idle
  }

  func isUpdateIgnored(_ application: AppRecord) -> Bool {
    ignoredBundleIdentifiers.contains(Self.ignoreIdentifier(for: application))
  }

  func ignoreUpdates(for applicationID: AppRecord.ID) {
    guard
      let application = applications.first(where: { $0.id == applicationID }),
      application.needsUpdate
    else {
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
    await refresh()
  }

  func refreshIfStale(after interval: TimeInterval = 60) async {
    guard hasLoaded, phase == .idle, updatingApplicationIDs.isEmpty else { return }
    if let lastCheckedAt, Date.now.timeIntervalSince(lastCheckedAt) < interval {
      return
    }
    await refresh()
  }

  func refreshReleaseMetadataIfNeeded(for applicationID: AppRecord.ID) async {
    guard phase == .idle,
      !updatingApplicationIDs.contains(applicationID),
      let existingIndex = applications.firstIndex(where: { $0.id == applicationID })
    else {
      return
    }

    let application = applications[existingIndex]
    guard application.releaseNotes == nil else {
      return
    }
    switch application.source {
    case .appStore, .electronBuilder, .tauri, .vscodeUpdater, .releaseJSON:
      break
    case .sparkle where application.sourceURL != nil:
      break
    case .homebrew, .selfManaged, .sparkle:
      return
    }

    let checked = await coordinator.check(application)
    guard !updatingApplicationIDs.contains(applicationID),
      let currentIndex = applications.firstIndex(where: { $0.id == applicationID })
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
    guard updatingApplicationIDs.isEmpty else { return }
    guard phase == .idle else {
      refreshRequested = true
      return
    }

    repeat {
      refreshRequested = false
      await performRefresh()
    } while refreshRequested
  }

  private func performRefresh() async {
    let previousSelection = selectedApplicationID
    let previousApplications = applications
    pendingCheckedFlushTask?.cancel()
    pendingCheckedFlushTask = nil
    pendingCheckedApplications.removeAll(keepingCapacity: true)
    phase = .scanning
    alertMessage = nil

    let scannedApplications = await scanner.scan()

    guard !scannedApplications.isEmpty else {
      applications = []
      selectedApplicationID = nil
      phase = .idle
      lastCheckedAt = .now
      persistSnapshot()
      return
    }

    publish(
      Self.mergeKeepingCheckResults(scannedApplications, previous: previousApplications),
      selecting: previousSelection
    )
    phase = .checking
    await Task.yield()

    let enrichedApplications = await coordinator.enrich(applications)
    publish(
      Self.mergeKeepingCheckResults(enrichedApplications, previous: applications),
      selecting: selectedApplicationID
    )

    let applicationsToCheck = applications
    let coordinator = coordinator
    await withTaskGroup(of: AppRecord.self) { group in
      for application in applicationsToCheck {
        group.addTask {
          await coordinator.check(application)
        }
      }

      for await checked in group {
        queueChecked(checked)
      }
    }
    flushPendingChecked()

    let claimedApplications = await coordinator.enrich(applications)
    publish(
      Self.mergeKeepingCheckResults(claimedApplications, previous: applications),
      selecting: selectedApplicationID
    )

    lastCheckedAt = .now
    phase = .idle
    persistSnapshot()
  }

  private func publish(_ applications: [AppRecord], selecting selection: AppRecord.ID?) {
    self.applications = applications
    selectedApplicationID = Self.validSelection(
      selection,
      in: applications,
      ignoring: ignoredBundleIdentifiers
    )
  }

  private func queueChecked(_ application: AppRecord) {
    pendingCheckedApplications.append(application)
    if pendingCheckedApplications.count >= 12 {
      flushPendingChecked()
      return
    }
    guard pendingCheckedFlushTask == nil else { return }
    pendingCheckedFlushTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(80))
      flushPendingChecked()
    }
  }

  private func flushPendingChecked() {
    pendingCheckedFlushTask?.cancel()
    pendingCheckedFlushTask = nil
    let pending = pendingCheckedApplications
    pendingCheckedApplications.removeAll(keepingCapacity: true)
    guard !pending.isEmpty else { return }

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

  static func mergeKeepingCheckResults(
    _ incoming: [AppRecord],
    previous: [AppRecord]
  ) -> [AppRecord] {
    let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
    return incoming.map { current in
      guard let previous = previousByID[current.id] else {
        return current
      }

      if current.source == .homebrew, current.status == .updateAvailable {
        return carryingMetadata(from: previous, onto: current)
      }

      let versionChanged =
        current.currentVersion != previous.currentVersion
        || current.buildVersion != previous.buildVersion
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

      if previous.source == current.source, previous.status != .checking {
        merged.status = previous.status
        merged.latestVersion = previous.latestVersion
        merged.latestBuildVersion = previous.latestBuildVersion
        merged.releaseNotes = previous.releaseNotes
        merged.releaseDate = previous.releaseDate
        merged.releaseNotesURL = previous.releaseNotesURL
        merged.canAutomaticallyUpdate = previous.canAutomaticallyUpdate
      }
      return carryingMetadata(from: previous, onto: merged)
    }
  }

  static func coalesceCheckResult(_ incoming: AppRecord, over existing: AppRecord) -> AppRecord {
    let result: AppRecord
    if existing.status == .updateAvailable {
      switch incoming.status {
      case .checking, .selfManaged, .unavailable:
        result = carryingPendingUpdate(from: existing, onto: incoming)
      default:
        result = incoming
      }
    } else {
      result = incoming
    }

    guard result.lastInstalledAt == nil else { return result }
    var merged = result
    merged.lastInstalledAt = existing.lastInstalledAt
    return merged
  }

  private static func carryingPendingUpdate(
    from previous: AppRecord,
    onto current: AppRecord
  ) -> AppRecord {
    guard previous.status == .updateAvailable, previous.hasNewerRelease(than: current) else {
      return carryingMetadata(from: previous, onto: current)
    }

    var merged = current
    merged.status = .updateAvailable
    merged.latestVersion = previous.latestVersion
    merged.latestBuildVersion = previous.latestBuildVersion
    merged.releaseNotes = previous.releaseNotes
    merged.releaseDate = previous.releaseDate
    merged.releaseNotesURL = previous.releaseNotesURL
    merged.canAutomaticallyUpdate =
      previous.source == current.source
      ? previous.canAutomaticallyUpdate
      : current.canAutomaticallyUpdate
    return carryingMetadata(from: previous, onto: merged)
  }

  private static func carryingMetadata(
    from previous: AppRecord,
    onto current: AppRecord
  ) -> AppRecord {
    var merged = current
    if merged.sourceURL == nil, previous.source == merged.source {
      merged.sourceURL = previous.sourceURL
    }
    if merged.homepageURL == nil {
      merged.homepageURL = previous.homepageURL
    }
    if merged.sourceIdentifier == nil, previous.source == merged.source {
      merged.sourceIdentifier = previous.sourceIdentifier
    }
    if merged.releaseNotes == nil {
      merged.releaseNotes = previous.releaseNotes
    }
    if merged.releaseDate == nil {
      merged.releaseDate = previous.releaseDate
    }
    if merged.releaseNotesURL == nil {
      merged.releaseNotesURL = previous.releaseNotesURL
    }
    if merged.latestBuildVersion == nil {
      merged.latestBuildVersion = previous.latestBuildVersion
    }
    if merged.lastInstalledAt == nil {
      merged.lastInstalledAt = previous.lastInstalledAt
    }
    return merged
  }

  func performPrimaryAction(for applicationID: AppRecord.ID) async -> URL? {
    guard let application = applications.first(where: { $0.id == applicationID }) else {
      return nil
    }

    if application.needsUpdate, application.canAutomaticallyUpdate {
      await update(application)
      return nil
    }

    return application.applicationURL
  }

  func appStoreURL(for applicationID: AppRecord.ID) -> URL? {
    guard
      let application = applications.first(where: { $0.id == applicationID }),
      application.source == .appStore,
      let sourceURL = application.sourceURL
    else {
      return nil
    }

    return Self.nativeAppStoreURL(from: sourceURL)
  }

  func updateAll() async {
    guard !automaticUpdates.isEmpty else { return }
    let updates = automaticUpdates
    var failures: [String] = []

    for application in updates {
      do {
        _ = try await performVisibleUpdate(application)
      } catch {
        failures.append("\(application.name)：\(error.localizedDescription)")
      }
    }

    if !failures.isEmpty {
      alertMessage = failures.joined(separator: "\n")
    }
    await refresh()
  }

  func reportOpeningFailure(for url: URL) {
    alertMessage = "无法打开 \(url.lastPathComponent)。"
  }

  private func update(_ application: AppRecord) async {
    let selectionToRestore = selectedApplicationID == application.id ? application.id : nil
    var failureMessage: String?

    do {
      _ = try await performVisibleUpdate(application)
    } catch {
      failureMessage = error.localizedDescription
    }

    await refreshIfNoUpdatesInFlight()

    if let selectionToRestore,
      applications.contains(where: { $0.id == selectionToRestore })
    {
      selectedApplicationID = selectionToRestore
    }
    if let failureMessage {
      alertMessage = failureMessage
    }
  }

  private func refreshIfNoUpdatesInFlight() async {
    guard updatingApplicationIDs.isEmpty else { return }
    await refresh()
  }

  @discardableResult
  private func performVisibleUpdate(_ application: AppRecord) async throws -> Bool {
    let applicationID = application.id
    updatingApplicationIDs.insert(applicationID)
    updateProgressByID[applicationID] = .indeterminate("正在更新…")

    do {
      try await performCoordinatorUpdate(application)
      let diskRecord = await waitForInstalledDiskRecord(application)
      updateProgressByID[applicationID] = UpdateProgress(
        fractionCompleted: 1,
        status: "正在完成…"
      )
      try? await Task.sleep(for: .milliseconds(300))
      finishUpdating(application, diskRecord: diskRecord)
      return diskRecord != nil
    } catch {
      clearUpdateProgress(for: application)
      throw error
    }
  }

  private func finishUpdating(_ application: AppRecord, diskRecord: AppRecord?) {
    if let diskRecord {
      applyInstalledDiskRecord(diskRecord, replacing: application)
    } else {
      rememberLocalInstall(of: application)
    }
    clearUpdateProgress(for: application)
  }

  private func clearUpdateProgress(for application: AppRecord) {
    updateProgressByID[application.id] = nil
    updatingApplicationIDs.remove(application.id)
  }

  private func performCoordinatorUpdate(_ application: AppRecord) async throws {
    let applicationID = application.id
    let (stream, continuation) = AsyncStream.makeStream(of: UpdateProgress.self)
    let consumeProgress = Task { @MainActor in
      for await progress in stream {
        guard self.updatingApplicationIDs.contains(applicationID) else { return }
        self.updateProgressByID[applicationID] = progress
      }
    }

    do {
      try await coordinator.update(application) { progress in
        continuation.yield(progress)
      }
      continuation.finish()
      await consumeProgress.value
    } catch {
      continuation.finish()
      await consumeProgress.value
      throw error
    }
  }

  private func waitForInstalledDiskRecord(_ application: AppRecord) async -> AppRecord? {
    let applicationURL = application.applicationURL
    guard FileManager.default.fileExists(atPath: applicationURL.path),
      ApplicationScanner.makeRecord(from: applicationURL) != nil
    else {
      return nil
    }

    for attempt in 0..<48 {
      if Task.isCancelled { return nil }
      if let disk = ApplicationScanner.makeRecord(from: applicationURL) {
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

  private func applyInstalledDiskRecord(_ disk: AppRecord, replacing application: AppRecord) {
    guard
      let index = applications.firstIndex(where: {
        $0.id == application.id || $0.bundleIdentifier == application.bundleIdentifier
      })
    else {
      return
    }

    var record = disk
    record.source = application.source
    record.appStorePlatform = application.appStorePlatform
    record.appStoreCountryCode = application.appStoreCountryCode
    record.sourceURL = application.sourceURL
    record.homepageURL = application.homepageURL
    record.releaseNotes = application.releaseNotes
    record.releaseDate = application.releaseDate
    record.releaseNotesURL = application.releaseNotesURL
    record.sourceIdentifier = application.sourceIdentifier
    record.latestVersion = application.latestVersion
    record.latestBuildVersion = application.latestBuildVersion
    record.lastInstalledAt = .now

    if application.hasNewerRelease(than: disk) {
      record.status = .updateAvailable
      record.canAutomaticallyUpdate = application.canAutomaticallyUpdate
    } else {
      record.status = .upToDate
      record.canAutomaticallyUpdate = false
    }

    applications[index] = record
    persistSnapshot()
  }

  private func rememberLocalInstall(of application: AppRecord) {
    guard FileManager.default.fileExists(atPath: application.applicationURL.path),
      let index = applications.firstIndex(where: {
        $0.id == application.id || $0.bundleIdentifier == application.bundleIdentifier
      })
    else {
      return
    }

    applications[index].lastInstalledAt = .now
    persistSnapshot()
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
      ?? applications.installedApplications().first?.id
      ?? applications.ignoredUpdates(ignoredIDs: ignoredIDs).first?.id
  }
}
