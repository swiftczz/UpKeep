import Foundation

struct HomebrewUpdateProvider: Sendable {
  private let cache = SnapshotCache()
  var fetchData: @Sendable (URL) async throws -> Data? = { try await UpdateHTTP.successfulData(from: $0) }

  func enrich(_ applications: [AppRecord]) async -> [AppRecord] {
    await enrich(applications, cachePolicy: .allowed)
  }

  func enrich(
    _ applications: [AppRecord],
    cachePolicy: UpdateCachePolicy
  ) async -> [AppRecord] {
    guard let snapshot = await loadSnapshot(cachePolicy: cachePolicy) else {
      return applications
    }
    let claimed = applications.map { snapshot.applying(to: $0) }
    return await fillingGitHubReleaseMetadata(claimed, snapshot: snapshot)
  }

  func upgrade(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    guard let brewURL = HomebrewCLI.executableURL,
      let token = application.sourceIdentifier,
      application.canAutomaticallyUpdate
    else {
      throw ProcessRunnerError.failed(status: 1, message: "此应用不能由 Homebrew 自动更新。")
    }

    progress(.indeterminate("正在更新…"))
    let parser = HomebrewOutputProgressParser()
    _ = try await ProcessRunner.run(
      executableURL: brewURL,
      arguments: ["upgrade", "--cask", "--greedy-auto-updates", token],
      captureTTY: true,
      onOutput: { chunk in
        progress(parser.consuming(chunk))
      }
    )
    progress(UpdateProgress(fractionCompleted: 1, status: "正在完成…"))
  }

  static func resolvedStatus(
    currentVersion: String,
    remoteVersion: String,
    buildVersion: String? = nil
  ) -> UpdateStatus {
    if remoteVersion == "latest" {
      return .selfManaged
    }

    if VersionComparator.isNewer(remoteVersion, than: currentVersion, build: buildVersion) {
      return .updateAvailable
    }

    return .upToDate
  }

  static func homepageURL(caskHomepage: String?, existing: URL?) -> URL? {
    if let homepage = caskHomepage?.nonBlankValue, let url = URL(string: homepage) {
      return url
    }
    return existing
  }

  /// Prefer Homebrew when brew itself has an update. Otherwise keep a known
  /// first-party update that is already available. For installed apps, show
  /// Homebrew while retaining first-party metadata for release notes and checks.
  static func shouldClaimInstalledCask(
    source: UpdateSource,
    status: UpdateStatus,
    hasCheckableFeed: Bool,
    brewHasUpdate: Bool
  ) -> Bool {
    if source == .appStore {
      return false
    }
    if brewHasUpdate {
      return true
    }

    switch status {
    case .updateAvailable where source.canBeAlternateUpdateSource && hasCheckableFeed:
      return false
    case .checking, .unavailable, .selfManaged, .upToDate, .updateAvailable:
      return true
    }
  }

  static func keepsKnownFirstPartyInstall(_ application: AppRecord, brewHasUpdate: Bool) -> Bool {
    application.lastInstalledAt != nil
      && application.source.canBeAlternateUpdateSource
      && !application.needsUpdate
      && !brewHasUpdate
  }

  static func mergeAlternateCheckResult(
    _ checked: AppRecord,
    intoHomebrew application: AppRecord
  ) -> AppRecord {
    var merged = application
    merged.rememberAlternateUpdateSource(from: checked)
    if merged.homepageURL == nil {
      merged.homepageURL = checked.homepageURL
    }

    if checked.needsUpdate && !application.needsUpdate {
      var alternate = checked
      alternate.homebrewCaskToken = application.homebrewManagedCaskToken
      alternate.lastInstalledAt = application.lastInstalledAt
      return alternate
    }

    if checked.latestVersion != nil
      && checked.latestVersion?.split(separator: ",").first == application.latestVersion?.split(separator: ",").first {
      if checked.releaseNotes?.nonBlankValue != nil {
        merged.releaseNotes = checked.releaseNotes
        merged.releaseNotesURL = checked.releaseNotesURL
      } else if merged.releaseNotes?.nonBlankValue == nil, checked.releaseNotesURL != nil {
        merged.releaseNotesURL = checked.releaseNotesURL
      }
      if checked.releaseDate != nil {
        merged.releaseDate = checked.releaseDate
      }
    }

    if merged.latestVersion == nil {
      merged.latestVersion = checked.latestVersion
    }
    if merged.latestBuildVersion == nil {
      merged.latestBuildVersion = checked.latestBuildVersion
    }
    if merged.packageByteCount == nil {
      merged.packageByteCount = checked.packageByteCount
    }
    return merged
  }

