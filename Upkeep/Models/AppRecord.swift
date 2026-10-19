import Foundation

struct AppRecord: Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let bundleIdentifier: String
  let applicationURL: URL
  var currentVersion: String
  var buildVersion: String?
  let applicationModificationDate: Date?

  var updateConfiguration: UpdateConfiguration
  var alternateUpdateConfiguration: UpdateConfiguration?
  /// The full route confirmed by an installation or a matching local receipt.
  var installedUpdateConfiguration: UpdateConfiguration?
  var appStorePlatform: AppStorePlatform?
  var appStoreCountryCode: String?
  var appStoreAccountCountryCode: String?
  var status: UpdateStatus
  var latestVersion: String?
  var latestBuildVersion: String?
  var releaseNotes: String?
  var releaseDate: Date?
  var releaseNotesURL: URL?
  var updatePageURL: URL?
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
    updateConfiguration: UpdateConfiguration = UpdateConfiguration(mechanism: .selfManaged),
    appStorePlatform: AppStorePlatform? = nil,
    appStoreCountryCode: String? = nil,
    appStoreAccountCountryCode: String? = nil,
    status: UpdateStatus = .checking,
    latestVersion: String? = nil,
    latestBuildVersion: String? = nil,
    releaseNotes: String? = nil,
    releaseDate: Date? = nil,
    releaseNotesURL: URL? = nil,
    updatePageURL: URL? = nil,
    alternateUpdateConfiguration: UpdateConfiguration? = nil,
    homebrewCaskToken: String? = nil,
    packageByteCount: Int64? = nil,
    canAutomaticallyUpdate: Bool = false,
    lastInstalledAt: Date? = nil,
    installedUpdateConfiguration: UpdateConfiguration? = nil
  ) {
    self.id = applicationURL.standardizedFileURL.path
    self.name = name
    self.bundleIdentifier = bundleIdentifier
    self.applicationURL = applicationURL
    self.currentVersion = currentVersion
    self.buildVersion = buildVersion
    self.applicationModificationDate = applicationModificationDate
    self.updateConfiguration = updateConfiguration
    self.appStorePlatform = appStorePlatform
    self.appStoreCountryCode = appStoreCountryCode
    self.appStoreAccountCountryCode = appStoreAccountCountryCode
    self.status = status
    self.latestVersion = latestVersion
    self.latestBuildVersion = latestBuildVersion
    self.releaseNotes = releaseNotes
    self.releaseDate = releaseDate
    self.releaseNotesURL = releaseNotesURL
    self.updatePageURL = updatePageURL
    self.alternateUpdateConfiguration = alternateUpdateConfiguration
    self.homebrewCaskToken = homebrewCaskToken
    self.packageByteCount = packageByteCount
    self.canAutomaticallyUpdate = canAutomaticallyUpdate
    self.lastInstalledAt = lastInstalledAt
    self.installedUpdateConfiguration = installedUpdateConfiguration
  }
}

extension AppRecord {
  var isCheckable: Bool {
    if updateConfiguration.mechanism == .homebrew { return alternateUpdateCheckRecord != nil }
    return updateConfiguration.isCheckable
  }

  var homebrewManagedCaskToken: String? {
    homebrewCaskToken
      ?? (updateConfiguration.mechanism == .homebrew ? updateConfiguration.identifier : nil)
  }

  var alternateUpdateCheckRecord: AppRecord? {
    guard let alternateUpdateConfiguration,
      alternateUpdateConfiguration.mechanism.canBeAlternateUpdateMechanism,
      alternateUpdateConfiguration.isCheckable
    else { return nil }

    var application = self
    application.updateConfiguration = alternateUpdateConfiguration
    application.updateConfiguration.homepageURL =
      alternateUpdateConfiguration.homepageURL
      ?? updateConfiguration.homepageURL
    application.status = .checking
    application.latestVersion = nil
    application.latestBuildVersion = nil
    application.releaseNotes = nil
    application.releaseNotesURL = nil
    application.releaseDate = nil
    application.packageByteCount = nil
    application.updatePageURL = nil
    application.canAutomaticallyUpdate = false
    return application
  }

