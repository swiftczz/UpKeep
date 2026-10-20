import Foundation

struct GitHubReleaseManifest: Equatable, Sendable {
    struct Asset: Equatable, Sendable {
        let name: String
        let downloadURL: URL
        let size: Int64?
    }

    let version: String
    let releaseDate: Date?
    let releaseNotes: String?
    let releaseURL: URL?
    let assets: [Asset]

    static func parse(_ data: Data) -> GitHubReleaseManifest? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["draft"] as? Bool != true,
            json["prerelease"] as? Bool != true,
            let tag = (json["tag_name"] as? String)?.nonBlankValue,
            let version = releaseVersion(from: tag, fallback: json["name"] as? String)
        else {
            return nil
        }

        let assets = (json["assets"] as? [[String: Any]] ?? []).compactMap { value -> Asset? in
            guard let name = (value["name"] as? String)?.nonBlankValue,
                let rawURL = value["browser_download_url"] as? String,
                let downloadURL = SecureUpdateURL.https(string: rawURL)
            else {
                return nil
            }
            return Asset(
                name: name,
                downloadURL: downloadURL,
                size: JSONByteCount.parse(value["size"])
            )
        }

        return GitHubReleaseManifest(
            version: version,
            releaseDate: (json["published_at"] as? String).flatMap(ISO8601Parsing.date),
            releaseNotes: GitHubReleaseNotes.body(in: json),
            releaseURL: (json["html_url"] as? String).flatMap(SecureUpdateURL.https(string:)),
            assets: assets
        )
    }

    func selectedPackage(
        architecture: MacCPUArchitecture = .current
    ) -> Asset? {
        assets
            .filter {
                macOSScore(of: $0.name) > 0
                    && ApplicationPackageInstaller.architectureScore(
                        of: $0.name, architecture: architecture)
                        > 0
            }
            .max { lhs, rhs in
                packageScore(lhs, architecture: architecture)
                    < packageScore(rhs, architecture: architecture)
            }
    }

    func selectedCraftPackage(repository: String, architecture: MacCPUArchitecture = .current)
        -> Asset?
    {
        assets.filter { asset in
            guard let download = GitHubReleaseDownload.parse(asset.downloadURL),
                "\(download.owner)/\(download.repository)" == repository,
                download.fileName == asset.name,
                let slug = repository.split(separator: "/").last,
                asset.name.lowercased().hasPrefix("\(slug)-"),
                macOSScore(of: asset.name) >= 90,
                ApplicationPackageInstaller.architectureScore(
                    of: asset.name, architecture: architecture)
                    > 0
            else { return false }
            let tokens = asset.name.lowercased().split { !$0.isLetter && !$0.isNumber }
            return !tokens.contains("web") && !tokens.contains("server")
        }
        .max {
            packageScore($0, architecture: architecture)
                < packageScore($1, architecture: architecture)
        }
    }

    var checksumsAsset: Asset? {
        assets.first { asset in
            let name = asset.name.lowercased()
            return name == "checksums.txt" || name == "sha256sums" || name == "sha256sums.txt"
        }
    }

    static func sha256(for fileName: String, in data: Data) -> String? {
        guard data.count <= 1_000_000, let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { continue }
            let digest = String(fields[0]).lowercased()
            let listedName = normalizedChecksumFileName(String(fields[1]))
            if listedName == fileName, isSHA256(digest) {
                return digest
            }
        }

        let escaped = NSRegularExpression.escapedPattern(for: fileName)
        guard
            let expression = try? NSRegularExpression(
                pattern: #"(?i)SHA256\s*\("# + escaped + #"\)\s*=\s*([a-f0-9]{64})"#
            ),
            let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            ),
            let digestRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[digestRange]).lowercased()
    }

    private static func releaseVersion(from tag: String, fallback: String?) -> String? {
        for candidate in [tag, fallback].compactMap({ $0 }) {
            guard
                let expression = try? NSRegularExpression(
                    pattern:
                        #"(?i)(?:^|[-_/ ])v?(\d+(?:[._-]\d+)+(?:[-._]?[A-Za-z][A-Za-z0-9.-]*)?)"#
                ),
                let match = expression.firstMatch(
                    in: candidate,
                    range: NSRange(candidate.startIndex..., in: candidate)
                ),
                let range = Range(match.range(at: 1), in: candidate)
            else {
                continue
            }
            return String(candidate[range])
        }
        return nil
    }

    private func packageScore(_ asset: Asset, architecture: MacCPUArchitecture) -> Int {
        macOSScore(of: asset.name) * 1_000
            + ApplicationPackageInstaller.architectureScore(
                of: asset.name,
                architecture: architecture
            ) * 10
            + ApplicationPackageInstaller.packageKindScore(of: asset.name)
    }

    private func macOSScore(of fileName: String) -> Int {
        let name = fileName.lowercased()
        guard ApplicationPackageInstaller.packageKindScore(of: name) > 0 else { return 0 }
        // A release can contain a desktop app and a standalone command-line tool.
        // Match whole tokens so application names such as CLion remain eligible.
        let tokens = name.split { !$0.isLetter && !$0.isNumber }
        if tokens.contains("cli") || tokens.contains("commandline") || name.contains("command-line")
        {
            return 0
        }
        if name.contains("linux") || name.contains("windows") || name.contains("win32")
            || name.contains("win64")
        {
            return 0
        }
        if name.hasSuffix(".dmg") { return 100 }
        if name.contains("macos") || name.contains("darwin") || name.contains("osx") {
            return 90
        }
        return name.hasSuffix(".zip") ? 20 : 0
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func normalizedChecksumFileName(_ value: String) -> String {
        var name = value.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        while name.hasPrefix("./") {
            name.removeFirst(2)
        }
        return (name as NSString).lastPathComponent
    }
}

