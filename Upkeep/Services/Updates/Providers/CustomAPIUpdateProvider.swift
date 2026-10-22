import Foundation

/// Checks JSON update endpoints: ones discovered in an app and ones described by
/// `UpdateSourceRule`s.
struct CustomAPIUpdateProvider: Sendable {
    var fetchResponse: @Sendable (URL) async throws -> (statusCode: Int, data: Data)? = {
        try await UpdateHTTP.response(from: $0)
    }
    var rules: @Sendable () -> UpdateSourceRuleSet = { UpdateSourceRuleStore.shared.current() }

    func check(_ application: AppRecord) async -> AppRecord {
        var application = application
        let profile = CustomAPIFeedProfile(application: application, rules: rules())

        guard let requestURL = profile.requestURL(for: application) else {
            application.status = .selfManaged
            return application
        }

        do {
            switch try await fetchManifest(from: requestURL, profile: profile) {
            case .upToDate:
                application.applyInstalledRelease()
            case .update(let manifest):
                application.updateConfiguration.homepageURL =
                    application.updateConfiguration.homepageURL ?? manifest.releaseURL
                    ?? URL(string: "/", relativeTo: requestURL)?.absoluteURL
                let package = manifest.selectedPackage()
                application.applyRemoteRelease(
                    version: manifest.version,
                    releaseDate: manifest.publicationDate,
                    releaseNotes: manifest.notes,
                    releaseNotesURL: manifest.releaseURL,
                    packageByteCount: package?.size,
                    canInstall: package != nil && !application.requiresBundleMigration
                )
            case .notThisProtocol:
                application.updateConfiguration.mechanism = .selfManaged
                application.status = .selfManaged
                application.canAutomaticallyUpdate = false
            }
        } catch is CancellationError {
            return application
        } catch {
            application.status = .unavailable(profile.unavailableMessage(for: error))
        }

        return application
    }

    func upgrade(
        _ application: AppRecord,
        progress: @escaping @Sendable (UpdateProgress) -> Void
    ) async throws {
        let profile = CustomAPIFeedProfile(application: application, rules: rules())
        guard let requestURL = profile.requestURL(for: application) else {
            throw CustomAPIUpdateError.noSecureFeed
        }

        guard !application.requiresBundleMigration else {
            throw CustomAPIUpdateError.requiresApplicationUpdater
        }

        progress(.indeterminate("正在检查更新…"))
        guard
            case .update(let manifest) = try await fetchManifest(
                from: requestURL, profile: profile),
            let package = manifest.selectedPackage()
        else {
            throw CustomAPIUpdateError.noCompatiblePackage
        }

        try await ApplicationPackageInstaller.install(
            from: package.url,
            replacing: application,
            expectedSHA512: package.sha512,
            expectedSHA256: package.sha256,
            requiresValidSignature: profile.requiresValidSignature(requestURL: requestURL),
            requiresTeamIdentifier: ApplicationCodeSigning.teamIdentifier(
                at: application.applicationURL)
                != nil,
            progress: progress
        )
    }

    private enum FetchResult {
        case upToDate
        case update(ReleaseCandidate)
        case notThisProtocol
    }

    private func fetchManifest(
        from url: URL, profile: CustomAPIFeedProfile
    ) async throws -> FetchResult {
        var sawNotFound = false
        var sawOtherFailure = false

        for candidate in profile.candidateURLs(for: url) {
            guard let response = try await fetchResponse(candidate) else {
                sawOtherFailure = true
                continue
            }

            if response.statusCode == 204 { return .upToDate }

            if response.statusCode == 200 {
                guard response.data.count <= 5_000_000,
                    let manifest = profile.parse(response.data, sourceURL: candidate)
                else {
                    sawOtherFailure = true
                    continue
                }
                if VersionComparator.isPrerelease(manifest.version) {
                    return .upToDate
                }
                return .update(manifest)
            }

            if response.statusCode == 404 {
                sawNotFound = true
                continue
            }
            sawOtherFailure = true
        }

        if sawNotFound && !sawOtherFailure {
            // A rule names its endpoint explicitly: a 404 means the rule is wrong,
            // not that the app uses another protocol.
            guard profile.allowsProtocolFallback else {
                throw CustomAPIUpdateError.ruleEndpointNotFound
            }
            return .notThisProtocol
        }
        throw CustomAPIUpdateError.unreadableManifest
    }
}

/// The conventions a custom API record follows: a rule's own fields, or the
/// heuristics used for discovered endpoints.
private enum CustomAPIFeedProfile {
    /// Described by an `UpdateSourceRule`.
    case rule(UpdateSourceRuleMatch)
    /// Found in an executable: `latest.json` channels and `/api/latest` APIs.
    case discovered

    init(application: AppRecord, rules: UpdateSourceRuleSet) {
        let configuration = application.updateConfiguration
        if let match = rules.match(
            configurationIdentifier: configuration.identifier,
            bundleIdentifier: application.bundleIdentifier),
            match.rule.kind == .jsonFeed
        {
            self = .rule(match)
        } else {
            self = .discovered
        }
    }

    func requestURL(for application: AppRecord) -> URL? {
        switch self {
        case .rule(let match):
            // Resolve again so `{version}` follows the installed version.
            return match.feedURL(
                values: match.values(
                    version: application.currentVersion, build: application.buildVersion,
                    bundleIdentifier: application.bundleIdentifier))
        case .discovered:
            return application.updateConfiguration.feedURL.flatMap(SecureUpdateURL.https)
        }
    }

    func candidateURLs(for url: URL) -> [URL] {
        guard case .discovered = self,
            let stableURL = CustomAPIUpdateDetector.stableChannelURL(from: url)
        else { return [url] }
        return [url, stableURL]
    }

    func parse(_ data: Data, sourceURL: URL) -> ReleaseCandidate? {
        switch self {
        case .rule(let match):
            guard let fields = match.rule.fields else { return nil }
            return RuleJSONReleaseParser(fields: fields).parse(data, sourceURL: sourceURL)
        case .discovered:
            return HeuristicJSONReleaseParser.parse(data, sourceURL: sourceURL)
        }
    }

    func requiresValidSignature(requestURL: URL) -> Bool {
        switch self {
        case .rule: true
        case .discovered: requestURL.path.hasPrefix("/api/")
        }
    }

    var allowsProtocolFallback: Bool {
        if case .rule = self { return false }
        return true
    }

    func unavailableMessage(for error: Error) -> String {
        guard case .rule(let match) = self else { return "官网更新接口暂时无法访问。" }
        let name = match.rule.name ?? match.rule.id
        let reason = (error as? CustomAPIUpdateError)?.errorDescription ?? "更新地址暂时无法访问。"
        return "更新规则「\(name)」：\(reason)"
    }
}

enum CustomAPIUpdateError: LocalizedError {
    case noSecureFeed
    case requiresApplicationUpdater
    case noCompatiblePackage
    case unreadableManifest
    case ruleEndpointNotFound

    var errorDescription: String? {
        switch self {
        case .noSecureFeed: "此应用没有安全的官网更新接口。"
        case .requiresApplicationUpdater: "请打开应用，使用应用自身的更新器完成此更新。"
        case .noCompatiblePackage: "更新源中没有兼容此 Mac 的安装包。"
        case .unreadableManifest: "无法读取官网更新清单。"
        case .ruleEndpointNotFound: "更新地址返回 404，请检查规则中的 feed。"
        }
    }
}
