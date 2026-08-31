import Foundation

struct ApplicationResidueItem: Identifiable, Hashable, Sendable {
  enum Category: String, CaseIterable, Identifiable, Sendable {
    case application
    case caches
    case applicationSupport
    case preferences
    case containers
    case other

    var id: String { rawValue }

    var title: String {
      switch self {
      case .application: "应用程序"
      case .caches: "缓存"
      case .applicationSupport: "应用程序支持"
      case .preferences: "偏好设置"
      case .containers: "容器"
      case .other: "其他文件"
      }
    }

    var systemImage: String {
      switch self {
      case .application: "app.fill"
      case .caches: "internaldrive"
      case .applicationSupport: "folder.fill"
      case .preferences: "gearshape.fill"
      case .containers: "cube.box.fill"
      case .other: "doc.fill"
      }
    }
  }

  var id: String { url.standardizedFileURL.path }
  let url: URL
  let displayName: String
  let category: Category
  let byteCount: Int64

  var formattedSize: String {
    byteCount.formatted(.byteCount(style: .file))
  }
}

struct ApplicationResidueIdentity: Equatable, Sendable {
  let bundleIdentifier: String
  let teamIdentifier: String?
  let names: Set<String>
  let updaterCacheDirName: String?
  let homebrewToken: String?

  var bundleLastComponent: String {
    bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier
  }

  static func make(
    for application: AppRecord,
    teamIdentifier: String? = nil,
    bundleName: String? = nil,
    updaterCacheDirName: String? = nil
  ) -> ApplicationResidueIdentity {
    var names: Set<String> = [
      application.name,
      application.applicationURL.deletingPathExtension().lastPathComponent,
    ]
    if let bundleName, !bundleName.isEmpty {
      names.insert(bundleName)
    }
    names.formUnion(
      names.compactMap { name in
        let compact = name.replacingOccurrences(of: " ", with: "")
        return compact == name ? nil : compact
      }
    )

    return ApplicationResidueIdentity(
      bundleIdentifier: application.bundleIdentifier,
      teamIdentifier: teamIdentifier,
      names: Set(names.filter { !$0.isEmpty }),
      updaterCacheDirName: updaterCacheDirName,
      homebrewToken: application.homebrewManagedCaskToken
    )
  }

  func matches(leaf: String) -> Bool {
    let trimmed = leaf.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    let stripped = Self.stripKnownSuffixes(trimmed)
    if matchesBundleIdentifier(trimmed) || matchesBundleIdentifier(stripped) {
      return true
    }

    if let updaterCacheDirName, trimmed == updaterCacheDirName {
      return true
    }

    if names.contains(where: {
      $0.caseInsensitiveCompare(trimmed) == .orderedSame
        || $0.caseInsensitiveCompare(stripped) == .orderedSame
    }) {
      return true
    }

    if names.contains(where: { name in
      name.count >= 3
        && (trimmed.hasPrefix(name + "_") || trimmed.hasPrefix(name + "-"))
    }) {
      return true
    }

    if let teamIdentifier, trimmed.lowercased().hasPrefix(teamIdentifier.lowercased() + ".") {
      let suffix = String(trimmed.dropFirst(teamIdentifier.count + 1))
      let strippedSuffix = Self.stripKnownSuffixes(suffix)
      if matchesBundleIdentifier(suffix)
        || matchesBundleIdentifier(strippedSuffix)
        || matchesLastComponent(suffix)
        || matchesLastComponent(strippedSuffix)
        || suffix.lowercased().hasSuffix("." + bundleLastComponent.lowercased())
      {
        return true
      }
    }

    guard !Self.genericLastComponents.contains(bundleLastComponent.lowercased()) else {
      return false
    }

    return matchesLastComponent(trimmed)
      || matchesLastComponent(stripped)
      || trimmed.lowercased().hasSuffix("." + bundleLastComponent.lowercased())
  }

  private func matchesBundleIdentifier(_ value: String) -> Bool {
    let lowered = value.lowercased()
    let bundle = bundleIdentifier.lowercased()
    return lowered == bundle
      || lowered.hasPrefix(bundle + ".")
      || lowered.hasPrefix(bundle + "-")
  }

  private func matchesLastComponent(_ value: String) -> Bool {
    value.caseInsensitiveCompare(bundleLastComponent) == .orderedSame
  }

  func matches(url: URL) -> Bool {
    if let homebrewToken {
      let marker = "/Caskroom/\(homebrewToken)"
      if url.path.contains(marker + "/") || url.path.hasSuffix(marker) {
        return true
      }
    }
    return matches(leaf: url.lastPathComponent)
  }

  private static let genericLastComponents: Set<String> = [
    "app", "desktop", "mac", "macos", "helper", "launcher", "agent",
  ]

  private static let knownSuffixes = [
    ".plist.lockfile",
    ".lockfile",
    ".savedState",
    ".plist",
    ".sfl4",
    ".sfl3",
    ".sfl2",
    ".sfl",
    ".bom",
    ".log",
  ]

  private static func stripKnownSuffixes(_ leaf: String) -> String {
    for suffix in knownSuffixes where leaf.hasSuffix(suffix) {
      return String(leaf.dropLast(suffix.count))
    }
    return leaf
  }
}

enum ApplicationResiduePath {
  static func breadcrumb(for url: URL, homeDirectory: URL) -> String {
    let homePath = homeDirectory.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    let components: [String]
    if path == homePath || path.hasPrefix(homePath + "/") {
      let rest = String(path.dropFirst(homePath.count))
        .split(separator: "/")
        .map(String.init)
      components = ["Users", homeDirectory.lastPathComponent] + rest
    } else {
      components = url.standardizedFileURL.pathComponents.filter { $0 != "/" }
    }
    return components.joined(separator: " › ")
  }
}