struct GitHubReleasesUpdateProvider: Sendable {
    var fetchResponse: @Sendable (URL) async throws -> (statusCode: Int, data: Data)? = {
        try await UpdateHTTP.response(from: $0)
    }
    var fetchData: @Sendable (URL) async throws -> Data? = {
        try await UpdateHTTP.successfulData(from: $0)
    }
    var missingReleaseCache = GitHubMissingReleaseCache.shared

    func invalidateMissingReleaseCache() async {
        await missingReleaseCache.invalidate()
    }

    func check(_ application: AppRecord) async -> AppRecord {
        var application = application
        guard let apiURL = application.updateConfiguration.feedURL,
            GitHubReleasesDetector.metadata(in: apiURL.absoluteString) != nil
        else {
            application.status = .selfManaged
            return application
        }

        do {
            let release = try await loadRelease(
                from: apiURL, tagPrefix: application.updateConfiguration.githubReleaseTagPrefix,
                cacheMissing: craftMetadata(for: application) != nil)
            let package = selectedPackage(in: release, for: application)
            let installability = await installability(
                of: package,
                in: release,
                replacing: application
            )
            application.updateConfiguration.homepageURL =
                application.updateConfiguration.homepageURL ?? release.releaseURL
            application.applyRemoteRelease(
                version: release.version,
                releaseDate: release.releaseDate,
                releaseNotes: release.releaseNotes,
                releaseNotesURL: release.releaseURL,
                packageByteCount: package?.size,
                canInstall: installability.canInstall
            )
        } catch is CancellationError {
            return application
        } catch GitHubReleaseLookupError.notFound {
            application.canAutomaticallyUpdate = false
            application.status = .unavailable(
                GitHubReleaseLookupError.notFound.localizedDescription)
        } catch let error as GitHubAPIError {
            application.status = .unavailable(error.localizedDescription)
        } catch {
            application.status = .unavailable("GitHub Releases 更新源暂时无法访问。")
        }
        return application
    }

