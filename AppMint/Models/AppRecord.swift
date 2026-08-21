import Foundation

struct AppRecord: Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let bundleIdentifier: String
  let applicationURL: URL
  let currentVersion: String
  let buildVersion: String?
  let applicationModificationDate: Date?

  var source: UpdateSource
  var appStorePlatform: AppStorePlatform?
  var appStoreCountryCode: String?
  var status: UpdateStatus
  var latestVersion: String?
  var latestBuildVersion: String?
  var releaseNotes: String?
  var releaseDate: Date?
  var sourceURL: URL?
  var homepageURL: URL?
  var releaseNotesURL: URL?
  var sourceIdentifier: String?
  var canAutomaticallyUpdate: Bool

  init(
    name: String,
    bundleIdentifier: String,
    applicationURL: URL,
    currentVersion: String,
    buildVersion: String? = nil,
    applicationModificationDate: Date? = nil,
    source: UpdateSource = .selfManaged,
    appStorePlatform: AppStorePlatform? = nil,
    appStoreCountryCode: String? = nil,
    status: UpdateStatus = .checking,
    latestVersion: String? = nil,
    latestBuildVersion: String? = nil,
    releaseNotes: String? = nil,
    releaseDate: Date? = nil,
    sourceURL: URL? = nil,
    homepageURL: URL? = nil,
    releaseNotesURL: URL? = nil,
    sourceIdentifier: String? = nil,
    canAutomaticallyUpdate: Bool = false
  ) {
    self.id = applicationURL.standardizedFileURL.path
    self.name = name
    self.bundleIdentifier = bundleIdentifier
    self.applicationURL = applicationURL
    self.currentVersion = currentVersion
    self.buildVersion = buildVersion
    self.applicationModificationDate = applicationModificationDate
    self.source = source
    self.appStorePlatform = appStorePlatform
    self.appStoreCountryCode = appStoreCountryCode
    self.status = status
    self.latestVersion = latestVersion
    self.latestBuildVersion = latestBuildVersion
    self.releaseNotes = releaseNotes
    self.releaseDate = releaseDate
    self.sourceURL = sourceURL
    self.homepageURL = homepageURL
    self.releaseNotesURL = releaseNotesURL
    self.sourceIdentifier = sourceIdentifier
    self.canAutomaticallyUpdate = canAutomaticallyUpdate
  }

  var needsUpdate: Bool {
    status == .updateAvailable
  }

  var sourceTitle: String {
    guard source == .appStore else {
      return source.title
    }
    return appStorePlatform?.title ?? "App Store"
  }

  var sourceSystemImage: String {
    source.systemImage
  }

  var sourcePlatformSystemImage: String? {
    guard source == .appStore else {
      return nil
    }
    return appStorePlatform?.systemImage
  }

  var versionSummary: String {
    guard let buildVersion,
      !buildVersion.isEmpty,
      buildVersion != currentVersion,
      !currentVersion.localizedCaseInsensitiveContains(buildVersion)
    else {
      return currentVersion
    }

    return "\(currentVersion) (\(buildVersion))"
  }
}

enum AppStorePlatform: String, Hashable, Sendable {
  case mac
  case iPhone
  case iPad

  var title: String {
    switch self {
    case .mac: "Mac App Store"
    case .iPhone: "iPhone App Store"
    case .iPad: "iPad App Store"
    }
  }

  var systemImage: String {
    switch self {
    case .mac: "macwindow"
    case .iPhone: "iphone"
    case .iPad: "ipad"
    }
  }

  var usesDesktopStoreLookup: Bool {
    self == .mac
  }
}

enum UpdateSource: String, Hashable, Sendable {
  case appStore
  case homebrew
  case sparkle
  case github
  case selfManaged

  var title: String {
    switch self {
    case .appStore: "App Store"
    case .homebrew: "Homebrew"
    case .sparkle: "Sparkle"
    case .github: "GitHub"
    case .selfManaged: "应用自身"
    }
  }

  var systemImage: String {
    switch self {
    case .appStore: "apple.logo"
    case .homebrew: "mug.fill"
    case .sparkle: "sparkles"
    case .github: "chevron.left.forwardslash.chevron.right"
    case .selfManaged: "app.dashed"
    }
  }
}

