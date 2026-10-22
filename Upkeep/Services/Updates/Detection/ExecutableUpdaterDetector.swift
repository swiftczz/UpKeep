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
        // Never inspect the shared Electron runtime for application-specific endpoints.
        guard !TauriUpdaterDetector.hasElectronFramework(in: bundleURL) else {
            return ExecutableUpdaterDetection(tauriEndpoint: nil, customAPIUpdateEndpoint: nil)
        }
        let files = executableFiles(in: bundleURL)

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
            where seenGitHubReleases.insert(candidate.apiURL.absoluteString).inserted {
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
        var customAPIUpdateEndpoint: URL?
        var githubReleases: [GitHubReleasesMetadata] = []
        var seenGitHubReleases = Set<String>()

        while true {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty {
                break
            }

            let window = previousTail + chunk
            sawTauri = sawTauri || TauriUpdaterDetector.hasTauriEvidence(in: window)
            for url in TauriUpdaterDetector.updaterJSONURLs(in: window)
            where seen.insert(url.absoluteString).inserted {
                foundURLs.append(url)
            }
            if customAPIUpdateEndpoint == nil {
                customAPIUpdateEndpoint = CustomAPIUpdateDetector.firstEndpoint(in: window)
            }
            for candidate in GitHubReleasesDetector.metadataCandidates(in: window)
            where seenGitHubReleases.insert(candidate.apiURL.absoluteString).inserted {
                githubReleases.append(candidate)
            }
            if sawTauri, foundURLs.contains(where: TauriUpdaterDetector.isDirectManifestURL) {
                break
            }
            previousTail = Data(window.suffix(overlapSize))
        }

        return ExecutableUpdaterDetection(
            tauriEndpoint: TauriUpdaterDetector.preferredUpdaterJSONURL(foundURLs),
            customAPIUpdateEndpoint: customAPIUpdateEndpoint,
            githubReleases: githubReleases
        )
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
        where seen.insert(file.standardizedFileURL.path).inserted {
            files.append(file)
        }
        return files
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
