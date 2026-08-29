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
  var lastInstalledAt: Date?

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
    canAutomaticallyUpdate: Bool = false,
    lastInstalledAt: Date? = nil
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
    self.lastInstalledAt = lastInstalledAt
  }
}

extension AppRecord: Codable {
  private enum CodingKeys: String, CodingKey {
    case name
    case bundleIdentifier
    case applicationURL
    case currentVersion
    case buildVersion
    case applicationModificationDate
    case source
    case appStorePlatform
    case appStoreCountryCode
    case status
    case latestVersion
    case latestBuildVersion
    case releaseNotes
    case releaseDate
    case sourceURL
    case homepageURL
    case releaseNotesURL
    case sourceIdentifier
    case canAutomaticallyUpdate
    case lastInstalledAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      name: try container.decode(String.self, forKey: .name),
      bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier),
      applicationURL: try container.decode(URL.self, forKey: .applicationURL),
      currentVersion: try container.decode(String.self, forKey: .currentVersion),
      buildVersion: try container.decodeIfPresent(String.self, forKey: .buildVersion),
      applicationModificationDate: try container.decodeIfPresent(
        Date.self,
        forKey: .applicationModificationDate
      ),
      source: try container.decode(UpdateSource.self, forKey: .source),
      appStorePlatform: try container.decodeIfPresent(AppStorePlatform.self, forKey: .appStorePlatform),
      appStoreCountryCode: try container.decodeIfPresent(String.self, forKey: .appStoreCountryCode),
      status: try container.decode(UpdateStatus.self, forKey: .status),
      latestVersion: try container.decodeIfPresent(String.self, forKey: .latestVersion),
      latestBuildVersion: try container.decodeIfPresent(String.self, forKey: .latestBuildVersion),
      releaseNotes: try container.decodeIfPresent(String.self, forKey: .releaseNotes),
      releaseDate: try container.decodeIfPresent(Date.self, forKey: .releaseDate),
      sourceURL: try container.decodeIfPresent(URL.self, forKey: .sourceURL),
      homepageURL: try container.decodeIfPresent(URL.self, forKey: .homepageURL),
      releaseNotesURL: try container.decodeIfPresent(URL.self, forKey: .releaseNotesURL),
      sourceIdentifier: try container.decodeIfPresent(String.self, forKey: .sourceIdentifier),
      canAutomaticallyUpdate: try container.decodeIfPresent(
        Bool.self,
        forKey: .canAutomaticallyUpdate
      ) ?? false,
      lastInstalledAt: try container.decodeIfPresent(Date.self, forKey: .lastInstalledAt)
    )
  }
}

extension AppRecord {
  var needsUpdate: Bool {
    switch status {
    case .updateAvailable:
      return true
    case .checking, .unavailable:
      return hasNewerRelease(than: self)
    case .upToDate, .selfManaged:
      return false
    }
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
    Self.formattedVersion(
      currentVersion,
      build: includesBuildToDistinguishUpdate ? buildVersion : nil
    )
  }

  var latestVersionSummary: String? {
    guard let latestVersion else { return nil }
    return Self.formattedVersion(
      latestVersion,
      build: includesBuildToDistinguishUpdate ? latestBuildVersion : nil
    )
  }

  private var includesBuildToDistinguishUpdate: Bool {
    guard needsUpdate, let latestVersion else { return false }
    return currentVersion.localizedCaseInsensitiveCompare(latestVersion) == .orderedSame
  }

  var updateVersionSummary: String? {
    guard needsUpdate, let latestVersionSummary else { return nil }
    return "\(versionSummary) → \(latestVersionSummary)"
  }

  var versionDescription: String {
    if let updateVersionSummary {
      return "版本 \(updateVersionSummary)"
    }
    return "版本 \(versionSummary)"
  }

  mutating func applyRemoteRelease(
    version: String,
    releaseDate: Date? = nil,
    releaseNotes: String? = nil,
    releaseNotesURL: URL? = nil,
    canInstall: Bool
  ) {
    latestVersion = version
    self.releaseDate = releaseDate
    self.releaseNotes = releaseNotes
    if let releaseNotesURL {
      self.releaseNotesURL = releaseNotesURL
    }

    let newer = VersionComparator.isNewer(version, than: currentVersion)
    status = newer ? .updateAvailable : .upToDate
    canAutomaticallyUpdate = newer && canInstall
  }

