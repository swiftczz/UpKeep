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
  var byteCount: Int64
  var matchReason: ApplicationResidueMatchReason = .nameOnly
  var isSizeCalculated = true

  var isSelectedByDefault: Bool { matchReason.isSelectedByDefault }

  static func defaultSelection(in items: [ApplicationResidueItem]) -> Set<String> {
    Set(items.filter(\.isSelectedByDefault).map(\.id))
  }

  var formattedSize: String {
    isSizeCalculated ? byteCount.formatted(.byteCount(style: .file)) : "正在计算…"
  }
}

enum ApplicationResidueMatchReason: Hashable, Sendable {
  case application
  case bundleIdentifier
  case declaredUpdaterCache
  case homebrewCask
  case embeddedBundle
  case possibleBundleVariant
  case nameOnly
  case undeclaredGroupContainer
  case unverifiedGroupContainer
  case sharedWith([String])

  var isSelectedByDefault: Bool {
    switch self {
    case .application, .bundleIdentifier, .homebrewCask:
      true
    case .declaredUpdaterCache, .embeddedBundle, .possibleBundleVariant, .nameOnly, .undeclaredGroupContainer,
      .unverifiedGroupContainer, .sharedWith:
      false
    }
  }

  var explanation: String {
    switch self {
    case .application: "所选应用程序"
    case .bundleIdentifier: "完整 Bundle ID 匹配"
    case .declaredUpdaterCache: "应用声明的更新缓存，可能与其他版本共用；默认保留"
    case .homebrewCask: "Homebrew 安装记录"
    case .embeddedBundle: "应用内辅助程序的数据，可能被其他应用共用；默认保留"
    case .possibleBundleVariant: "仅 Bundle ID 前缀相同，可能属于独立测试版或其他应用；默认保留"
    case .nameOnly: "仅名称相似，归属未确认；默认保留"
    case .undeclaredGroupContainer: "名称相关，但未找到应用的容器声明；默认保留"
    case .unverifiedGroupContainer: "应用声明的共享容器，可能被其他应用共用；默认保留"
    case .sharedWith(let names): "也被 \(names.joined(separator: "、")) 使用；默认保留"
    }
  }
}

enum ApplicationResidueLocation: Sendable {
  case containers
  case groupContainers
  case applicationScripts
  case preferences
  case byHostPreferences
  case caches
  case other
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
    match(leaf: leaf, location: .other) != nil
  }

  func match(
    leaf: String,
    location: ApplicationResidueLocation
  ) -> ApplicationResidueMatchReason? {
    let trimmed = leaf.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !bundleIdentifier.isEmpty else { return nil }

    let stripped = Self.stripKnownSuffixes(trimmed)
    if Self.matchesExactBundleIdentifier(bundleIdentifier, leaf: trimmed, location: location) {
      return .bundleIdentifier
    }

    if let updaterCacheDirName, trimmed == updaterCacheDirName, location == .caches {
      return .declaredUpdaterCache
    }

    let lowered = trimmed.lowercased()
    let bundle = bundleIdentifier.lowercased()
    if lowered.hasPrefix(bundle + ".") || lowered.hasPrefix(bundle + "-") {
      return .possibleBundleVariant
    }

    if let updaterCacheDirName, trimmed == updaterCacheDirName {
      return .nameOnly
    }

    if names.contains(where: {
      $0.caseInsensitiveCompare(trimmed) == .orderedSame
        || $0.caseInsensitiveCompare(stripped) == .orderedSame
    }) {
      return .nameOnly
    }

    if names.contains(where: { name in
      name.count >= 3
        && (trimmed.hasPrefix(name + "_") || trimmed.hasPrefix(name + "-"))
    }) {
      return .nameOnly
    }

    if let teamIdentifier, trimmed.lowercased().hasPrefix(teamIdentifier.lowercased() + ".") {
      let suffix = String(trimmed.dropFirst(teamIdentifier.count + 1))
      let strippedSuffix = Self.stripKnownSuffixes(suffix)
      if suffix.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        || strippedSuffix.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        || matchesLastComponent(suffix)
        || matchesLastComponent(strippedSuffix)
      {
        return .undeclaredGroupContainer
      }
    }

    guard !Self.genericLastComponents.contains(bundleLastComponent.lowercased()) else {
      return nil
    }

    return matchesLastComponent(trimmed) || matchesLastComponent(stripped) ? .nameOnly : nil
  }

  static func matchesExactBundleIdentifier(
    _ identifier: String,
    leaf: String,
    location: ApplicationResidueLocation
  ) -> Bool {
    let bundle = identifier.lowercased()
    let leaf = leaf.lowercased()
    guard !bundle.isEmpty else { return false }

    switch location {
    case .preferences:
      return leaf == bundle + ".plist" || leaf == bundle + ".plist.lockfile"
    case .byHostPreferences:
      guard leaf.hasPrefix(bundle + ".") else { return false }
      let suffix = String(leaf.dropFirst(bundle.count + 1))
      for ending in [".plist.lockfile", ".plist"] where suffix.hasSuffix(ending) {
        return UUID(uuidString: String(suffix.dropLast(ending.count))) != nil
      }
      return false
    case .containers, .groupContainers, .applicationScripts, .caches:
      return leaf == bundle
    case .other:
      return leaf == bundle || stripKnownSuffixes(leaf) == bundle
    }
  }

  private func matchesLastComponent(_ value: String) -> Bool {
    value.caseInsensitiveCompare(bundleLastComponent) == .orderedSame
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
    for suffix in knownSuffixes where leaf.lowercased().hasSuffix(suffix.lowercased()) {
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
