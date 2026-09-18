import Foundation

struct AppRecord: Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let bundleIdentifier: String
  let applicationURL: URL
  var currentVersion: String
  var buildVersion: String?
  let applicationModificationDate: Date?

  var source: UpdateSource
  var appStorePlatform: AppStorePlatform?
  var appStoreCountryCode: String?
  var appStoreAccountCountryCode: String?
  var status: UpdateStatus
  var latestVersion: String?
  var latestBuildVersion: String?
  var releaseNotes: String?
  var releaseDate: Date?
  var sourceURL: URL?
  var homepageURL: URL?
  var releaseNotesURL: URL?
  var updatePageURL: URL?
  var sourceIdentifier: String?
  var alternateUpdateSource: UpdateSource?
  var alternateSourceURL: URL?
  var alternateSourceIdentifier: String?
  var alternateHomepageURL: URL?
  var homebrewCaskToken: String?
  var packageByteCount: Int64?
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
    appStoreAccountCountryCode: String? = nil,
    status: UpdateStatus = .checking,
    latestVersion: String? = nil,
    latestBuildVersion: String? = nil,
    releaseNotes: String? = nil,
    releaseDate: Date? = nil,
    sourceURL: URL? = nil,
    homepageURL: URL? = nil,
    releaseNotesURL: URL? = nil,
    updatePageURL: URL? = nil,
    sourceIdentifier: String? = nil,
    alternateUpdateSource: UpdateSource? = nil,
    alternateSourceURL: URL? = nil,
    alternateSourceIdentifier: String? = nil,
    alternateHomepageURL: URL? = nil,
    homebrewCaskToken: String? = nil,
    packageByteCount: Int64? = nil,
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
    self.appStoreAccountCountryCode = appStoreAccountCountryCode
    self.status = status
    self.latestVersion = latestVersion
    self.latestBuildVersion = latestBuildVersion
    self.releaseNotes = releaseNotes
    self.releaseDate = releaseDate
    self.sourceURL = sourceURL
    self.homepageURL = homepageURL
    self.releaseNotesURL = releaseNotesURL
    self.updatePageURL = updatePageURL
    self.sourceIdentifier = sourceIdentifier
    self.alternateUpdateSource = alternateUpdateSource
    self.alternateSourceURL = alternateSourceURL
    self.alternateSourceIdentifier = alternateSourceIdentifier
    self.alternateHomepageURL = alternateHomepageURL
    self.homebrewCaskToken = homebrewCaskToken
    self.packageByteCount = packageByteCount
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
    case appStoreAccountCountryCode
    case status
    case latestVersion
    case latestBuildVersion
    case releaseNotes
    case releaseDate
    case sourceURL
    case homepageURL
    case releaseNotesURL
    case updatePageURL
    case sourceIdentifier
    case alternateUpdateSource
    case alternateSourceURL
    case alternateSourceIdentifier
    case alternateHomepageURL
    case homebrewCaskToken
    case packageByteCount
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
      appStoreAccountCountryCode: try container.decodeIfPresent(
        String.self,
        forKey: .appStoreAccountCountryCode
      ),
      status: try container.decode(UpdateStatus.self, forKey: .status),
      latestVersion: try container.decodeIfPresent(String.self, forKey: .latestVersion),
      latestBuildVersion: try container.decodeIfPresent(String.self, forKey: .latestBuildVersion),
      releaseNotes: try container.decodeIfPresent(String.self, forKey: .releaseNotes),
      releaseDate: try container.decodeIfPresent(Date.self, forKey: .releaseDate),
      sourceURL: try container.decodeIfPresent(URL.self, forKey: .sourceURL),
      homepageURL: try container.decodeIfPresent(URL.self, forKey: .homepageURL),
      releaseNotesURL: try container.decodeIfPresent(URL.self, forKey: .releaseNotesURL),
      updatePageURL: try container.decodeIfPresent(URL.self, forKey: .updatePageURL),
      sourceIdentifier: try container.decodeIfPresent(String.self, forKey: .sourceIdentifier),
      alternateUpdateSource: try container.decodeIfPresent(
        UpdateSource.self,
        forKey: .alternateUpdateSource
      ),
      alternateSourceURL: try container.decodeIfPresent(URL.self, forKey: .alternateSourceURL),
      alternateSourceIdentifier: try container.decodeIfPresent(
        String.self,
        forKey: .alternateSourceIdentifier
      ),
      alternateHomepageURL: try container.decodeIfPresent(URL.self, forKey: .alternateHomepageURL),
      homebrewCaskToken: try container.decodeIfPresent(String.self, forKey: .homebrewCaskToken),
      packageByteCount: try container.decodeIfPresent(Int64.self, forKey: .packageByteCount),
      canAutomaticallyUpdate: try container.decodeIfPresent(
        Bool.self,
        forKey: .canAutomaticallyUpdate
      ) ?? false,
      lastInstalledAt: try container.decodeIfPresent(Date.self, forKey: .lastInstalledAt)
    )
  }
}