enum UpdateStatus: Hashable, Sendable {
  case checking
  case upToDate
  case updateAvailable
  case selfManaged
  case unavailable(String)

  var title: String {
    switch self {
    case .checking: "正在检查"
    case .upToDate: "已是最新"
    case .updateAvailable: "可用更新"
    case .selfManaged: "由应用管理"
    case .unavailable: "无法检查"
    }
  }
}

extension Array where Element == AppRecord {
  func availableUpdates(ignoredIDs: Set<AppRecord.ID>) -> [AppRecord] {
    filter { $0.needsUpdate && !ignoredIDs.contains($0.id) }
      .sortedByDescendingDate(\.releaseDate)
  }

  func installedApplications() -> [AppRecord] {
    filter { !$0.needsUpdate }
      .sortedByDescendingDate(\.applicationModificationDate)
  }

  func ignoredUpdates(ignoredIDs: Set<AppRecord.ID>) -> [AppRecord] {
    filter { $0.needsUpdate && ignoredIDs.contains($0.id) }
      .sortedByDescendingDate(\.releaseDate)
  }

  func sortedByDescendingDate(_ keyPath: KeyPath<AppRecord, Date?>) -> [AppRecord] {
    sorted { first, second in
      switch (first[keyPath: keyPath], second[keyPath: keyPath]) {
      case (let firstDate?, let secondDate?) where firstDate != secondDate:
        return firstDate > secondDate
      case (_?, nil):
        return true
      case (nil, _?):
        return false
      default:
        let nameComparison = first.name.localizedStandardCompare(second.name)
        if nameComparison != .orderedSame {
          return nameComparison == .orderedAscending
        }
        return first.id.localizedStandardCompare(second.id) == .orderedAscending
      }
    }
  }
}

extension Date {
  var slashDateText: String {
    Self.slashDateFormatter.string(from: self)
  }

  private static let slashDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy/MM/dd"
    return formatter
  }()
}

enum LibraryPhase: Equatable, Sendable {
  case idle
  case scanning
  case checking

  var title: String? {
    switch self {
    case .idle: nil
    case .scanning: "正在扫描应用…"
    case .checking: "正在检查更新…"
    }
  }
}

extension AppRecord {
  static let previewApps: [AppRecord] = [
    AppRecord(
      name: "Pixelmator Pro",
      bundleIdentifier: "com.pixelmatorteam.pixelmator.x",
      applicationURL: URL(fileURLWithPath: "/Applications/Pixelmator Pro.app"),
      currentVersion: "3.7.1",
      buildVersion: "30701000",
      source: .appStore,
      appStorePlatform: .mac,
      status: .updateAvailable,
      latestVersion: "3.7.2",
      releaseNotes: "提升了大型文稿的编辑性能，并修复了若干稳定性问题。",
      releaseDate: .now.addingTimeInterval(-86_400),
      sourceURL: URL(string: "https://apps.apple.com/"),
      canAutomaticallyUpdate: false
    ),
    AppRecord(
      name: "Visual Studio Code",
      bundleIdentifier: "com.microsoft.VSCode",
      applicationURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
      currentVersion: "1.103.1",
      source: .homebrew,
      status: .updateAvailable,
      latestVersion: "1.104.0",
      homepageURL: URL(string: "https://code.visualstudio.com/"),
      sourceIdentifier: "visual-studio-code",
      canAutomaticallyUpdate: true
    ),
    AppRecord(
      name: "CotEditor",
      bundleIdentifier: "com.coteditor.CotEditor",
      applicationURL: URL(fileURLWithPath: "/Applications/CotEditor.app"),
      currentVersion: "5.1.7",
      source: .sparkle,
      status: .upToDate,
      latestVersion: "5.1.7",
      releaseNotes: "当前已安装最新版本。"
    ),
    AppRecord(
      name: "Example",
      bundleIdentifier: "com.example.mac",
      applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
      currentVersion: "2.4",
      source: .selfManaged,
      status: .selfManaged
    ),
    AppRecord(
      name: "GitHub Example",
      bundleIdentifier: "com.example.github",
      applicationURL: URL(fileURLWithPath: "/Applications/GitHub Example.app"),
      currentVersion: "1.2.0",
      source: .github,
      status: .selfManaged,
      sourceURL: URL(string: "https://github.com/example/example")
    ),
  ]
}
