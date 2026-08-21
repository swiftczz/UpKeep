import Foundation

struct HomebrewUpdateProvider: Sendable {
  func enrich(_ applications: [AppRecord]) async -> [AppRecord] {
    guard let brewURL = Self.brewExecutableURL else {
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

        var application = application
        let outdatedItem = outdatedByToken[cask.token]
        let remoteVersion = outdatedItem?.currentVersion ?? cask.version

        application.source = .homebrew
        application.sourceIdentifier = cask.token
        application.homepageURL = cask.homepage.flatMap(URL.init(string:))
        application.sourceURL = application.homepageURL
        application.latestVersion = remoteVersion == "latest" ? nil : remoteVersion
        application.releaseNotes = nil
        application.canAutomaticallyUpdate = cask.autoUpdates != true
        application.status = Self.resolvedStatus(
          currentVersion: application.currentVersion,
          remoteVersion: remoteVersion,
          brewReportsOutdated: outdatedItem != nil,
          autoUpdates: cask.autoUpdates
        )

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
    guard let brewURL = Self.brewExecutableURL,
      let token = application.sourceIdentifier,
      application.canAutomaticallyUpdate
    else {
      throw ProcessRunnerError.failed(status: 1, message: "此应用不能由 Homebrew 自动更新。")
    }

    progress(.indeterminate("正在更新…"))
    let parser = HomebrewOutputProgressParser()
    _ = try await ProcessRunner.run(
      executableURL: brewURL,
      arguments: ["upgrade", "--cask", token],
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
    autoUpdates: Bool?
  ) -> UpdateStatus {
    if remoteVersion == "latest" {
      return .selfManaged
    }

    if brewReportsOutdated,
      VersionComparator.isNewer(remoteVersion, than: currentVersion)
    {
      return .updateAvailable
    }

    if autoUpdates == true {
      return .selfManaged
    }

    return .upToDate
  }

  private static var brewExecutableURL: URL? {
    let candidates = [
      "/opt/homebrew/bin/brew",
      "/usr/local/bin/brew",
    ]

    return
      candidates
      .first(where: FileManager.default.isExecutableFile(atPath:))
      .map(URL.init(fileURLWithPath:))
  }
}

final class HomebrewOutputProgressParser: @unchecked Sendable {
  private let lock = NSLock()
  private var progress = UpdateProgress.indeterminate("正在更新…")

  func consuming(_ chunk: String) -> UpdateProgress {
    lock.lock()
    defer { lock.unlock() }

    if let percent = Self.lastPercent(in: chunk) {
      progress = UpdateProgress(
        fractionCompleted: min(percent / 100, 0.9),
        status: "正在下载…"
      )
    } else if chunk.localizedCaseInsensitiveContains("==> Installing")
      || chunk.localizedCaseInsensitiveContains("==> Purging")
    {
      progress = UpdateProgress(fractionCompleted: 0.92, status: "正在安装…")
    } else if chunk.localizedCaseInsensitiveContains("==> Downloading") {
      progress = .indeterminate("正在下载…")
    }
    return progress
  }

  private static func lastPercent(in chunk: String) -> Double? {
    let matches = chunk.matches(of: /(\d{1,3}(?:\.\d+)?)%/)
    guard let match = matches.last else { return nil }
    return Double(match.1)
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
