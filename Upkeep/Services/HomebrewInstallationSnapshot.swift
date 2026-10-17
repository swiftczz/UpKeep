import Foundation

/// Local installation receipts, available even during a scan without update checks.
struct HomebrewInstallationSnapshot {
  static let caskroomURLs = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }

  private struct Receipt: Decodable {
    let time: TimeInterval
    let source: Source
    struct Source: Decodable { let version: String }
  }

  private struct Installation {
    let token: String
    let version: String
    let date: Date
  }

  private var installations: [String: Installation] = [:]

  init(caskroomURLs: [URL] = Self.caskroomURLs) {
    let fileManager = FileManager.default
    for caskroom in caskroomURLs {
      let casks = (try? fileManager.contentsOfDirectory(
        at: caskroom, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
      )) ?? []
      for cask in casks {
        guard let data = try? Data(contentsOf: cask.appendingPathComponent(".metadata/INSTALL_RECEIPT.json")),
          let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
          receipt.time.isFinite, receipt.time > 0,
          receipt.source.version != "latest",
          !receipt.source.version.contains("/"), receipt.source.version != ".."
        else { continue }
        let versionURL = cask.appendingPathComponent(receipt.source.version)
        let artifacts = (try? fileManager.contentsOfDirectory(
          at: versionURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        for artifact in artifacts where artifact.pathExtension.lowercased() == "app" {
          guard (try? fileManager.destinationOfSymbolicLink(atPath: artifact.path)) != nil else {
            continue
          }
          let target = artifact.resolvingSymlinksInPath().standardizedFileURL.path
          let installation = Installation(
            token: cask.lastPathComponent, version: receipt.source.version,
            date: Date(timeIntervalSince1970: receipt.time)
          )
          if installations[target].map({ $0.date > installation.date }) != true {
            installations[target] = installation
          }
        }
      }
    }
  }

  func applying(to application: AppRecord) -> AppRecord {
    guard application.source != .appStore,
      let installation = installations[application.applicationURL.standardizedFileURL.path]
    else { return application }

    var application = application
    application.homebrewCaskToken = installation.token
    var installed = application
    installed.latestVersion = nil
    installed.latestBuildVersion = nil
    var receipt = installed
    receipt.currentVersion = installation.version
    receipt.buildVersion = nil
    guard installed.hasSameRelease(as: receipt) else { return application }

    // A later native update must not be relabeled using an old Homebrew receipt.
    if let source = application.installedSource, source != .homebrew {
      guard let lastInstalledAt = application.lastInstalledAt,
        installation.date > lastInstalledAt
      else { return application }
    }
    let values = try? application.applicationURL.resourceValues(
      forKeys: [.creationDateKey, .contentModificationDateKey]
    )
    let dates = [values?.creationDate, values?.contentModificationDate, application.applicationModificationDate]
    guard dates.compactMap({ $0 }).allSatisfy({ $0 <= installation.date.addingTimeInterval(2) }) else {
      return application
    }

    application.installedSource = .homebrew
    application.lastInstalledAt = max(application.lastInstalledAt ?? .distantPast, installation.date)
    return application
  }
}
