import Foundation

struct HomebrewUpdateProvider: Sendable {
  private let cache = SnapshotCache()

  func enrich(_ applications: [AppRecord]) async -> [AppRecord] {
    guard let snapshot = await loadSnapshot() else {
      return applications
    }
    return applications.map { snapshot.applying(to: $0) }
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

  /// Prefer Homebrew when brew itself has an update. Otherwise keep a working
  /// first-party protocol, and only fall back to Homebrew if that check failed
  /// or the app has no other protocol.
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
    case .checking:
      switch source {
      case .sparkle:
        return !hasCheckableFeed
      case .homebrew, .selfManaged:
        return true
      case .appStore, .electronBuilder, .tauri, .vscodeUpdater, .releaseJSON, .githubReleases:
        return false
      }
    case .unavailable, .selfManaged:
      return true
    case .updateAvailable, .upToDate:
      return false
    }
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

  private func loadSnapshot() async -> Snapshot? {
    if let snapshot = cache.snapshot() {
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
      let snapshot = Snapshot(
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
}

private struct Snapshot {
  private var caskByTargetPath: [String: BrewCask]
  private var outdatedByToken: [String: BrewOutdatedCask]

  init(
    info: BrewInfoResponse,
    outdated: BrewOutdatedResponse,
    packageApplicationPaths: [String: [String]]
  ) {
    var caskByTargetPath: [String: BrewCask] = [:]
    for cask in info.casks {
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

    var outdatedByToken: [String: BrewOutdatedCask] = [:]
    for item in outdated.casks {
      guard let token = item.token else { continue }
      outdatedByToken[token] = item
    }
    self.outdatedByToken = outdatedByToken
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
    application.source = .homebrew
    application.sourceIdentifier = cask.token
    if application.homepageURL == nil {
      application.homepageURL = cask.homepage.flatMap(URL.init(string:))
    }
    application.sourceURL = application.homepageURL ?? cask.homepage.flatMap(URL.init(string:))
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
    application.canAutomaticallyUpdate = application.status == .updateAvailable
    return application
  }
}

private final class SnapshotCache: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Snapshot?
  private var storedAt: Date?
  private let timeToLive: TimeInterval = 20

  func snapshot() -> Snapshot? {
    lock.lock()
    defer { lock.unlock() }
    guard let stored, let storedAt, Date().timeIntervalSince(storedAt) < timeToLive else {
      return nil
    }
    return stored
  }

  func store(_ snapshot: Snapshot) {
    lock.lock()
    stored = snapshot
    storedAt = Date()
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

private struct BrewInfoResponse: Decodable, Sendable {
  let casks: [BrewCask]

  var packageReceiptIdentifiers: Set<String> {
    Set(casks.flatMap(\.packageReceiptIdentifiers))
  }
}

private struct BrewCask: Decodable, Sendable {
  let token: String
  let version: String
  let homepage: String?
  let artifacts: [BrewArtifact]

  enum CodingKeys: String, CodingKey {
    case token
    case version
    case homepage
    case artifacts
  }

  var packageReceiptIdentifiers: [String] {
    artifacts.flatMap(\.packageReceiptIdentifiers)
  }
}

private struct BrewArtifact: Decodable, Sendable {
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

private struct BrewUninstallArtifact: Decodable, Sendable {
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

private struct BrewOutdatedResponse: Decodable, Sendable {
  let casks: [BrewOutdatedCask]
}

private struct BrewOutdatedCask: Decodable, Sendable {
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