    func upgrade(
        _ application: AppRecord,
        progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws {
        guard let apiURL = application.updateConfiguration.feedURL,
            GitHubReleasesDetector.metadata(in: apiURL.absoluteString) != nil
        else {
            throw ProcessRunnerError.failed(status: 1, message: "此应用没有安全的 GitHub Releases 更新源。")
        }

        progress(.indeterminate("正在检查更新…"))
        let release = try await loadRelease(
            from: apiURL, tagPrefix: application.updateConfiguration.githubReleaseTagPrefix)
        guard let package = selectedPackage(in: release, for: application) else {
            throw ProcessRunnerError.failed(status: 1, message: "GitHub Release 中没有兼容此 Mac 的安装包。")
        }

        let installability = await installability(
            of: package,
            in: release,
            replacing: application
        )
        guard installability.canInstall else {
            throw ProcessRunnerError.failed(
                status: 1, message: "GitHub Release 没有提供可验证的 macOS 更新包。")
        }
        try await ApplicationPackageInstaller.install(
            from: package.downloadURL,
            replacing: application,
            expectedSHA512: nil,
            expectedSHA256: installability.expectedSHA256,
            requiresValidSignature: installability.requiresValidSignature,
            requiresTeamIdentifier: installability.requiresTeamIdentifier,
            progress: progress
        )
    }

    private func craftMetadata(for application: AppRecord) -> GitHubReleasesMetadata? {
        guard let metadata = KnownGitHubReleaseSources.metadata(for: application.bundleIdentifier),
            metadata.apiURL == application.updateConfiguration.feedURL
        else { return nil }
        return metadata
    }

    private func selectedPackage(in release: GitHubReleaseManifest, for application: AppRecord)
        -> GitHubReleaseManifest.Asset?
    {
        if let metadata = craftMetadata(for: application) {
            return release.selectedCraftPackage(repository: metadata.identifier)
        }
        return release.selectedPackage()
    }

    private func loadRelease(from url: URL, tagPrefix: String? = nil, cacheMissing: Bool = false)
        async throws -> GitHubReleaseManifest
    {
        if let tagPrefix {
            return try await loadChannelRelease(from: url, tagPrefix: tagPrefix)
        }
        try Task.checkCancellation()
        if cacheMissing, await missingReleaseCache.contains(url) {
            throw GitHubReleaseLookupError.notFound
        }
        guard let result = try await fetchResponse(url) else {
            throw ProcessRunnerError.failed(status: 1, message: "未收到 GitHub 发布信息响应，请稍后重试。")
        }
        try Task.checkCancellation()
        if result.statusCode == 404 {
            if cacheMissing { await missingReleaseCache.remember(url) }
            throw GitHubReleaseLookupError.notFound
        }
        guard (200..<300).contains(result.statusCode) else {
            throw GitHubAPIError(message: "GitHub 发布信息请求失败（HTTP \(result.statusCode)），请稍后重试。")
        }
        let data = result.data
        guard data.count <= 5_000_000,
            let release = GitHubReleaseManifest.parse(data)
        else {
            throw ProcessRunnerError.failed(status: 1, message: "无法读取 GitHub Release。")
        }
        await missingReleaseCache.remove(url)
        return release
    }

    private func loadChannelRelease(from url: URL, tagPrefix: String) async throws
        -> GitHubReleaseManifest
    {
        guard !tagPrefix.isEmpty, tagPrefix.count <= 80,
            tagPrefix.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0)
                    || (48...57).contains($0) || $0 == 45 || $0 == 95
            })
        else {
            throw ProcessRunnerError.failed(status: 1, message: "GitHub 发布渠道无效。")
        }
        // Never fall back to /latest: a shared repository can make its CLI the latest release.
        for page in 1...5 {
            try Task.checkCancellation()
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                break
            }
            components.queryItems = [
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page)),
            ]
            guard let pageURL = components.url,
                let response = try await fetchResponse(pageURL)
            else { break }
            try Task.checkCancellation()
            guard (200..<300).contains(response.statusCode) else {
                throw GitHubAPIError(message: "GitHub 发布列表请求失败（HTTP \(response.statusCode)）。")
            }
            guard response.data.count <= 5_000_000,
                let values = try JSONSerialization.jsonObject(with: response.data)
                    as? [[String: Any]]
            else { break }
            let releases = values.compactMap { value -> GitHubReleaseManifest? in
                guard let tag = value["tag_name"] as? String, tag.hasPrefix(tagPrefix),
                    let data = try? JSONSerialization.data(withJSONObject: value)
                else { return nil }
                guard let release = GitHubReleaseManifest.parse(data),
                    !VersionComparator.isPrerelease(release.version)
                else { return nil }
                return release
            }
            if let release = releases.max(by: {
                VersionComparator.isNewer($1.version, than: $0.version)
            }) {
                return release
            }
            if values.count < 100 { break }
        }
        throw ProcessRunnerError.failed(status: 1, message: "未找到该渠道的 GitHub 正式版本。")
    }

    private func installability(
        of package: GitHubReleaseManifest.Asset?,
        in release: GitHubReleaseManifest,
        replacing application: AppRecord
    ) async -> (
        canInstall: Bool,
        expectedSHA256: String?,
        requiresValidSignature: Bool,
        requiresTeamIdentifier: Bool
    ) {
        guard let package else {
            return (false, nil, false, false)
        }

        let requiresTeamIdentifier =
            ApplicationCodeSigning.teamIdentifier(at: application.applicationURL) != nil
        let expectedSHA256 = await checksum(for: package, in: release)
        return (true, expectedSHA256, true, requiresTeamIdentifier)
    }

    private func checksum(
        for package: GitHubReleaseManifest.Asset,
        in release: GitHubReleaseManifest
    ) async -> String? {
        guard let checksums = release.checksumsAsset,
            let data = try? await fetchData(checksums.downloadURL)
        else {
            return nil
        }
        return GitHubReleaseManifest.sha256(for: package.name, in: data)
    }
}

private enum GitHubReleaseLookupError: LocalizedError {
    case notFound

    var errorDescription: String? {
        "未找到可访问的 GitHub 正式版本（HTTP 404）。请稍后重试，或手动刷新重新检查。"
    }
}