  static func applicationPaths(inPackageFileList fileList: String) -> [String] {
    var paths = Set<String>()

    for line in fileList.split(whereSeparator: \.isNewline) {
      let components = line.split(separator: "/", omittingEmptySubsequences: true)
      guard let appIndex = components.firstIndex(where: {
        $0.lowercased().hasSuffix(".app")
      }) else {
        continue
      }

      let appComponents = components[...appIndex]
      paths.insert("/" + appComponents.joined(separator: "/"))
    }

    return paths.sorted()
  }

  private func loadSnapshot(cachePolicy: UpdateCachePolicy) async -> HomebrewSnapshot? {
    if cachePolicy == .allowed, let snapshot = cache.snapshot() {
      return snapshot
    }
    guard let brewURL = HomebrewCLI.executableURL else {
      return nil
    }

    do {
      async let infoOutput = ProcessRunner.run(
        executableURL: brewURL,
        arguments: ["info", "--json=v2", "--installed", "--cask"]
      )
      async let outdatedOutput = ProcessRunner.run(
        executableURL: brewURL,
        arguments: ["outdated", "--cask", "--json=v2"]
      )

      let info = try JSONDecoder().decode(BrewInfoResponse.self, from: await infoOutput.data)
      let outdated = try JSONDecoder().decode(
        BrewOutdatedResponse.self,
        from: await outdatedOutput.data
      )
      let packageApplicationPaths = await loadPackageApplicationPaths(
        for: info.packageReceiptIdentifiers
      )
      let snapshot = HomebrewSnapshot(
        info: info,
        outdated: outdated,
        packageApplicationPaths: packageApplicationPaths
      )
      cache.store(snapshot)
      return snapshot
    } catch is CancellationError {
      return nil
    } catch {
      return nil
    }
  }

  private func loadPackageApplicationPaths(
    for receiptIdentifiers: Set<String>
  ) async -> [String: [String]] {
    guard !receiptIdentifiers.isEmpty else { return [:] }

    return await withTaskGroup(of: (String, [String])?.self) { group in
      for identifier in receiptIdentifiers {
        group.addTask {
          do {
            let output = try await ProcessRunner.run(
              executableURL: URL(fileURLWithPath: "/usr/sbin/pkgutil"),
              arguments: ["--files", identifier]
            )
            return (
              identifier,
              Self.applicationPaths(inPackageFileList: output.standardOutput)
            )
          } catch {
            return nil
          }
        }
      }

      var pathsByReceipt: [String: [String]] = [:]
      for await result in group {
        guard let (identifier, paths) = result, !paths.isEmpty else { continue }
        pathsByReceipt[identifier] = paths
      }
      return pathsByReceipt
    }
  }

