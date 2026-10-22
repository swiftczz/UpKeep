import Foundation

struct ExecutableUpdaterDetection: Sendable {
    var tauriEndpoint: URL?
    var customAPIUpdateEndpoint: URL?
    var githubReleases: [GitHubReleasesMetadata] = []
}

enum ExecutableUpdaterDetector {
    private static let chunkSize = 1024 * 1024
    private static let overlapSize = 512
    private static let maximumExecutableBytes = 400 * 1024 * 1024

    static func detect(bundleURL: URL) -> ExecutableUpdaterDetection {
        if let endpoint = TauriUpdaterDetector.endpointFromConfiguration(in: bundleURL) {
            return ExecutableUpdaterDetection(tauriEndpoint: endpoint, customAPIUpdateEndpoint: nil)
        }
        // Electron can delegate updates to its own native service. Never inspect the
        // shared Electron runtime for application-specific endpoints.
        let files =
            TauriUpdaterDetector.hasElectronFramework(in: bundleURL)
            ? applicationServiceExecutables(in: bundleURL) + helperExecutables(in: bundleURL)
            : executableFiles(in: bundleURL)

        let suppressCustomAPIUpdate = CustomAPIUpdateDetector.hasTauriConfiguration(in: bundleURL)
        var customAPIUpdateEndpoint: URL?
        var githubReleases: [GitHubReleasesMetadata] = []
        var seenGitHubReleases = Set<String>()
        for fileURL in files {
            let detection = detect(fileURL: fileURL)
            if let tauriEndpoint = detection.tauriEndpoint {
                return ExecutableUpdaterDetection(
                    tauriEndpoint: tauriEndpoint,
                    customAPIUpdateEndpoint: nil
                )
            }
            if customAPIUpdateEndpoint == nil, !suppressCustomAPIUpdate {
                customAPIUpdateEndpoint = detection.customAPIUpdateEndpoint
            }
            for candidate in detection.githubReleases
            where seenGitHubReleases.insert(
                candidate.apiURL.absoluteString + "|" + (candidate.tagPrefix ?? "")
            ).inserted {
                githubReleases.append(candidate)
            }
        }
        return ExecutableUpdaterDetection(
            tauriEndpoint: nil,
            customAPIUpdateEndpoint: customAPIUpdateEndpoint,
            githubReleases: githubReleases
        )
    }

    static func detect(fileURL: URL) -> ExecutableUpdaterDetection {
        guard
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
            values.isRegularFile == true,
            let fileSize = values.fileSize,
            fileSize > 0,
            fileSize <= maximumExecutableBytes,
            let handle = try? FileHandle(forReadingFrom: fileURL)
        else {
            return ExecutableUpdaterDetection(tauriEndpoint: nil, customAPIUpdateEndpoint: nil)
        }
        defer { try? handle.close() }

        var previousTail = Data()
        var foundURLs: [URL] = []
        var seen = Set<String>()
        var sawTauri = false
        var sawGPUI = false
        var customAPIUpdateEndpoint: URL?
        var githubReleases: [GitHubReleasesMetadata] = []
        var seenGitHubReleases = Set<String>()

        while true {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty {
                break
            }

            let window = previousTail + chunk
            let evidence = TauriUpdaterDetector.evidence(in: window)
            sawTauri = sawTauri || evidence.sawTauri
            sawGPUI = sawGPUI || evidence.sawGPUI
            for url in TauriUpdaterDetector.updaterJSONURLs(in: window)
            where seen.insert(url.absoluteString).inserted {
                foundURLs.append(url)
            }
            if customAPIUpdateEndpoint == nil {
                customAPIUpdateEndpoint = CustomAPIUpdateDetector.firstEndpoint(in: window)
            }
            for candidate in GitHubReleasesDetector.metadataCandidates(in: window)
            where seenGitHubReleases.insert(
                candidate.apiURL.absoluteString + "|" + (candidate.tagPrefix ?? "")
            ).inserted {
                githubReleases.append(candidate)
            }
            if sawTauri, foundURLs.contains(where: TauriUpdaterDetector.isDirectManifestURL) {
                break
            }
            previousTail = Data(window.suffix(overlapSize))
        }

        let tauriEndpoint =
            sawGPUI && !sawTauri
            ? nil
            : TauriUpdaterDetector.preferredUpdaterJSONURL(foundURLs)
        return ExecutableUpdaterDetection(
            tauriEndpoint: tauriEndpoint,
            customAPIUpdateEndpoint: customAPIUpdateEndpoint,
            githubReleases: githubReleases
        )
    }

