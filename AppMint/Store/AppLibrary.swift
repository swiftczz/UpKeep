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
  @ObservationIgnored private let userDefaults: UserDefaults
  private var hasLoaded: Bool
  private var refreshRequested = false

  private static let ignoredBundleIdentifiersKey = "ignoredUpdateBundleIdentifiers"

  init(
    applications: [AppRecord] = [],
    scanner: any ApplicationScanning = ApplicationScanner(),
    coordinator: any UpdateCoordinating = UpdateCoordinator(),
    userDefaults: UserDefaults = .standard
  ) {
    let ignoredBundleIdentifiers = Set(
      userDefaults.stringArray(forKey: Self.ignoredBundleIdentifiersKey) ?? []
    )
    self.applications = applications
    self.scanner = scanner
    self.coordinator = coordinator
    self.userDefaults = userDefaults
    self.ignoredBundleIdentifiers = ignoredBundleIdentifiers
    self.hasLoaded = !applications.isEmpty
    self.selectedApplicationID = Self.preferredSelection(
      in: applications,
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

  func loadIfNeeded() async {
    guard !hasLoaded else { return }
    hasLoaded = true
    await refresh()
  }

  func refresh() async {
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
    phase = .scanning
    alertMessage = nil

    let scannedApplications = await scanner.scan()

    guard !scannedApplications.isEmpty else {
      applications = []
      selectedApplicationID = nil
      phase = .idle
      lastCheckedAt = .now
      return
    }

    phase = .checking
    let checkedApplications = await coordinator.check(scannedApplications)
    applications = checkedApplications
    selectedApplicationID = Self.validSelection(
      previousSelection,
      in: checkedApplications,
      ignoring: ignoredBundleIdentifiers
    )
    lastCheckedAt = .now
    phase = .idle
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
    do {
      _ = try await performVisibleUpdate(application)
    } catch {
      alertMessage = error.localizedDescription
    }

    await refreshIfNoUpdatesInFlight()
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
      finishUpdating(application, diskRecord: nil)
      throw error
    }
  }

  private func finishUpdating(_ application: AppRecord, diskRecord: AppRecord?) {
    if let diskRecord {
      applyInstalledDiskRecord(diskRecord, replacing: application)
    }
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

    if let latestVersion = application.latestVersion,
      VersionComparator.isNewer(latestVersion, than: disk.currentVersion)
    {
      record.status = .updateAvailable
      record.canAutomaticallyUpdate = application.canAutomaticallyUpdate
    } else {
      record.status = .upToDate
      record.canAutomaticallyUpdate = false
    }

    applications[index] = record
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