  func fillingGitHubReleaseMetadata(
    _ applications: [AppRecord],
    snapshot: HomebrewSnapshot
  ) async -> [AppRecord] {
    // Reuse the same release response for asset sizes and notes, including apps
    // with multiple assets in a single release. Cache empty responses briefly too.
    var requested = Set<URL>()
    var urls: [URL] = []
    for application in applications where application.source == .homebrew {
      guard application.packageByteCount == nil || application.releaseNotes?.nonBlankValue == nil,
        let token = application.sourceIdentifier,
        let download = snapshot.gitHubReleaseDownload(for: token), let url = download.apiURL,
        requested.insert(url).inserted, cache.releaseData(for: url) == nil else { continue }
      urls.append(url)
    }
    await withTaskGroup(of: (URL, Data, Bool).self) { group in
      var pending = urls.makeIterator()
      let fetchData = fetchData
      func enqueue(_ url: URL) {
        group.addTask {
          do {
            let data = try await fetchData(url)
            return (url, data.flatMap { $0.count <= 5_000_000 ? $0 : nil } ?? Data(), false)
          } catch {
            return (url, Data(), error is GitHubAPIError)
          }
        }
      }
      for _ in 0..<4 {
        if let url = pending.next() { enqueue(url) }
      }
      var limited = false
      for await (url, data, rateLimited) in group {
        if Task.isCancelled { group.cancelAll(); break }
        cache.store(releaseData: data, for: url)
        limited = limited || rateLimited
        if !limited, let next = pending.next() { enqueue(next) }
      }
    }
    return applications.map { application in
      guard application.source == .homebrew, let token = application.sourceIdentifier,
        let download = snapshot.gitHubReleaseDownload(for: token), let url = download.apiURL,
        let data = cache.releaseData(for: url) else { return application }
      return Self.applyingGitHubRelease(data, download: download, to: application)
    }
  }

  static func applyingGitHubRelease(_ data: Data, download: GitHubReleaseDownload,
    to application: AppRecord) -> AppRecord {
    var result = application
    guard let release = GitHubReleaseManifest.parse(data),
      let version = application.latestVersion?.split(separator: ",").first,
      String(version) == release.version,
      release.assets.contains(where: { $0.downloadURL == URL(string:
        "https://github.com/\(download.owner)/\(download.repository)/releases/download/\(download.tag)/\(download.fileName)") })
    else { return result }
    if result.packageByteCount == nil {
      result.packageByteCount = GitHubReleaseManifest.packageByteCount(named: download.fileName, in: data)
    }
    if result.releaseNotes?.nonBlankValue == nil, let notes = release.releaseNotes?.nonBlankValue {
      result.releaseNotes = notes
      result.releaseNotesURL = URL(string:
        "https://github.com/\(download.owner)/\(download.repository)/releases/tag/\(download.tag)")
      result.releaseDate = result.releaseDate ?? release.releaseDate
    }
    return result
  }

}

struct HomebrewSnapshot {
  private var caskByTargetPath: [String: BrewCask]
  private var downloadURLByToken: [String: String]
  private var outdatedByToken: [String: BrewOutdatedCask]

  init(
    info: BrewInfoResponse,
    outdated: BrewOutdatedResponse,
    packageApplicationPaths: [String: [String]]
  ) {
    var caskByTargetPath: [String: BrewCask] = [:]
    var downloadURLByToken: [String: String] = [:]
    for cask in info.casks {
      if let downloadURL = cask.downloadURL {
        downloadURLByToken[cask.token] = downloadURL
      }
      for artifact in cask.artifacts where artifact.isApplication {
        guard let target = artifact.target else { continue }
        let path = URL(fileURLWithPath: target).standardizedFileURL.path
        caskByTargetPath[path] = cask
      }
      for receiptIdentifier in cask.packageReceiptIdentifiers {
        for target in packageApplicationPaths[receiptIdentifier] ?? [] {
          let path = URL(fileURLWithPath: target).standardizedFileURL.path
          caskByTargetPath[path] = cask
        }
      }
    }
    self.caskByTargetPath = caskByTargetPath
    self.downloadURLByToken = downloadURLByToken

    var outdatedByToken: [String: BrewOutdatedCask] = [:]
    for item in outdated.casks {
      guard let token = item.token else { continue }
      outdatedByToken[token] = item
    }
    self.outdatedByToken = outdatedByToken
  }

  func gitHubReleaseDownload(for token: String) -> GitHubReleaseDownload? {
    downloadURLByToken[token].flatMap(GitHubReleaseDownload.parse)
  }