    static func hasApplicationService(in bundleURL: URL) -> Bool {
        !applicationServiceExecutables(in: bundleURL).isEmpty
    }

    private static func applicationServiceExecutables(in bundleURL: URL) -> [URL] {
        guard let name = Bundle(url: bundleURL)?.executableURL?.lastPathComponent.lowercased(),
            !name.isEmpty
        else { return [] }
        let root = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let slug = name.split(whereSeparator: \.isWhitespace).joined(separator: "-")
        let candidates = ["service/\(name)-desktop", "service/\(name)", "bin/\(slug)-host"]
        return candidates.compactMap { path in
            let url = root.appendingPathComponent("Contents/Resources").appendingPathComponent(path)
                .resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(root.path + "/"), isRegularFile(url),
                FileManager.default.isExecutableFile(atPath: url.path)
            else { return nil }
            return url
        }
    }

    private static func executableFiles(in bundleURL: URL) -> [URL] {
        let macosURL = bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let preferredName = Bundle(url: bundleURL)?.executableURL?.lastPathComponent
        var files =
            (try? FileManager.default.contentsOfDirectory(
                at: macosURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []

        if let preferredName,
            let preferredIndex = files.firstIndex(where: { $0.lastPathComponent == preferredName })
        {
            files.swapAt(0, preferredIndex)
        }

        var seen = Set(files.map(\.standardizedFileURL.path))
        for file in applicationPayloadExecutables(in: bundleURL, preferredName: preferredName)
            + helperExecutables(in: bundleURL)
        where seen.insert(file.standardizedFileURL.path).inserted {
            files.append(file)
        }
        return files
    }

    private static func helperExecutables(in bundleURL: URL) -> [URL] {
        let root = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let directory = root.appendingPathComponent("Contents/Helpers")
        let appName = bundleURL.deletingPathExtension().lastPathComponent.lowercased()
            .filter { $0.isLetter || $0.isNumber }
        guard !appName.isEmpty else { return [] }
        let helpers =
            ((try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
        return helpers.filter { helper in
            helper.pathExtension.lowercased() == "app"
                && helper.deletingPathExtension().lastPathComponent.lowercased()
                    .filter { $0.isLetter || $0.isNumber }.hasPrefix(appName)
        }.prefix(8).compactMap { helper in
            guard let executable = Bundle(url: helper)?.executableURL else { return nil }
            let resolved = executable.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/"), isRegularFile(resolved),
                FileManager.default.isExecutableFile(atPath: resolved.path)
            else { return nil }
            return resolved
        }
    }

    private static func applicationPayloadExecutables(
        in bundleURL: URL,
        preferredName: String?
    ) -> [URL] {
        let frameworksURL = bundleURL.appendingPathComponent(
            "Contents/Frameworks", isDirectory: true)
        let frameworkNames = ["App", preferredName].compactMap(\.self)
        var files: [URL] = []

        for frameworkName in frameworkNames {
            let frameworkURL = frameworksURL.appendingPathComponent(
                "\(frameworkName).framework",
                isDirectory: true
            )
            let candidates = [
                Bundle(url: frameworkURL)?.executableURL,
                frameworkURL
                    .appendingPathComponent("Versions/A", isDirectory: true)
                    .appendingPathComponent(frameworkName),
                frameworkURL.appendingPathComponent(frameworkName),
            ].compactMap(\.self)

            for candidate in candidates where isRegularFile(candidate) {
                files.append(candidate)
                break
            }
        }

        return files
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
