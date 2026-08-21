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
  private(set) var ignoredBundleIdentifiers: Set<String>

  private let scanner: any ApplicationScanning
  private let coordinator: any UpdateCoordinating
  @ObservationIgnored private let userDefaults: UserDefaults
  private var hasLoaded: Bool

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
    applications.filter { $0.needsUpdate && !isUpdateIgnored($0) }
  }

  var ignoredApplicationIDs: Set<AppRecord.ID> {
    Set(
      applications.lazy
        .filter(isUpdateIgnored)
        .map(\.id)
    )
  }

  var automaticUpdates: [AppRecord] {
    availableUpdates.filter {
      $0.source == .homebrew && $0.canAutomaticallyUpdate
    }
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
    guard phase == .idle else { return }

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

    if application.needsUpdate,
      application.source == .appStore,
      let sourceURL = application.sourceURL
    {
      return Self.nativeAppStoreURL(from: sourceURL)
    }

    return application.applicationURL
  }

  func updateAll() async {
    guard !automaticUpdates.isEmpty else { return }
    let updates = automaticUpdates
    var failures: [String] = []

    for application in updates {
      updatingApplicationIDs.insert(application.id)
      do {
        try await coordinator.update(application)
      } catch {
        failures.append("\(application.name)：\(error.localizedDescription)")
      }
      updatingApplicationIDs.remove(application.id)
    }

    if !failures.isEmpty {
      alertMessage = failures.joined(separator: "\n")
    }
    await refresh()
  }

  func reportOpeningFailure(for url: URL) {
    alertMessage = "无法打开 \(url.lastPathComponent)。"
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
    applications.first {
      $0.needsUpdate
        && !ignoredBundleIdentifiers.contains(ignoreIdentifier(for: $0))
    }?.id ?? applications.first?.id
  }
}