  func applying(to application: AppRecord) -> AppRecord {
    guard application.source != .appStore,
      let cask = caskByTargetPath[application.applicationURL.standardizedFileURL.path]
    else {
      return application
    }

    let outdatedItem = outdatedByToken[cask.token]
    let remoteVersion = outdatedItem?.currentVersion ?? cask.version
    let brewHasUpdate =
      outdatedItem != nil
      && remoteVersion != "latest"
      && VersionComparator.isNewer(
        remoteVersion,
        than: application.currentVersion,
        build: application.buildVersion
      )

    let detectedApplication = application
    var application = application
    application.rememberAlternateUpdateSource(from: detectedApplication)
    application.homebrewCaskToken = cask.token

    if HomebrewUpdateProvider.keepsKnownFirstPartyInstall(application, brewHasUpdate: brewHasUpdate) {
      return application
    }

    guard
      HomebrewUpdateProvider.shouldClaimInstalledCask(
        source: application.source,
        status: application.status,
        hasCheckableFeed: application.sourceURL != nil,
        brewHasUpdate: brewHasUpdate
      )
    else {
      return application
    }

    return claiming(cask, remoteVersion: remoteVersion, onto: application)
  }

  private func claiming(
    _ cask: BrewCask,
    remoteVersion: String,
    onto application: AppRecord
  ) -> AppRecord {
    var application = application
    let previousNotesVersion = application.latestVersion
    let remoteIsNewer = VersionComparator.isNewer(
      remoteVersion,
      than: application.currentVersion,
      build: application.buildVersion
    )
    let preservedPackageByteCount =
      application.source == .homebrew
      && (application.latestVersion == remoteVersion || !remoteIsNewer)
      ? application.packageByteCount
      : nil
    application.source = .homebrew
    application.sourceIdentifier = cask.token
    application.homebrewCaskToken = cask.token
    application.homepageURL = HomebrewUpdateProvider.homepageURL(
      caskHomepage: cask.homepage,
      existing: application.homepageURL
    )
    application.sourceURL = application.homepageURL
    application.packageByteCount = preservedPackageByteCount
    application.status = HomebrewUpdateProvider.resolvedStatus(
      currentVersion: application.currentVersion,
      remoteVersion: remoteVersion,
      buildVersion: application.buildVersion
    )
    switch application.status {
    case .updateAvailable:
      application.latestVersion = remoteVersion
    case .upToDate:
      application.latestVersion = application.currentVersion
    case .selfManaged, .checking, .unavailable:
      application.latestVersion = remoteVersion == "latest" ? nil : remoteVersion
    }
    if application.latestVersion != previousNotesVersion {
      application.releaseNotes = nil
      application.releaseNotesURL = nil
      application.releaseDate = nil
    }
    application.canAutomaticallyUpdate = application.status == .updateAvailable
    return application
  }
}

private final class SnapshotCache: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: HomebrewSnapshot?
  private var storedAt: Date?
  private var releases: [URL: (data: Data, date: Date)] = [:]
  private let timeToLive: TimeInterval = 5 * 60

  func snapshot() -> HomebrewSnapshot? {
    lock.lock()
    defer { lock.unlock() }
    guard let stored, let storedAt, Date().timeIntervalSince(storedAt) < timeToLive else {
      return nil
    }
    return stored
  }

  func store(_ snapshot: HomebrewSnapshot) {
    lock.lock()
    stored = snapshot
    storedAt = Date()
    lock.unlock()
  }

  func releaseData(for url: URL) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = releases[url], Date().timeIntervalSince(entry.date) < timeToLive else { return nil }
    return entry.data
  }

  func store(releaseData: Data, for url: URL) {
    lock.lock()
    releases[url] = (releaseData, Date())
    lock.unlock()
  }

}

final class HomebrewOutputProgressParser: @unchecked Sendable {
  private let lock = NSLock()
  private var pending = ""
  private var progress = UpdateProgress.indeterminate("正在更新…")

  func consuming(_ chunk: String) -> UpdateProgress {
    lock.lock()
    defer { lock.unlock() }

    pending += chunk
    if pending.count > 8_192 {
      pending.removeFirst(pending.count - 4_096)
    }

    let text = Self.stripANSI(pending)
    if text.localizedCaseInsensitiveContains("==> Installing")
      || text.localizedCaseInsensitiveContains("==> Purging")
    {
      progress = UpdateProgress(fractionCompleted: 0.92, status: "正在安装…")
    } else if let percent = Self.lastPercent(in: text) {
      progress = UpdateProgress(
        fractionCompleted: min(percent / 100, 0.9),
        status: "正在下载…"
      )
    } else if let ratio = Self.lastSizeRatio(in: text) {
      progress = UpdateProgress(
        fractionCompleted: min(ratio, 0.9),
        status: "正在下载…"
      )
    } else if text.localizedCaseInsensitiveContains("==> Downloading")
      || text.localizedCaseInsensitiveContains("Downloading")
    {
      progress = .indeterminate("正在下载…")
    }
    return progress
  }

