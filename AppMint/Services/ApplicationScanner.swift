import Foundation

protocol ApplicationScanning: Sendable {
  func scan() async -> [AppRecord]
}

struct ApplicationScanner: ApplicationScanning {
  func scan() async -> [AppRecord] {
    let ownBundleIdentifier = Bundle.main.bundleIdentifier

    return await Task.detached(priority: .userInitiated) {
      Self.scanSynchronously(excludingBundleIdentifier: ownBundleIdentifier)
    }.value
  }

  private static func scanSynchronously(excludingBundleIdentifier: String?) -> [AppRecord] {
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
          let record = makeRecord(from: applicationURL),
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
    let buildVersion = info["CFBundleVersion"] as? String
    let applicationModificationDate = latestModificationDate(
      of: applicationURL,
      bundle: bundle
    )

    let contentsURL = bundle.bundleURL.appendingPathComponent("Contents", isDirectory: true)
    let receiptURL = contentsURL.appendingPathComponent("_MASReceipt/receipt")
    let sparkleURL = contentsURL.appendingPathComponent(
      "Frameworks/Sparkle.framework", isDirectory: true)
    let hasAppStoreReceipt = FileManager.default.fileExists(atPath: receiptURL.path)
    let iOSAppStoreMetadata = iOSAppStoreMetadata(at: applicationURL, bundleInfo: info)
    let hasSparkle = FileManager.default.fileExists(atPath: sparkleURL.path)
    let feedURL = (info["SUFeedURL"] as? String).flatMap(SecureUpdateURL.https(string:))

    let source: UpdateSource
    let appStorePlatform: AppStorePlatform?
    let status: UpdateStatus
    var electronMetadata: ElectronBuilderMetadata? = nil
    var tauriEndpoint: URL? = nil

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
    } else if let detectedTauri = TauriUpdaterDetector.detect(bundleURL: bundle.bundleURL) {
      source = .tauri
      appStorePlatform = nil
      status = .checking
      tauriEndpoint = detectedTauri
    } else {
      source = .selfManaged
      appStorePlatform = nil
      status = .selfManaged
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
        default: nil
        }
      }(),
      homepageURL: electronMetadata?.homepageURL,
      sourceIdentifier: {
        switch source {
        case .appStore:
          iOSAppStoreMetadata?.storeIdentifier ?? appStoreAdamIdentifier(at: applicationURL)
        case .electronBuilder:
          electronMetadata?.identifier
        case .tauri:
          tauriEndpoint?.absoluteString
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
      applicationURL,
      bundle.bundleURL,
      bundle.bundleURL.appendingPathComponent("Contents", isDirectory: true),
      bundle.bundleURL.appendingPathComponent("Contents/Info.plist"),
    ]
    if let executableURL = bundle.executableURL {
      urls.append(executableURL)
    }
    return urls.compactMap(contentModificationDate(at:)).max()
  }

  private static func contentModificationDate(at url: URL) -> Date? {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
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
    if let bundle = Bundle(url: applicationURL) {
      return bundle
    }

    let wrappedBundleURL =
      applicationURL
      .appendingPathComponent("WrappedBundle")
      .resolvingSymlinksInPath()
    return Bundle(url: wrappedBundleURL)
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