extension AppRecord {
  var isCheckable: Bool {
    switch source {
    case .appStore, .electronBuilder, .tauri, .vscodeUpdater, .releaseJSON, .githubReleases:
      return true
    case .sparkle:
      return sourceURL != nil
    case .homebrew:
      return alternateUpdateCheckRecord != nil
    case .selfManaged:
      return false
    }
  }

  var homebrewManagedCaskToken: String? {
    homebrewCaskToken ?? (source == .homebrew ? sourceIdentifier : nil)
  }

  var alternateUpdateCheckRecord: AppRecord? {
    guard let alternateUpdateSource,
      alternateUpdateSource != .homebrew,
      alternateUpdateSource != .selfManaged,
      alternateUpdateSource != .appStore
    else {
      return nil
    }

    switch alternateUpdateSource {
    case .sparkle where alternateSourceURL == nil:
      return nil
    default:
      break
    }

    var application = self
    application.source = alternateUpdateSource
    application.sourceURL = alternateSourceURL
    application.sourceIdentifier = alternateSourceIdentifier
    application.homepageURL = alternateHomepageURL ?? homepageURL
    application.status = .checking
    application.latestVersion = nil
    application.latestBuildVersion = nil
    application.packageByteCount = nil
    application.updatePageURL = nil
    application.canAutomaticallyUpdate = false
    return application
  }

  mutating func rememberAlternateUpdateSource(from application: AppRecord) {
    guard application.source.canBeAlternateUpdateSource else { return }
    alternateUpdateSource = application.source
    alternateSourceURL = application.sourceURL
    alternateSourceIdentifier = application.sourceIdentifier
    alternateHomepageURL = application.homepageURL
  }

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

  var requiresAppStoreUpdatePageHandoff: Bool {
    guard source == .appStore else { return false }
    if appStorePlatform != .mac { return true }
    guard
      let applicationCountryCode = AppStoreCountryCode.normalized(appStoreCountryCode),
      let accountCountryCode = AppStoreCountryCode.normalized(appStoreAccountCountryCode)
    else {
      return false
    }
    return applicationCountryCode != accountCountryCode
  }

  var manualUpdateURL: URL? {
    guard source == .sparkle, needsUpdate, !canAutomaticallyUpdate,
      let updatePageURL
    else { return nil }
    return SecureUpdateURL.https(updatePageURL)
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

  func matchesSearch(_ searchText: String) -> Bool {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return true }

    if UpdateSource.isSourceSearchQuery(query) {
      return matchesSourceSearch(query)
    }

    return name.localizedCaseInsensitiveContains(query)
      || bundleIdentifier.localizedCaseInsensitiveContains(query)
      || sourceTitle.localizedCaseInsensitiveContains(query)
  }

