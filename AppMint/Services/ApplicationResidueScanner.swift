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
      updaterCacheDirName: Self.updaterCacheDirName(in:)
    )
  }

  func items(for application: AppRecord) -> [ApplicationResidueItem] {
    let identity = ApplicationResidueIdentity.make(
      for: application,
      teamIdentifier: teamIdentifier(application.applicationURL),
      bundleName: bundleName(application.applicationURL),
      updaterCacheDirName: updaterCacheDirName(application.applicationURL)
    )

    var found: [URL: ApplicationResidueItem] = [:]

    func add(_ url: URL, category: ApplicationResidueItem.Category) {
      let standardized = url.standardizedFileURL
      guard found[standardized] == nil, fileManager.fileExists(atPath: standardized.path) else {
        return
      }
      var isDirectory: ObjCBool = false
      fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory)
      found[standardized] = ApplicationResidueItem(
        url: standardized,
        displayName: displayName(for: standardized),
        category: category,
        byteCount: allocatedSize(of: standardized),
        isDirectory: isDirectory.boolValue
      )
    }

    add(application.applicationURL, category: .application)

    for libraryDirectory in libraryDirectories {
      addMatches(
        in: libraryDirectory.appendingPathComponent("Containers", isDirectory: true),
        identity: identity,
        category: .containers,
        into: add
      )
      addMatches(
        in: libraryDirectory.appendingPathComponent("Group Containers", isDirectory: true),
        identity: identity,
        category: .containers,
        into: add
      )
      addMatches(
        in: libraryDirectory.appendingPathComponent("Application Support", isDirectory: true),
        identity: identity,
        category: .applicationSupport,
        into: add
      )
      addMatches(
        in: libraryDirectory.appendingPathComponent("Preferences", isDirectory: true),
        identity: identity,
        category: .preferences,
        into: add
      )
      addMatches(
        in: libraryDirectory.appendingPathComponent("Preferences/ByHost", isDirectory: true),
        identity: identity,
        category: .preferences,
        into: add
      )
      addMatches(
        in: libraryDirectory.appendingPathComponent("Caches", isDirectory: true),
        identity: identity,
        category: .caches,
        into: add
      )
      addMatches(
        in: libraryDirectory.appendingPathComponent("Logs", isDirectory: true),
        identity: identity,
        category: .other,
        into: add
      )
      addMatches(
        in: libraryDirectory.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true),
        identity: identity,
        category: .other,
        into: add
      )
      addMatches(
        in: libraryDirectory.appendingPathComponent("HTTPStorages", isDirectory: true),
        identity: identity,
        category: .other,
        into: add
      )
      addMatches(
        in: libraryDirectory.appendingPathComponent("Cookies", isDirectory: true),
        identity: identity,
        category: .other,
        into: add
      )
      addMatches(
        in: libraryDirectory.appendingPathComponent("WebKit", isDirectory: true),
        identity: identity,
        category: .other,
        into: add
      )
      addMatches(
        in: libraryDirectory.appendingPathComponent("Saved Application State", isDirectory: true),
        identity: identity,
        category: .other,
        into: add
      )
      addMatches(
        in: libraryDirectory.appendingPathComponent("Application Scripts", isDirectory: true),
        identity: identity,
        category: .other,
        into: add
      )
      addMatches(
        in: libraryDirectory.appendingPathComponent("LaunchAgents", isDirectory: true),
        identity: identity,
        category: .other,
        into: add
      )
      addMatches(
        in: libraryDirectory.appendingPathComponent("LaunchDaemons", isDirectory: true),
        identity: identity,
        category: .other,
        into: add
      )
      addMatches(
        in: libraryDirectory.appendingPathComponent("Services", isDirectory: true),
        identity: identity,
        category: .other,
        into: add
      )
    }

    if let receiptsDirectory {
      addMatches(
        in: receiptsDirectory,
        identity: identity,
        category: .other,
        into: add
      )
    }

    for directory in darwinDirectories {
      let category: ApplicationResidueItem.Category =
        directory.lastPathComponent == "C" ? .caches : .other
      addMatches(in: directory, identity: identity, category: category, into: add)
    }

    if let token = identity.homebrewToken {
      for caskroom in caskroomDirectories {
        add(
          caskroom.appendingPathComponent(token, isDirectory: true),
          category: .other
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

  private func addMatches(
    in directory: URL,
    identity: ApplicationResidueIdentity,
    category: ApplicationResidueItem.Category,
    into add: (URL, ApplicationResidueItem.Category) -> Void
  ) {
    let children =
      (try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
      )) ?? []

    for child in children where identity.matches(url: child) {
      add(child, category)
    }
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
