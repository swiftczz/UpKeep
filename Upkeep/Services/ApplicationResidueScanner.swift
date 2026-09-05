import Darwin
import Foundation

struct ApplicationResidueScanner: @unchecked Sendable {
  var fileManager: FileManager
  var homeDirectory: URL
  var libraryDirectories: [URL]
  var receiptsDirectory: URL?
  var darwinDirectories: [URL]
  var caskroomDirectories: [URL]
  var teamIdentifier: @Sendable (URL) -> String?
  var bundleName: @Sendable (URL) -> String?
  var updaterCacheDirName: @Sendable (URL) -> String?
  var systemManagedDarwinItem: @Sendable (URL) -> Bool = Self.isSystemManagedDarwinItem(_:)

  var ownershipInventory: @Sendable () -> ApplicationResidueOwnershipInventory = { .init() }
  var applicationGroups: @Sendable (URL) -> Set<String>? = { _ in nil }

  static var live: ApplicationResidueScanner {
    let fileManager = FileManager.default
    let homeDirectory = fileManager.homeDirectoryForCurrentUser
    let temporaryDirectory = fileManager.temporaryDirectory.resolvingSymlinksInPath()
    let darwinCacheDirectory = temporaryDirectory.deletingLastPathComponent()
      .appendingPathComponent("C", isDirectory: true)

    return ApplicationResidueScanner(
      fileManager: fileManager,
      homeDirectory: homeDirectory,
      libraryDirectories: [
        homeDirectory.appendingPathComponent("Library", isDirectory: true),
        URL(fileURLWithPath: "/Library", isDirectory: true),
      ],
      receiptsDirectory: URL(fileURLWithPath: "/var/db/receipts", isDirectory: true),
      darwinDirectories: [darwinCacheDirectory, temporaryDirectory],
      caskroomDirectories: [
        URL(fileURLWithPath: "/opt/homebrew/Caskroom", isDirectory: true),
        URL(fileURLWithPath: "/usr/local/Caskroom", isDirectory: true),
      ],
      teamIdentifier: { ApplicationCodeSigning.teamIdentifier(at: $0) },
      bundleName: { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleName") as? String },
      updaterCacheDirName: Self.updaterCacheDirName(in:),
      ownershipInventory: {
        ApplicationResidueOwnershipInventory.scan(
          applicationDirectories: [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true),
          ],
          updaterCacheDirName: Self.updaterCacheDirName(in:)
        )
      },
      applicationGroups: { ApplicationCodeSigning.applicationGroups(at: $0) }
    )
  }

  func items(for application: AppRecord) -> [ApplicationResidueItem] {
    let identity = ApplicationResidueIdentity.make(
      for: application,
      teamIdentifier: teamIdentifier(application.applicationURL),
      bundleName: bundleName(application.applicationURL),
      updaterCacheDirName: updaterCacheDirName(application.applicationURL)
    )

    let inventory = ownershipInventory()
    let matcher = inventory.matcher(
      identity: identity,
      applicationURL: application.applicationURL,
      declaredGroups: applicationGroups(application.applicationURL) ?? []
    )
    var found: [URL: ApplicationResidueItem] = [:]

    func add(
      _ url: URL,
      category: ApplicationResidueItem.Category,
      reason: ApplicationResidueMatchReason
    ) {
      let standardized = url.standardizedFileURL
      guard found[standardized] == nil, fileManager.fileExists(atPath: standardized.path) else {
        return
      }
      found[standardized] = ApplicationResidueItem(
        url: standardized,
        displayName: displayName(for: standardized),
        category: category,
        byteCount: allocatedSize(of: standardized),
        matchReason: reason
      )
    }

    func collect(
      in directory: URL,
      category: ApplicationResidueItem.Category,
      location: ApplicationResidueLocation = .other,
      skipsSystemManagedItems: Bool = false
    ) {
      let children =
        (try? fileManager.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []
        )) ?? []
      for child in children {
        guard let reason = matcher.match(leaf: child.lastPathComponent, location: location) else {
          continue
        }
        if skipsSystemManagedItems, systemManagedDarwinItem(child) { continue }
        add(child, category: category, reason: reason)
      }
    }

    add(application.applicationURL, category: .application, reason: .application)