  func hasNewerRelease(than installed: AppRecord) -> Bool {
    if let latestBuild = latestBuildVersion, let installedBuild = installed.buildVersion {
      return VersionComparator.isNewer(latestBuild, than: installedBuild)
    }

    guard let latestVersion else { return false }
    return VersionComparator.isNewer(
      latestVersion,
      than: installed.currentVersion,
      build: installed.buildVersion
    )
  }

  static func formattedVersion(_ version: String, build: String?) -> String {
    guard let build,
      !build.isEmpty,
      build != version,
      !version.localizedCaseInsensitiveContains(build)
    else {
      return version
    }

    return "\(version) (\(build))"
  }

  func sidebarDate(isUpdateIgnored: Bool) -> Date? {
    if needsUpdate && !isUpdateIgnored {
      return releaseDate ?? applicationModificationDate
    }
    return lastInstalledAt ?? applicationModificationDate
  }

  var sidebarDateIsReleaseDate: Bool {
    needsUpdate && releaseDate != nil
  }
}

enum AppStorePlatform: String, Hashable, Sendable, Codable {
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

enum UpdateSource: String, Hashable, Sendable, Codable {
  case appStore
  case homebrew
  case sparkle
  case electronBuilder
  case tauri
  case vscodeUpdater
  case releaseJSON
  case selfManaged

  var title: String {
    switch self {
    case .appStore: "App Store"
    case .homebrew: "Homebrew"
    case .sparkle: "Sparkle"
    case .electronBuilder: "electron-updater"
    case .tauri: "Tauri updater"
    case .vscodeUpdater: "VS Code updater"
    case .releaseJSON: "JSON release"
    case .selfManaged: "未知"
    }
  }

  var systemImage: String {
    switch self {
    case .appStore: "apple.logo"
    case .homebrew: "mug.fill"
    case .sparkle: "sparkles"
    case .electronBuilder: "atom"
    case .tauri: "drop.fill"
    case .vscodeUpdater: "chevron.left.forwardslash.chevron.right"
    case .releaseJSON: "doc.text"
    case .selfManaged: "app.dashed"
    }
  }
}

enum UpdateStatus: Hashable, Sendable, Codable {
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
    case .selfManaged: "自行更新"
    case .unavailable: "无法检查"
    }
  }
}

extension Array where Element == AppRecord {
  func availableUpdates(ignoredIDs: Set<AppRecord.ID>) -> [AppRecord] {
    filter { $0.needsUpdate && !ignoredIDs.contains($0.id) }
      .sortedByDescendingDate { $0.releaseDate ?? $0.applicationModificationDate }
  }

  func installedApplications() -> [AppRecord] {
    filter { !$0.needsUpdate }
      .sortedByDescendingDate { $0.lastInstalledAt ?? $0.applicationModificationDate }
  }

  func ignoredUpdates(ignoredIDs: Set<AppRecord.ID>) -> [AppRecord] {
    filter { $0.needsUpdate && ignoredIDs.contains($0.id) }
      .sortedByDescendingDate { $0.releaseDate ?? $0.applicationModificationDate }
  }

  func sortedByDescendingDate(_ keyPath: KeyPath<AppRecord, Date?>) -> [AppRecord] {
    sortedByDescendingDate { $0[keyPath: keyPath] }
  }

  func sortedByDescendingDate(_ date: (AppRecord) -> Date?) -> [AppRecord] {
    sorted { first, second in
      switch (date(first), date(second)) {
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
      name: "ChatWise",
      bundleIdentifier: "app.chatwise",
      applicationURL: URL(fileURLWithPath: "/Applications/ChatWise.app"),
      currentVersion: "26.8.0",
      source: .electronBuilder,
      status: .updateAvailable,
      latestVersion: "26.8.1",
      sourceURL: URL(string: "https://releases.chatwise.app/latest-mac.yml"),
      canAutomaticallyUpdate: true
    ),
    AppRecord(
      name: "Grok",
      bundleIdentifier: "com.example.grok",
      applicationURL: URL(fileURLWithPath: "/Applications/Grok.app"),
      currentVersion: "0.2.20",
      source: .tauri,
      status: .updateAvailable,
      latestVersion: "0.2.24",
      sourceURL: URL(
        string: "https://github.com/RongleCat/grok-app/releases/download/grok-desktop-latest/latest.json"
      ),
      canAutomaticallyUpdate: true
    ),
  ]
}
