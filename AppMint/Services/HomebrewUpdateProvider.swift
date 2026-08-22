import Foundation

struct HomebrewUpdateProvider: Sendable {
  func enrich(_ applications: [AppRecord]) async -> [AppRecord] {
    guard let brewURL = HomebrewCLI.executableURL else {
      return applications
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
        BrewOutdatedResponse.self, from: await outdatedOutput.data)
      let outdatedByToken = Dictionary(
        uniqueKeysWithValues: outdated.casks.compactMap { item in
          item.token.map { ($0, item) }
        })

      var caskByTargetPath: [String: BrewCask] = [:]
      for cask in info.casks {
        for artifact in cask.artifacts where artifact.isApplication {
          guard let target = artifact.target else { continue }
          caskByTargetPath[URL(fileURLWithPath: target).standardizedFileURL.path] = cask
        }
      }

      return applications.map { application in
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
          Self.shouldClaimInstalledCask(
            source: application.source,
            hasCheckableFeed: application.sourceURL != nil,
            brewHasUpdate: brewHasUpdate
          )
        else {
          return application
        }

        var application = application
        application.source = .homebrew
        application.sourceIdentifier = cask.token
        application.homepageURL = cask.homepage.flatMap(URL.init(string:))
        application.sourceURL = application.homepageURL
        application.latestVersion = remoteVersion == "latest" ? nil : remoteVersion
        application.releaseNotes = nil
        application.status = Self.resolvedStatus(
          currentVersion: application.currentVersion,
          remoteVersion: remoteVersion,
          brewReportsOutdated: outdatedItem != nil,
          autoUpdates: cask.autoUpdates,
          buildVersion: application.buildVersion
        )
        application.canAutomaticallyUpdate = application.status == .updateAvailable

        return application
      }
    } catch is CancellationError {
      return applications
    } catch {
      return applications
    }
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
    brewReportsOutdated: Bool,
    autoUpdates: Bool?,
    buildVersion: String? = nil
  ) -> UpdateStatus {
    if remoteVersion == "latest" {
      return .selfManaged
    }

    if brewReportsOutdated,
      VersionComparator.isNewer(remoteVersion, than: currentVersion, build: buildVersion)
    {
      return .updateAvailable
    }

    if autoUpdates == true {
      return .selfManaged
    }

    return .upToDate
  }

  static func shouldClaimInstalledCask(
    source: UpdateSource,
    hasCheckableFeed: Bool,
    brewHasUpdate: Bool
  ) -> Bool {
    if brewHasUpdate {
      return true
    }

    switch source {
    case .appStore, .electronBuilder, .tauri, .vscodeUpdater, .releaseJSON:
      return false
    case .sparkle:
      return !hasCheckableFeed
    case .homebrew, .selfManaged:
      return true
    }
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
}

private struct BrewCask: Decodable, Sendable {
  let token: String
  let version: String
  let autoUpdates: Bool?
  let homepage: String?
  let artifacts: [BrewArtifact]

  enum CodingKeys: String, CodingKey {
    case token
    case version
    case autoUpdates = "auto_updates"
    case homepage
    case artifacts
  }
}

private struct BrewArtifact: Decodable, Sendable {
  let isApplication: Bool
  let target: String?

  enum CodingKeys: String, CodingKey {
    case app
    case target
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    isApplication = container.contains(.app)
    target = try container.decodeIfPresent(String.self, forKey: .target)
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