    for libraryDirectory in libraryDirectories {
      collect(
        in: libraryDirectory.appendingPathComponent("Containers", isDirectory: true),
        category: .containers,
        location: .containers
      )
      collect(
        in: libraryDirectory.appendingPathComponent("Group Containers", isDirectory: true),
        category: .containers,
        location: .groupContainers
      )
      collect(
        in: libraryDirectory.appendingPathComponent("Application Support", isDirectory: true),
        category: .applicationSupport
      )
      collect(
        in: libraryDirectory.appendingPathComponent("Preferences", isDirectory: true),
        category: .preferences,
        location: .preferences
      )
      collect(
        in: libraryDirectory.appendingPathComponent("Preferences/ByHost", isDirectory: true),
        category: .preferences,
        location: .byHostPreferences
      )
      collect(
        in: libraryDirectory.appendingPathComponent("Caches", isDirectory: true),
        category: .caches,
        location: .caches
      )
      collect(
        in: libraryDirectory.appendingPathComponent("Logs", isDirectory: true),
        category: .other
      )
      collect(
        in: libraryDirectory.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true),
        category: .other
      )
      collect(
        in: libraryDirectory.appendingPathComponent("HTTPStorages", isDirectory: true),
        category: .other
      )
      collect(
        in: libraryDirectory.appendingPathComponent("Cookies", isDirectory: true),
        category: .other
      )
      collect(
        in: libraryDirectory.appendingPathComponent("WebKit", isDirectory: true),
        category: .other
      )
      collect(
        in: libraryDirectory.appendingPathComponent("Saved Application State", isDirectory: true),
        category: .other
      )
      collect(
        in: libraryDirectory.appendingPathComponent("Application Scripts", isDirectory: true),
        category: .other,
        location: .applicationScripts
      )
      collect(
        in: libraryDirectory.appendingPathComponent("LaunchAgents", isDirectory: true),
        category: .other
      )
      collect(
        in: libraryDirectory.appendingPathComponent("LaunchDaemons", isDirectory: true),
        category: .other
      )
      collect(
        in: libraryDirectory.appendingPathComponent("Services", isDirectory: true),
        category: .other
      )
    }

    if let receiptsDirectory {
      collect(
        in: receiptsDirectory,
        category: .other
      )
    }

    for directory in darwinDirectories {
      let category: ApplicationResidueItem.Category =
        directory.lastPathComponent == "C" ? .caches : .other
      collect(
        in: directory,
        category: category,
        location: category == .caches ? .caches : .other,
        skipsSystemManagedItems: true
      )
    }

    if let token = identity.homebrewToken {
      for caskroom in caskroomDirectories {
        add(
          caskroom.appendingPathComponent(token, isDirectory: true),
          category: .other,
          reason: .homebrewCask
        )
      }
    }

    return found.values.sorted { lhs, rhs in
      if lhs.category != rhs.category {
        return lhs.category.sortOrder < rhs.category.sortOrder
      }
      if lhs.byteCount != rhs.byteCount {
        return lhs.byteCount > rhs.byteCount
      }
      return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
  }

  static func isSystemManagedDarwinItem(_ url: URL) -> Bool {
    hasExtendedAttribute("com.apple.rootless", at: url) || hasSystemNoUnlinkFlag(at: url)
  }

  private static func hasExtendedAttribute(_ name: String, at url: URL) -> Bool {
    url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return false }
      return getxattr(path, name, nil, 0, 0, 0) >= 0
    }
  }

  private static func hasSystemNoUnlinkFlag(at url: URL) -> Bool {
    var info = stat()
    let status = url.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return lstat(path, &info)
    }
    guard status == 0 else { return false }

    let protectedFlags =
      UInt32(SF_NOUNLINK)
      | UInt32(SF_RESTRICTED)
      | UInt32(SF_IMMUTABLE)
    return info.st_flags & protectedFlags != 0
  }

  private func displayName(for url: URL) -> String {
    if url.pathExtension.lowercased() == "app" {
      return url.deletingPathExtension().lastPathComponent
    }
    return url.lastPathComponent
  }

  private func allocatedSize(of url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [
      .isRegularFileKey,
      .isDirectoryKey,
      .totalFileAllocatedSizeKey,
      .fileAllocatedSizeKey,
      .fileSizeKey,
    ])

    if values?.isRegularFile == true {
      return Int64(
        values?.totalFileAllocatedSize
          ?? values?.fileAllocatedSize
          ?? values?.fileSize
          ?? 0
      )
    }

    guard
      let enumerator = fileManager.enumerator(
        at: url,
        includingPropertiesForKeys: [
          .isRegularFileKey,
          .totalFileAllocatedSizeKey,
          .fileAllocatedSizeKey,
          .fileSizeKey,
        ],
        options: [],
        errorHandler: { _, _ in true }
      )
    else {
      return 0
    }

    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      let fileValues = try? fileURL.resourceValues(forKeys: [
        .isRegularFileKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .fileSizeKey,
      ])
      guard fileValues?.isRegularFile == true else { continue }
      total += Int64(
        fileValues?.totalFileAllocatedSize
          ?? fileValues?.fileAllocatedSize
          ?? fileValues?.fileSize
          ?? 0
      )
    }
    return total
  }

  private static func updaterCacheDirName(in bundleURL: URL) -> String? {
    let configurationURLs = [
      bundleURL.appendingPathComponent("Contents/Resources/app-update.yml"),
      bundleURL.appendingPathComponent("Contents/Resources/app-update.yaml"),
    ]
    for configurationURL in configurationURLs {
      guard
        let text = try? String(contentsOf: configurationURL, encoding: .utf8),
        let values = ElectronBuilderYAML.flatValues(in: text)
      else {
        continue
      }
      if let name = values["updaterCacheDirName"]?.nonBlankYAMLValue {
        return name
      }
    }
    return nil
  }
}

extension ApplicationResidueItem.Category {
  fileprivate var sortOrder: Int {
    switch self {
    case .application: 0
    case .caches: 1
    case .applicationSupport: 2
    case .preferences: 3
    case .containers: 4
    case .other: 5
    }
  }
}
