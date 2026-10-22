import Foundation

protocol ApplicationScanning: Sendable {
    func scan() async -> [AppRecord]
    func scanInstalledApplications(reusing previousApplications: [AppRecord]) async -> [AppRecord]
    func scan(reusing previousApplications: [AppRecord]) async -> [AppRecord]
}

extension ApplicationScanning {
    func scanInstalledApplications(reusing previousApplications: [AppRecord]) async -> [AppRecord] {
        await scan(reusing: previousApplications)
    }

    func scan(reusing previousApplications: [AppRecord]) async -> [AppRecord] {
        await scan()
    }
}

private typealias SourceDetectionMode = UpdateSourceDetectionContext.Depth

struct ApplicationScanner: ApplicationScanning {
    var ruleStore: UpdateSourceRuleStore = .shared
    var registry: UpdateSourceRegistry = .standard

    func scan() async -> [AppRecord] {
        await scan(reusing: [])
    }

    func scanInstalledApplications(reusing previousApplications: [AppRecord]) async -> [AppRecord] {
        await scan(reusing: previousApplications, sourceDetection: .installedOnly)
    }

    func scan(reusing previousApplications: [AppRecord]) async -> [AppRecord] {
        await scan(reusing: previousApplications, sourceDetection: .full)
    }

    private func scan(
        reusing previousApplications: [AppRecord],
        sourceDetection: SourceDetectionMode
    ) async -> [AppRecord] {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ruleStore = ruleStore
        let registry = registry
        let previousByPath = Dictionary(
            previousApplications.map { ($0.applicationURL.standardizedFileURL.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return await Task.detached(priority: .userInitiated) {
            Self.scanSynchronously(
                excludingBundleIdentifier: ownBundleIdentifier,
                reusing: previousByPath,
                sourceDetection: sourceDetection,
                rules: ruleStore.current(),
                registry: registry
            )
        }.value
    }

    private static func scanSynchronously(
        excludingBundleIdentifier: String?,
        reusing previousByPath: [String: AppRecord] = [:],
        sourceDetection: SourceDetectionMode = .full,
        rules: UpdateSourceRuleSet,
        registry: UpdateSourceRegistry
    ) -> [AppRecord] {
        let fileManager = FileManager.default
        let locations = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
                "Applications", isDirectory: true),
        ]

        var seenPaths = Set<String>()
        var records: [AppRecord] = []
        let homebrewInstallations = HomebrewInstallationSnapshot()

        for location in locations where fileManager.fileExists(atPath: location.path) {
            guard
                let enumerator = fileManager.enumerator(
                    at: location,
                    includingPropertiesForKeys: [
                        .isDirectoryKey,
                        .isPackageKey,
                        .contentModificationDateKey,
                    ],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            else {
                continue
            }

            for case let applicationURL as URL in enumerator {
                guard applicationURL.pathExtension.lowercased() == "app" else {
                    continue
                }

                enumerator.skipDescendants()
                let path = applicationURL.standardizedFileURL.path
                guard seenPaths.insert(path).inserted,
                    let record = makeRecord(
                        from: applicationURL,
                        reusing: previousByPath[path],
                        preferredLanguages: Locale.preferredLanguages,
                        sourceDetection: sourceDetection,
                        rules: rules,
                        registry: registry
                    ),
                    record.bundleIdentifier != excludingBundleIdentifier
                else {
                    continue
                }

                records.append(homebrewInstallations.applying(to: record))
            }
        }

        return sortedByModificationDate(records)
    }

    static func makeRecord(
        from applicationURL: URL,
        reusing previous: AppRecord? = nil,
        preferredLanguages: [String] = Locale.preferredLanguages,
        sourceDetection: UpdateSourceDetectionContext.Depth = .full,
        rules: UpdateSourceRuleSet = .builtIn,
        registry: UpdateSourceRegistry = .standard
    ) -> AppRecord? {
        guard let bundle = resolvedBundle(from: applicationURL) else {
            return nil
        }

        let info = freshInfoDictionary(for: bundle)
        guard let bundleIdentifier = info["CFBundleIdentifier"] as? String,
            !bundleIdentifier.isEmpty
        else {
            return nil
        }

        let name = resolvedName(
            for: bundle,
            applicationURL: applicationURL,
            info: info,
            preferredLanguages: preferredLanguages
        )
        let currentVersion =
            (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)
            ?? "未知"
        var buildVersion = info["CFBundleVersion"] as? String
        let applicationModificationDate = latestModificationDate(
            of: applicationURL,
            bundle: bundle
        )
        let contentsURL = bundle.bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let receiptURL = contentsURL.appendingPathComponent("_MASReceipt/receipt")
        let hasAppStoreReceipt = FileManager.default.fileExists(atPath: receiptURL.path)
        let iOSAppStoreMetadata = iOSAppStoreMetadata(at: applicationURL, bundleInfo: info)
        let sparkleURL = contentsURL.appendingPathComponent(
            "Frameworks/Sparkle.framework", isDirectory: true)
        let feedURL = (info["SUFeedURL"] as? String).flatMap(SecureUpdateURL.https(string:))
        let hasSparkleSource =
            feedURL != nil
            || FileManager.default.fileExists(atPath: sparkleURL.path)
        let context = UpdateSourceDetectionContext(
            applicationURL: applicationURL, bundleURL: bundle.bundleURL, name: name,
            bundleIdentifier: bundleIdentifier, currentVersion: currentVersion,
            buildVersion: buildVersion, depth: sourceDetection,
            hasAppStoreReceipt: hasAppStoreReceipt, iOSAppStoreMetadata: iOSAppStoreMetadata,
            sparkleFeedURL: feedURL, hasSparkleSource: hasSparkleSource, rules: rules)

        // Retry unknown sources in full scans so new detector rules can recover them.
        // The installed-only monitor still reuses unchanged records without reading binaries.
        if let previous, previous.updateConfiguration.mechanism != .vscodeUpdater,
            !(sourceDetection == .full && previous.updateConfiguration.mechanism == .homebrew
                && previous.alternateUpdateConfiguration == nil),
            previous.updateConfiguration.mechanism != .sparkle
                || previous.updateConfiguration.feedURL == feedURL
                || previous.updateConfiguration.isRuleAssigned,
            !(previous.updateConfiguration.mechanism == .selfManaged
                && (sourceDetection == .full
                    || hasSparkleSource
                    || rules.firstMatch(for: bundleIdentifier) != nil)),
            !ruleRouteChanged(since: previous, context: context),
            canReuse(
                previous,
                bundleIdentifier: bundleIdentifier,
                currentVersion: currentVersion,
                applicationModificationDate: applicationModificationDate,
                hasAppStoreReceipt: hasAppStoreReceipt,
                iOSAppStoreMetadata: iOSAppStoreMetadata
            )
        {
            return previous
        }

        let detected = registry.detectors.lazy.compactMap { $0.detect(context) }.first
        let configuration = detected?.configuration ?? UpdateConfiguration(mechanism: .selfManaged)
        let appStorePlatform = detected?.appStorePlatform
        if let detectedBuildVersion = detected?.buildVersion {
            buildVersion = detectedBuildVersion
        }

        let status: UpdateStatus
        switch configuration.mechanism {
        case .selfManaged: status = .selfManaged
        case .sparkle where configuration.feedURL == nil: status = .selfManaged
        case .appStore where sourceDetection == .installedOnly: status = .upToDate
        default: status = .checking
        }
        return AppRecord(
            name: name, bundleIdentifier: bundleIdentifier, applicationURL: applicationURL,
            currentVersion: currentVersion, buildVersion: buildVersion,
            applicationModificationDate: applicationModificationDate,
            updateConfiguration: configuration, appStorePlatform: appStorePlatform,
            appStoreCountryCode: sourceDetection == .installedOnly && hasAppStoreReceipt
                ? nil : iOSAppStoreMetadata?.countryCode, status: status)
    }

    /// A rule added, edited or removed after this record was cached takes effect
    /// without waiting for the application's next version.
    private static func ruleRouteChanged(
        since previous: AppRecord, context: UpdateSourceDetectionContext
    ) -> Bool {
        let cached = previous.updateConfiguration
        // Store receipts and Sparkle feeds declared in Info.plist outrank rules in the
        // registry's detector order.
        let bundleDeclaresSource =
            context.hasAppStoreReceipt || context.iOSAppStoreMetadata != nil
            || context.sparkleFeedURL != nil
        if cached.isRuleAssigned,
            bundleDeclaresSource
                || context.rules.match(
                    configurationIdentifier: cached.identifier,
                    bundleIdentifier: context.bundleIdentifier) == nil
        {
            return true
        }
        guard !bundleDeclaresSource,
            let detected = RuleSourceDetector(precedence: .beforeHeuristics).detect(context)
        else { return false }
        return detected.configuration.mechanism != cached.mechanism
            || detected.configuration.identifier != cached.identifier
    }

    static func sortedByModificationDate(_ applications: [AppRecord]) -> [AppRecord] {
        applications.sortedByDescendingDate(\.applicationModificationDate)
    }

    static func latestModificationDate(of applicationURL: URL, bundle: Bundle) -> Date? {
        var urls = [
            bundle.bundleURL.appendingPathComponent("Contents", isDirectory: true),
            bundle.bundleURL.appendingPathComponent("Contents/Info.plist"),
            bundle.bundleURL.appendingPathComponent("Info.plist"),
        ]
        if let executableURL = bundle.executableURL {
            urls.append(executableURL)
        }

        if let newestInnerDate = urls.compactMap(contentModificationDate(at:)).max() {
            return newestInnerDate
        }

        return contentModificationDate(at: applicationURL)
            ?? contentModificationDate(at: bundle.bundleURL)
    }

    private static func contentModificationDate(at url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func canReuse(
        _ previous: AppRecord,
        bundleIdentifier: String,
        currentVersion: String,
        applicationModificationDate: Date?,
        hasAppStoreReceipt: Bool,
        iOSAppStoreMetadata: IOSAppStoreMetadata?
    ) -> Bool {
        guard previous.bundleIdentifier == bundleIdentifier,
            previous.currentVersion == currentVersion,
            let previousDate = previous.applicationModificationDate,
            let applicationModificationDate
        else {
            return false
        }

        guard abs(previousDate.timeIntervalSince(applicationModificationDate)) < 0.001 else {
            return false
        }

        if hasAppStoreReceipt {
            return previous.updateConfiguration.mechanism == .appStore
                && previous.appStorePlatform == .mac
        }
        if let iOSAppStoreMetadata {
            return previous.updateConfiguration.mechanism == .appStore
                && previous.appStorePlatform == iOSAppStoreMetadata.platform
        }
        return previous.updateConfiguration.mechanism != .appStore
    }

    private static func resolvedName(
        for bundle: Bundle,
        applicationURL: URL,
        info: [String: Any],
        preferredLanguages: [String]
    ) -> String {
        let localizedValues = ["CFBundleDisplayName", "CFBundleName"].compactMap {
            localizedInfoString(
                forKey: $0,
                in: bundle,
                preferredLanguages: preferredLanguages
            )
        }
        let bundleValues = ["CFBundleDisplayName", "CFBundleName"].compactMap {
            bundle.object(forInfoDictionaryKey: $0) as? String
        }
        let rawValues = ["CFBundleDisplayName", "CFBundleName"].compactMap {
            info[$0] as? String
        }

        return (localizedValues + bundleValues + rawValues)
            .compactMap(\.nonBlankValue)
            .first
            ?? applicationURL.deletingPathExtension().lastPathComponent
    }

    private static func freshInfoDictionary(for bundle: Bundle) -> [String: Any] {
        let candidateURLs = [
            bundle.bundleURL.appendingPathComponent("Contents/Info.plist"),
            bundle.bundleURL.appendingPathComponent("Info.plist"),
        ]

        for infoURL in candidateURLs {
            guard
                let data = try? Data(contentsOf: infoURL, options: .uncached),
                let values = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                ) as? [String: Any]
            else {
                continue
            }

            return values
        }

        return bundle.infoDictionary ?? [:]
    }

    private static func resolvedBundle(from applicationURL: URL) -> Bundle? {
        // Foundation can open an iOS wrapper as a bundle, but its info dictionary
        // is cached. Resolve the inner bundle first so freshInfoDictionary reads
        // the actual plist after an App Store installation or update.
        let wrappedBundleURL =
            applicationURL
            .appendingPathComponent("WrappedBundle")
            .resolvingSymlinksInPath()
        return Bundle(url: wrappedBundleURL) ?? Bundle(url: applicationURL)
    }

    static func appStoreAdamIdentifier(at applicationURL: URL) -> String? {
        guard let item = NSMetadataItem(url: applicationURL) else {
            return nil
        }

        let value = item.value(forAttribute: "kMDItemAppStoreAdamID")
        if let number = value as? NSNumber {
            let identifier = number.uint64Value
            return identifier == 0 ? nil : String(identifier)
        }
        if let identifier = value as? String {
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func iOSAppStoreMetadata(
        at applicationURL: URL,
        bundleInfo: [String: Any]
    ) -> IOSAppStoreMetadata? {
        let metadataURL = applicationURL.appendingPathComponent("Wrapper/iTunesMetadata.plist")
        guard
            let data = try? Data(contentsOf: metadataURL),
            let metadata = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        else {
            return nil
        }

        let deviceFamilies =
            (bundleInfo["UIDeviceFamily"] as? [Any])?.compactMap {
                ($0 as? NSNumber)?.intValue
            } ?? []
        let supportsIPhone = deviceFamilies.contains(1)
        let supportsIPad = deviceFamilies.contains(2)
        let platform: AppStorePlatform

        platform = supportsIPad && !supportsIPhone ? .iPad : .iPhone

        let storeIdentifier: String?
        if let itemID = metadata["itemId"] as? NSNumber {
            storeIdentifier = itemID.stringValue
        } else {
            storeIdentifier = metadata["itemId"] as? String
        }

        return IOSAppStoreMetadata(
            storeIdentifier: storeIdentifier,
            countryCode: metadata["storefrontCountryCode"] as? String,
            platform: platform
        )
    }

    private static func localizedInfoString(
        forKey key: String,
        in bundle: Bundle,
        preferredLanguages: [String]
    ) -> String? {
        let preferredLocalizations = Bundle.preferredLocalizations(
            from: bundle.localizations,
            forPreferences: preferredLanguages
        )

        for localization in preferredLocalizations {
            guard
                let url = bundle.url(
                    forResource: "InfoPlist",
                    withExtension: "strings",
                    subdirectory: nil,
                    localization: localization
                ),
                let data = try? Data(contentsOf: url),
                let values = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                ) as? [String: Any],
                let value = values[key] as? String,
                let value = value.nonBlankValue
            else {
                continue
            }

            return value
        }

        return nil
    }
}

struct IOSAppStoreMetadata: Sendable {
    let storeIdentifier: String?
    let countryCode: String?
    let platform: AppStorePlatform
}
