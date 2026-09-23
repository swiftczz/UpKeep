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

private enum SourceDetectionMode {
  case installedOnly
  case full
}

struct ApplicationScanner: ApplicationScanning {
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
    let previousByPath = Dictionary(
      previousApplications.map { ($0.applicationURL.standardizedFileURL.path, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    return await Task.detached(priority: .userInitiated) {
      Self.scanSynchronously(
        excludingBundleIdentifier: ownBundleIdentifier,
        reusing: previousByPath,
        sourceDetection: sourceDetection
      )
    }.value
  }

  private static func scanSynchronously(
    excludingBundleIdentifier: String?,
    reusing previousByPath: [String: AppRecord] = [:],
    sourceDetection: SourceDetectionMode = .full
  ) -> [AppRecord] {
    let fileManager = FileManager.default
    let locations = [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Applications", isDirectory: true),
    ]

    var seenPaths = Set<String>()
    var records: [AppRecord] = []

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
            sourceDetection: sourceDetection
          ),
          record.bundleIdentifier != excludingBundleIdentifier
        else {
          continue
        }

        records.append(record)
      }
    }

    return sortedByModificationDate(records)
  }

  static func makeRecord(
    from applicationURL: URL,
    preferredLanguages: [String] = Locale.preferredLanguages
  ) -> AppRecord? {
    makeRecord(
      from: applicationURL,
      reusing: nil,
      preferredLanguages: preferredLanguages
    )
  }

  static func makeInstalledApplicationRecord(
    from applicationURL: URL,
    preferredLanguages: [String] = Locale.preferredLanguages
  ) -> AppRecord? {
    makeRecord(
      from: applicationURL,
      reusing: nil,
      preferredLanguages: preferredLanguages,
      sourceDetection: .installedOnly
    )
  }

  static func makeRecord(
    from applicationURL: URL,
    reusing previous: AppRecord?,
    preferredLanguages: [String] = Locale.preferredLanguages
  ) -> AppRecord? {
    makeRecord(
      from: applicationURL,
      reusing: previous,
      preferredLanguages: preferredLanguages,
      sourceDetection: .full
    )
  }

  private static func makeRecord(
    from applicationURL: URL,
    reusing previous: AppRecord?,
    preferredLanguages: [String],
    sourceDetection: SourceDetectionMode
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
    if let previous, previous.source != .vscodeUpdater,
      !(previous.source == .selfManaged
        && ExecutableUpdaterDetector.hasApplicationService(in: bundle.bundleURL)),
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

    if sourceDetection == .installedOnly {
      if hasAppStoreReceipt {
        return AppRecord(
          name: name,
          bundleIdentifier: bundleIdentifier,
          applicationURL: applicationURL,
          currentVersion: currentVersion,
          buildVersion: buildVersion,
          applicationModificationDate: applicationModificationDate,
          source: .appStore,
          appStorePlatform: .mac,
          status: .upToDate,
          sourceIdentifier: appStoreAdamIdentifier(at: applicationURL)
        )
      }
      if let iOSAppStoreMetadata {
        return AppRecord(
          name: name,
          bundleIdentifier: bundleIdentifier,
          applicationURL: applicationURL,
          currentVersion: currentVersion,
          buildVersion: buildVersion,
          applicationModificationDate: applicationModificationDate,
          source: .appStore,
          appStorePlatform: iOSAppStoreMetadata.platform,
          appStoreCountryCode: iOSAppStoreMetadata.countryCode,
          status: .upToDate,
          sourceIdentifier: iOSAppStoreMetadata.storeIdentifier
        )
      }
      if let metadata = VSCodeUpdaterDetector.detect(in: bundle.bundleURL) {
        return AppRecord(
          name: name, bundleIdentifier: bundleIdentifier, applicationURL: applicationURL,
          currentVersion: currentVersion,
          buildVersion: String(metadata.commit.prefix(7)),
          applicationModificationDate: applicationModificationDate,
          source: .vscodeUpdater, status: .checking,
          sourceURL: metadata.updateURL, homepageURL: metadata.homepageURL,
          sourceIdentifier: VSCodeUpdaterDetector.sourceIdentifier(
            quality: metadata.quality, commit: metadata.commit))
      }
      return AppRecord(
        name: name,
        bundleIdentifier: bundleIdentifier,
        applicationURL: applicationURL,
        currentVersion: currentVersion,
        buildVersion: buildVersion,
        applicationModificationDate: applicationModificationDate,
        source: .selfManaged,
        status: .selfManaged
      )
    }

    let sparkleURL = contentsURL.appendingPathComponent(
      "Frameworks/Sparkle.framework", isDirectory: true)
    let hasSparkle = FileManager.default.fileExists(atPath: sparkleURL.path)
    let feedURL = (info["SUFeedURL"] as? String).flatMap(SecureUpdateURL.https(string:))

    let source: UpdateSource
    let appStorePlatform: AppStorePlatform?
    let status: UpdateStatus
    var electronMetadata: ElectronBuilderMetadata? = nil
    var tauriEndpoint: URL? = nil
    var vscodeMetadata: VSCodeUpdaterMetadata? = nil
    var releaseJSONEndpoint: URL? = nil
    var githubReleasesMetadata: GitHubReleasesMetadata? = nil

    if hasAppStoreReceipt {
      source = .appStore
      appStorePlatform = .mac
      status = .checking
    } else if let iOSAppStoreMetadata {
      source = .appStore
      appStorePlatform = iOSAppStoreMetadata.platform
      status = .checking
    } else if hasSparkle {
      source = .sparkle
      appStorePlatform = nil
      status = feedURL == nil ? .selfManaged : .checking
    } else if let detectedElectron = ElectronBuilderDetector.detect(in: bundle.bundleURL) {
      source = .electronBuilder
      appStorePlatform = nil
      status = .checking
      electronMetadata = detectedElectron
    } else if let detectedVSCode = VSCodeUpdaterDetector.detect(in: bundle.bundleURL) {
      source = .vscodeUpdater
      appStorePlatform = nil
      status = .checking
      vscodeMetadata = detectedVSCode
      if buildVersion == nil || buildVersion == currentVersion {
        buildVersion = String(detectedVSCode.commit.prefix(7))
      }
    } else {
      let detection = ExecutableUpdaterDetector.detect(bundleURL: bundle.bundleURL)
      if let detectedTauri = detection.tauriEndpoint {
        source = .tauri
        appStorePlatform = nil
        status = .checking
        tauriEndpoint = detectedTauri
      } else if let detectedReleaseJSON = detection.releaseJSONEndpoint {
        source = .releaseJSON
        appStorePlatform = nil
        status = .checking
        releaseJSONEndpoint = detectedReleaseJSON
      } else if let detectedGitHub = detection.githubReleases.first(where: {
        GitHubReleasesDetector.matchesApplication(
          $0,
          name: name,
          bundleIdentifier: bundleIdentifier
        )
      }) {
        source = .githubReleases
        appStorePlatform = nil
        status = .checking
        githubReleasesMetadata = detectedGitHub
      } else {
        source = .selfManaged
        appStorePlatform = nil
        status = .selfManaged
      }
    }

    return AppRecord(
      name: name,
      bundleIdentifier: bundleIdentifier,
      applicationURL: applicationURL,
      currentVersion: currentVersion,
      buildVersion: buildVersion,
      applicationModificationDate: applicationModificationDate,
      source: source,
      appStorePlatform: appStorePlatform,
      appStoreCountryCode: iOSAppStoreMetadata?.countryCode,
      status: status,
      sourceURL: {
        switch source {
        case .sparkle: feedURL
        case .electronBuilder: electronMetadata?.feedURL
        case .tauri: tauriEndpoint
        case .vscodeUpdater: vscodeMetadata?.updateURL
        case .releaseJSON: releaseJSONEndpoint
        case .githubReleases: githubReleasesMetadata?.apiURL
        default: nil
        }
      }(),
      homepageURL: electronMetadata?.homepageURL ?? vscodeMetadata?.homepageURL
        ?? githubReleasesMetadata?.homepageURL,
      sourceIdentifier: {
        switch source {
        case .appStore:
          iOSAppStoreMetadata?.storeIdentifier ?? appStoreAdamIdentifier(at: applicationURL)
        case .electronBuilder:
          electronMetadata?.identifier
        case .tauri:
          tauriEndpoint?.absoluteString
        case .vscodeUpdater:
          vscodeMetadata.map {
            VSCodeUpdaterDetector.sourceIdentifier(quality: $0.quality, commit: $0.commit)
          }
        case .releaseJSON:
          releaseJSONEndpoint?.absoluteString
        case .githubReleases:
          githubReleasesMetadata?.identifier
        default:
          nil
        }
      }()
    )
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
      return previous.source == .appStore && previous.appStorePlatform == .mac
    }
    if let iOSAppStoreMetadata {
      return previous.source == .appStore
        && previous.appStorePlatform == iOSAppStoreMetadata.platform
    }
    return previous.source != .appStore
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

  private static func appStoreAdamIdentifier(at applicationURL: URL) -> String? {
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

private struct IOSAppStoreMetadata {
  let storeIdentifier: String?
  let countryCode: String?
  let platform: AppStorePlatform
}
