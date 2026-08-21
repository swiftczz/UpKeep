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

        if outdatedItem != nil {
          application.status = .updateAvailable
        } else if cask.autoUpdates == true || cask.version == "latest" {
          application.status = .selfManaged
        } else {
          application.status = .upToDate
        }

        return application
      }
    } catch is CancellationError {
      return applications
    } catch {
      return applications
    }
  }

  func upgrade(_ application: AppRecord) async throws {
    guard let brewURL = Self.brewExecutableURL,
      let token = application.sourceIdentifier,
      application.canAutomaticallyUpdate
    else {
      throw ProcessRunnerError.failed(status: 1, message: "此应用不能由 Homebrew 自动更新。")
    }

    _ = try await ProcessRunner.run(
      executableURL: brewURL,
      arguments: ["upgrade", "--cask", token]
    )
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