  private static func stripANSI(_ text: String) -> String {
    text.replacing(#/\u{001B}\[[\d;?]*[A-Za-z]/#, with: "")
  }

  private static func lastPercent(in chunk: String) -> Double? {
    let matches = chunk.matches(of: /(\d{1,3}(?:\.\d+)?)%/)
    guard let match = matches.last, let value = Double(match.1), value <= 100 else {
      return nil
    }
    return value
  }

  private static func lastSizeRatio(in chunk: String) -> Double? {
    let matches = chunk.matches(
      of: /(\d+(?:\.\d+)?)\s*([KMGT]?B)\s*\/\s*(\d+(?:\.\d+)?)\s*([KMGT]?B)/
    )
    guard let match = matches.last,
      let fetched = Self.byteCount(value: String(match.1), unit: String(match.2)),
      let total = Self.byteCount(value: String(match.3), unit: String(match.4)),
      total > 0
    else {
      return nil
    }
    return min(fetched / total, 1)
  }

  private static func byteCount(value: String, unit: String) -> Double? {
    guard let amount = Double(value) else { return nil }
    let multiplier: Double
    switch unit.uppercased() {
    case "B":
      multiplier = 1
    case "KB":
      multiplier = 1_000
    case "MB":
      multiplier = 1_000_000
    case "GB":
      multiplier = 1_000_000_000
    case "TB":
      multiplier = 1_000_000_000_000
    default:
      return nil
    }
    return amount * multiplier
  }
}

struct BrewInfoResponse: Decodable, Sendable {
  let casks: [BrewCask]

  var packageReceiptIdentifiers: Set<String> {
    Set(casks.flatMap(\.packageReceiptIdentifiers))
  }
}

struct BrewCask: Decodable, Sendable {
  let token: String
  let version: String
  let homepage: String?
  let url: String?
  let artifacts: [BrewArtifact]

  enum CodingKeys: String, CodingKey {
    case token
    case version
    case homepage
    case url
    case artifacts
  }

  var downloadURL: String? {
    url?.nonBlankValue
  }

  var packageReceiptIdentifiers: [String] {
    artifacts.flatMap(\.packageReceiptIdentifiers)
  }
}

struct BrewArtifact: Decodable, Sendable {
  let isApplication: Bool
  let target: String?
  let packageReceiptIdentifiers: [String]

  enum CodingKeys: String, CodingKey {
    case app
    case target
    case uninstall
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    isApplication = container.contains(.app)
    target = try container.decodeIfPresent(String.self, forKey: .target)
    packageReceiptIdentifiers = try container.decodeIfPresent(
      [BrewUninstallArtifact].self,
      forKey: .uninstall
    )?.flatMap(\.packageReceiptIdentifiers) ?? []
  }
}

struct BrewUninstallArtifact: Decodable, Sendable {
  let packageReceiptIdentifiers: [String]

  private enum CodingKeys: String, CodingKey {
    case pkgutil
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let identifier = try? container.decode(String.self, forKey: .pkgutil) {
      packageReceiptIdentifiers = [identifier]
    } else {
      packageReceiptIdentifiers =
        (try? container.decode([String].self, forKey: .pkgutil)) ?? []
    }
  }
}

struct BrewOutdatedResponse: Decodable, Sendable {
  let casks: [BrewOutdatedCask]
}

struct BrewOutdatedCask: Decodable, Sendable {
  let name: String?
  let legacyToken: String?
  let currentVersion: String?

  var token: String? {
    name ?? legacyToken
  }

  enum CodingKeys: String, CodingKey {
    case name
    case legacyToken = "token"
    case currentVersion = "current_version"
  }
}
