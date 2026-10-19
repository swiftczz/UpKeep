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
            let casks =
                (try? fileManager.contentsOfDirectory(
                    at: caskroom, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
                )) ?? []
            for cask in casks {
                guard
                    let data = try? Data(
                        contentsOf: cask.appendingPathComponent(".metadata/INSTALL_RECEIPT.json")),
                    let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
                    receipt.time.isFinite, receipt.time > 0,
                    receipt.source.version != "latest",
                    !receipt.source.version.contains("/"), receipt.source.version != ".."
                else { continue }
                let versionURL = cask.appendingPathComponent(receipt.source.version)
                let artifacts =
                    (try? fileManager.contentsOfDirectory(
                        at: versionURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
                    )) ?? []
                for artifact in artifacts where artifact.pathExtension.lowercased() == "app" {
                    guard (try? fileManager.destinationOfSymbolicLink(atPath: artifact.path)) != nil
                    else {
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
        guard application.updateConfiguration.mechanism != .appStore,
            let installation = installations[application.applicationURL.standardizedFileURL.path]
        else { return application }

        var application = application
        application.homebrewCaskToken = installation.token
        guard Self.matchesInstalledRelease(installation.version, application: application) else {
            return application
        }

        // A later native update must not be relabeled using an old Homebrew receipt.
        if let source = application.installedUpdateConfiguration?.mechanism, source != .homebrew {
            guard let lastInstalledAt = application.lastInstalledAt,
                installation.date > lastInstalledAt
            else { return application }
        }
        let values = try? application.applicationURL.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey]
        )
        let dates = [
            values?.creationDate, values?.contentModificationDate,
            application.applicationModificationDate,
        ]
        guard dates.compactMap({ $0 }).allSatisfy({ $0 <= installation.date.addingTimeInterval(2) })
        else {
            return application
        }

        let configuration = UpdateConfiguration(
            mechanism: .homebrew, homepageURL: application.updateConfiguration.homepageURL,
            identifier: installation.token)
        application.installedUpdateConfiguration = configuration
        application.lastInstalledAt = max(
            application.lastInstalledAt ?? .distantPast, installation.date)

        // A framework without a feed cannot check for updates. Use the verified
        // Homebrew route immediately, including during local-only installation scans.
        if !application.updateConfiguration.isCheckable,
            application.updateConfiguration.mechanism != .homebrew,
            !application.needsUpdate
        {
            application.rememberAlternateUpdateConfiguration(from: application)
            application.updateConfiguration = configuration
            application.status = .upToDate
            application.latestVersion = application.currentVersion
            application.latestBuildVersion = application.buildVersion
            application.canAutomaticallyUpdate = false
        }
        return application
    }

    private static func matchesInstalledRelease(_ caskVersion: String, application: AppRecord)
        -> Bool
    {
        // Development casks can record `build,full-commit` while the bundle exposes
        // the same build and an abbreviated commit as its marketing version.
        if caskVersion.range(of: #"\A[0-9]+,[0-9a-fA-F]{7,64}\z"#, options: .regularExpression)
            != nil,
            application.currentVersion.range(
                of: #"\A[0-9a-fA-F]{7,64}\z"#, options: .regularExpression)
                != nil
        {
            let parts = caskVersion.split(separator: ",")
            guard application.buildVersion == String(parts[0]) else { return false }
            let commit = String(parts[1]).lowercased()
            let installedCommit = application.currentVersion.lowercased()
            return commit.hasPrefix(installedCommit) || installedCommit.hasPrefix(commit)
        }

        var installed = application
        installed.latestVersion = nil
        installed.latestBuildVersion = nil
        var receipt = installed
        receipt.currentVersion = caskVersion
        receipt.buildVersion = nil
        return installed.hasSameRelease(as: receipt)
    }
}