  private func matchesSourceSearch(_ query: String) -> Bool {
    let primaryTerms: [String]
    if source == .appStore {
      primaryTerms = [source.title, sourceTitle]
    } else {
      primaryTerms = source.searchTerms
    }
    let terms = primaryTerms + (alternateUpdateSource?.searchTerms ?? [])
    return terms.contains { UpdateSource.searchTerm($0, matches: query) }
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

  var packageSizeDescription: String? {
    guard let packageByteCount, packageByteCount > 0 else {
      return nil
    }
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    formatter.includesUnit = true
    return formatter.string(fromByteCount: packageByteCount)
  }

  mutating func applyRemoteRelease(
    version: String,
    releaseDate: Date? = nil,
    releaseNotes: String? = nil,
    releaseNotesURL: URL? = nil,
    packageByteCount: Int64? = nil,
    canInstall: Bool
  ) {
    latestVersion = version
    self.releaseDate = releaseDate
    self.releaseNotes = releaseNotes
    if let releaseNotesURL {
      self.releaseNotesURL = releaseNotesURL
    }
    self.packageByteCount = packageByteCount

    let newer = VersionComparator.isNewer(version, than: currentVersion, build: buildVersion)
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

enum AppStoreCountryCode {
  static func normalized(_ raw: String?) -> String? {
    guard let raw else { return nil }
    var code = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let separator = code.firstIndex(where: { $0 == "-" || $0 == "_" }) {
      let suffix = String(code[code.index(after: separator)...])
      code = suffix.count == 2 ? suffix : String(code[..<separator])
    }

    guard code.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else {
      return nil
    }
    if code.count == 2 {
      return code
    }
    if code.count == 3 {
      return alpha2CountryCode(forAlpha3: code)
    }
    return nil
  }

  private static func alpha2CountryCode(forAlpha3 code: String) -> String? {
    let locale = Locale(identifier: "en_US_POSIX")
    guard let alpha3Name = locale.localizedString(forRegionCode: code.uppercased()) else {
      return nil
    }

    return Locale.Region.isoRegions.lazy.map(\.identifier).first { identifier in
      guard identifier.count == 2,
        identifier.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }),
        let name = locale.localizedString(forRegionCode: identifier)
      else {
        return false
      }
      return name.caseInsensitiveCompare(alpha3Name) == .orderedSame
    }?.lowercased()
  }
}

enum UpdateSource: String, Hashable, Sendable, Codable, CaseIterable {
  case appStore
  case homebrew
  case sparkle
  case electronBuilder
  case tauri
  case vscodeUpdater
  case releaseJSON
  case githubReleases
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
    case .githubReleases: "GitHub Releases"
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
    case .githubReleases: "shippingbox"
    case .selfManaged: "app.dashed"
    }
  }

  var searchTerms: [String] {
    switch self {
    case .appStore:
      ["App Store", "Mac App Store", "iPhone App Store", "iPad App Store"]
    case .homebrew:
      ["Homebrew"]
    case .sparkle:
      ["Sparkle"]
    case .electronBuilder:
      ["electron", "electron-updater"]
    case .tauri:
      ["Tauri", "Tauri updater"]
    case .vscodeUpdater:
      ["VS Code", "VS Code updater", "VSCode"]
    case .releaseJSON:
      ["Release JSON", "JSON release"]
    case .githubReleases:
      ["GitHub", "GitHub Releases"]
    case .selfManaged:
      ["未知", "Unknown"]
    }
  }

  var canBeAlternateUpdateSource: Bool {
    switch self {
    case .sparkle, .electronBuilder, .tauri, .vscodeUpdater, .releaseJSON, .githubReleases:
      return true
    case .appStore, .homebrew, .selfManaged:
      return false
    }
  }

  static func isSourceSearchQuery(_ query: String) -> Bool {
    allCases.lazy.flatMap(\.searchTerms).contains {
      searchTerm($0, matches: query)
    }
  }

  static func searchTerm(_ term: String, matches query: String) -> Bool {
    if term.localizedCaseInsensitiveCompare(query) == .orderedSame {
      return true
    }
    guard query.count >= 4 else { return false }
    return term.range(of: query, options: [.anchored, .caseInsensitive]) != nil
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

enum JSONByteCount {
  static func parse(_ value: Any?) -> Int64? {
    switch value {
    case let number as Int64:
      return number > 0 ? number : nil
    case let number as Int:
      return number > 0 ? Int64(number) : nil
    case let number as UInt64:
      return number > 0 && number <= UInt64(Int64.max) ? Int64(number) : nil
    case let number as Double:
      guard number >= 1, number <= Double(Int64.max) else { return nil }
      return Int64(number)
    case let number as NSNumber:
      let parsed = number.int64Value
      return parsed > 0 ? parsed : nil
    case let text as String:
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let parsed = Int64(trimmed), parsed > 0 else { return nil }
      return parsed
    default:
      return nil
    }
  }

  static func decode<Key: CodingKey>(
    _ container: KeyedDecodingContainer<Key>,
    forKey key: Key
  ) -> Int64? {
    if let number = try? container.decode(Int64.self, forKey: key) {
      return number > 0 ? number : nil
    }
    if let number = try? container.decode(Double.self, forKey: key) {
      return parse(number)
    }
    if let text = try? container.decode(String.self, forKey: key) {
      return parse(text)
    }
    return nil
  }
}