  mutating func rememberAlternateUpdateConfiguration(from application: AppRecord) {
    guard application.updateConfiguration.mechanism.canBeAlternateUpdateMechanism else { return }
    alternateUpdateConfiguration = application.updateConfiguration
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
    guard updateConfiguration.mechanism == .appStore else { return false }
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
    guard updateConfiguration.mechanism == .sparkle, needsUpdate, !canAutomaticallyUpdate,
      let updatePageURL
    else { return nil }
    return SecureUpdateURL.https(updatePageURL)
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

  /// Release metadata can only be shared when both records describe the same release.
  func hasSameRelease(as other: AppRecord) -> Bool {
    func identity(_ app: AppRecord) -> (String, String?) {
      let parts = (app.latestVersion ?? app.currentVersion).split(separator: ",", maxSplits: 1)
      var version = parts.first.map(String.init)?.lowercased() ?? ""
      if version.hasPrefix("v") { version.removeFirst() }
      let build =
        app.latestBuildVersion
        ?? (parts.count > 1 ? String(parts[1]) : nil)
        ?? (app.latestVersion == nil || app.latestVersion == app.currentVersion
          ? app.buildVersion : nil)
      return (version, build)
    }
    let lhs = identity(self)
    let rhs = identity(other)
    guard !lhs.0.isEmpty, lhs.0 == rhs.0 else { return false }
    if let leftBuild = lhs.1, let rightBuild = rhs.1 { return leftBuild == rightBuild }
    return true
  }

  mutating func clearReleaseMetadata() {
    releaseNotes = nil
    releaseNotesURL = nil
    releaseDate = nil
    packageByteCount = nil
  }

  mutating func discardRemoteRelease() {
    latestVersion = nil
    latestBuildVersion = nil
    clearReleaseMetadata()
    updatePageURL = nil
    canAutomaticallyUpdate = false
    status = updateConfiguration.mechanism == .selfManaged ? .selfManaged : .checking
  }

  mutating func applyInstalledRelease() {
    let previous = self
    latestVersion = currentVersion
    latestBuildVersion = buildVersion
    if !hasSameRelease(as: previous) { clearReleaseMetadata() }
    status = .upToDate
    canAutomaticallyUpdate = false
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
    self.releaseNotesURL = releaseNotesURL
    self.packageByteCount = packageByteCount

    let newer = VersionComparator.isNewer(version, than: currentVersion, build: buildVersion)
    status = newer ? .updateAvailable : .upToDate
    canAutomaticallyUpdate = newer && canInstall
  }

  func hasNewerRelease(than installed: AppRecord) -> Bool {
    if updateConfiguration.mechanism == .vscodeUpdater {
      guard let latestVersion else { return false }
      let commit =
        installed.updateConfiguration.mechanism == .vscodeUpdater
        ? installed.updateConfiguration.identifier.flatMap(
          VSCodeUpdaterDetector.parseSourceIdentifier)?.commit
        : nil
      return VSCodeUpdatePayload(productVersion: latestVersion, commit: latestBuildVersion)
        .shouldOfferUpdate(
          against: installed.currentVersion, currentCommit: commit,
          currentBuildVersion: installed.buildVersion)
    }

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

extension Array where Element == AppRecord {
  func availableUpdates(ignoredIDs: Set<AppRecord.ID>) -> [AppRecord] {
    filter { $0.needsUpdate && !ignoredIDs.contains($0.id) }
      .sortedByDescendingDate { $0.releaseDate ?? $0.applicationModificationDate }
  }

  func installedApplications(ignoredIDs: Set<AppRecord.ID> = []) -> [AppRecord] {
    filter { !$0.needsUpdate && !ignoredIDs.contains($0.id) }
      .sortedByDescendingDate { $0.lastInstalledAt ?? $0.applicationModificationDate }
  }

  func ignoredUpdates(ignoredIDs: Set<AppRecord.ID>) -> [AppRecord] {
    filter { ignoredIDs.contains($0.id) }
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
      updateConfiguration: UpdateConfiguration(
        mechanism: .appStore, feedURL: URL(string: "https://apps.apple.com/")),
      appStorePlatform: .mac,
      status: .updateAvailable,
      latestVersion: "3.7.2",
      releaseNotes: "提升了大型文稿的编辑性能，并修复了若干稳定性问题。",
      releaseDate: .now.addingTimeInterval(-86_400),
      canAutomaticallyUpdate: false
    ),
    AppRecord(
      name: "Visual Studio Code",
      bundleIdentifier: "com.microsoft.VSCode",
      applicationURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
      currentVersion: "1.103.1",
      updateConfiguration: UpdateConfiguration(
        mechanism: .homebrew, homepageURL: URL(string: "https://code.visualstudio.com/"),
        identifier: "visual-studio-code"),
      status: .updateAvailable,
      latestVersion: "1.104.0",
      canAutomaticallyUpdate: true
    ),
    AppRecord(
      name: "CotEditor",
      bundleIdentifier: "com.coteditor.CotEditor",
      applicationURL: URL(fileURLWithPath: "/Applications/CotEditor.app"),
      currentVersion: "5.1.7",
      updateConfiguration: UpdateConfiguration(mechanism: .sparkle),
      status: .upToDate,
      latestVersion: "5.1.7",
      releaseNotes: "当前已安装最新版本。"
    ),
    AppRecord(
      name: "Example",
      bundleIdentifier: "com.example.mac",
      applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
      currentVersion: "2.4",
      updateConfiguration: UpdateConfiguration(mechanism: .selfManaged),
      status: .selfManaged
    ),
    AppRecord(
      name: "ChatWise",
      bundleIdentifier: "app.chatwise",
      applicationURL: URL(fileURLWithPath: "/Applications/ChatWise.app"),
      currentVersion: "26.8.0",
      updateConfiguration: UpdateConfiguration(
        mechanism: .electronBuilder,
        feedURL: URL(string: "https://releases.chatwise.app/latest-mac.yml")),
      status: .updateAvailable,
      latestVersion: "26.8.1",
      canAutomaticallyUpdate: true
    ),
    AppRecord(
      name: "Grok",
      bundleIdentifier: "com.example.grok",
      applicationURL: URL(fileURLWithPath: "/Applications/Grok.app"),
      currentVersion: "0.2.20",
      updateConfiguration: UpdateConfiguration(
        mechanism: .tauri,
        feedURL: URL(
          string:
            "https://github.com/RongleCat/grok-app/releases/download/grok-desktop-latest/latest.json"
        )),
      status: .updateAvailable,
      latestVersion: "0.2.24",
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
