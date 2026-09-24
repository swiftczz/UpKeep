import Foundation

enum SparkleUpdateProviderError: LocalizedError {
  case insecureFeed
  case noAvailableUpdate
  case noInstallablePackage

  var errorDescription: String? {
    switch self {
    case .insecureFeed:
      return "此应用没有提供安全的 Sparkle 更新源。"
    case .noAvailableUpdate:
      return "Sparkle 更新源中没有找到更新版本。"
    case .noInstallablePackage:
      return "Sparkle 更新源没有提供 Upkeep 可安装的更新包。"
    }
  }
}

struct SparkleUpdateProvider: Sendable {
  var fetchData: @Sendable (URL) async throws -> Data? = {
    try await UpdateHTTP.successfulData(from: $0)
  }

  func check(_ application: AppRecord, fallbackNotes: AppRecord? = nil) async -> AppRecord {
    var application = application

    guard let feedURL = application.sourceURL,
      SecureUpdateURL.https(feedURL) != nil
    else {
      application.status = .selfManaged
      return application
    }

    do {
      guard let data = try await fetchData(feedURL) else {
        application.status = .unavailable("Sparkle 更新源暂时无法访问。")
        return application
      }
      guard !Self.looksLikeHTML(data) else {
        application.status = .selfManaged
        application.canAutomaticallyUpdate = false
        application.latestVersion = nil
        application.latestBuildVersion = nil
        application.updatePageURL = nil
        return application
      }

      let parser = SparkleAppcastParser(data: data)
      let candidates = try parser.parse()
      if application.homepageURL == nil {
        application.homepageURL = parser.homepageURL
      }
      guard !candidates.isEmpty else {
        application.status = .unavailable("更新源没有提供版本。")
        return application
      }
      let releasedCandidates = candidates.filter { !$0.isPrerelease }
      guard !releasedCandidates.isEmpty else {
        application.status = .upToDate
        application.canAutomaticallyUpdate = false
        return application
      }
      guard let candidate = Self.bestCandidate(from: releasedCandidates) else {
        application.status = .unavailable("更新源中没有兼容此 Mac 的版本。")
        return application
      }

      guard let latestVersion = candidate.displayVersion else {
        application.status = .unavailable("更新源没有提供版本号。")
        return application
      }

      application.latestVersion = latestVersion
      application.latestBuildVersion = candidate.buildVersion
      application.releaseDate = candidate.publicationDate.flatMap(Self.parsePublicationDate)
      application.releaseNotesURL = candidate.releaseNotesURL
      application.releaseNotes = candidate.summary.flatMap(Self.plainText(fromHTML:))
      application.packageByteCount = candidate.packageByteCount
      application.updatePageURL = candidate.manualUpdateURL(relativeTo: feedURL)

      if application.releaseNotes == nil, let fallbackNotes,
        fallbackNotes.latestVersion?.split(separator: ",").first.map(String.init) == latestVersion,
        let notes = fallbackNotes.releaseNotes?.nonBlankValue {
        application.releaseNotes = notes
        application.releaseNotesURL = fallbackNotes.releaseNotesURL
      }

      var visitedNotesURLs = Set<URL>()
      for link in [candidate.releaseNotesURL, candidate.updatePageURL].compactMap({ $0 }) {
        guard application.releaseNotes == nil else { break }
        guard let url = URL(string: link.relativeString, relativeTo: feedURL)?.absoluteURL,
          SecureUpdateURL.https(url) != nil, visitedNotesURLs.insert(url).inserted
        else { continue }
        // Retain a usable source link even when the page is unavailable or empty.
        application.releaseNotesURL = url
        application.releaseNotes = await fetchReleaseNotes(from: url)
        if Task.isCancelled { return application }
      }

      let updateIsAvailable: Bool

      updateIsAvailable = Self.isUpdateAvailable(candidate, for: application)

      application.status =
        updateIsAvailable
        ? .updateAvailable
        : .upToDate
      application.canAutomaticallyUpdate =
        updateIsAvailable && candidate.supportedPackageURL(relativeTo: feedURL) != nil
    } catch is CancellationError {
      return application
    } catch {
      application.status = .unavailable("Sparkle 更新信息解析失败。")
    }

    return application
  }

  private static func looksLikeHTML(_ data: Data) -> Bool {
    guard
      let prefix = String(data: data.prefix(256), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    else {
      return false
    }
    return prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html")
  }

  func upgrade(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    guard let feedURL = application.sourceURL, SecureUpdateURL.https(feedURL) != nil else {
      throw SparkleUpdateProviderError.insecureFeed
    }

    progress(.indeterminate("正在检查更新…"))
    guard
      let data = try await UpdateHTTP.successfulData(
        from: feedURL,
        attempts: NetworkRetryPolicy.downloadAttempts
      )
    else {
      throw SparkleUpdateProviderError.noAvailableUpdate
    }

    let candidates = try SparkleAppcastParser(data: data).parse()
    guard let candidate = Self.bestCandidate(from: candidates.filter { !$0.isPrerelease }),
      Self.isUpdateAvailable(candidate, for: application)
    else {
      throw SparkleUpdateProviderError.noAvailableUpdate
    }
    guard let packageURL = candidate.supportedPackageURL(relativeTo: feedURL) else {
      throw SparkleUpdateProviderError.noInstallablePackage
    }

    try await ApplicationPackageInstaller.install(
      from: packageURL,
      replacing: application,
      expectedSHA512: nil,
      expectedEd25519Signature: candidate.edSignature,
      ed25519PublicKey: ApplicationCodeSigning.sparklePublicEDKey(
        at: application.applicationURL
      ),
      requiresTeamIdentifier: true,
      progress: progress
    )
  }

  static func bestCandidate(from candidates: [SparkleCandidate]) -> SparkleCandidate? {
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
    let systemVersion =
      "\(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)"

    #if arch(arm64)
      let architecture = "arm64"
    #elseif arch(x86_64)
      let architecture = "x86_64"
    #else
      let architecture = "universal"
    #endif

    return
      candidates
      .filter { candidate in
        guard !candidate.isPrerelease else {
          return false
        }
        let supportsOS =
          candidate.operatingSystem == nil
          || candidate.operatingSystem?.lowercased().contains("mac") == true
        let supportsArchitecture =
          candidate.architecture == nil
          || candidate.architecture == architecture
          || candidate.architecture == "universal"
        let supportsSystemVersion =
          candidate.minimumSystemVersion == nil
          || !VersionComparator.isNewer(candidate.minimumSystemVersion!, than: systemVersion)
        return supportsOS && supportsArchitecture && supportsSystemVersion
      }
      .max { lhs, rhs in
        Self.isOlder(lhs, than: rhs)
      }
  }

  private static func isOlder(_ lhs: SparkleCandidate, than rhs: SparkleCandidate) -> Bool {
    if let leftBuild = lhs.buildVersion,
      let rightBuild = rhs.buildVersion,
      leftBuild != rightBuild
    {
      return VersionComparator.isNewer(rightBuild, than: leftBuild)
    }

    let left = lhs.shortVersion ?? lhs.buildVersion ?? "0"
    let right = rhs.shortVersion ?? rhs.buildVersion ?? "0"
    return VersionComparator.isNewer(right, than: left)
  }

  private static func isUpdateAvailable(
    _ candidate: SparkleCandidate,
    for application: AppRecord
  ) -> Bool {
    if let candidateBuild = candidate.buildVersion,
      let installedBuild = application.buildVersion
    {
      return VersionComparator.isNewer(candidateBuild, than: installedBuild)
    }

    guard let latestVersion = candidate.displayVersion else {
      return false
    }
    return VersionComparator.isNewer(latestVersion, than: application.currentVersion)
  }

  static func parsePublicationDate(_ value: String) -> Date? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let timestamp = Int64(trimmed) {
      if timestamp >= 1_000_000_000_000 {
        return Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
      }
      if timestamp >= 1_000_000_000 {
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
      }
    }

    let rfc822Value = rfc822DateString(from: trimmed)
    let namedZoneValue = replaceNamedTimeZone(in: rfc822Value)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)

    for format in [
      "EEE, dd MMM yyyy HH:mm:ss Z",
      "EEE, d MMM yyyy HH:mm:ss Z",
      "EEE, dd MMM yyyy HH:mm:ss z",
      "EEE, d MMM yyyy HH:mm:ss z",
      "EEE MMM d HH:mm:ss Z yyyy",
      "EEE MMM dd HH:mm:ss Z yyyy",
      "yyyy-MM-dd'T'HH:mm:ssXXXXX",
      "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
      "yyyy-MM-dd'T'HH:mm:ssZ",
      "yyyy-MM-dd",
    ] {
      formatter.dateFormat = format
      if let date = formatter.date(from: namedZoneValue)
        ?? formatter.date(from: rfc822Value)
        ?? formatter.date(from: trimmed)
      {
        return date
      }
    }

    return ISO8601Parsing.date(from: trimmed)
  }

  private static let namedTimeZoneOffsets: [String: String] = [
    "UT": "+0000",
    "UTC": "+0000",
    "GMT": "+0000",
    "WET": "+0000",
    "WEST": "+0100",
    "CET": "+0100",
    "CEST": "+0200",
    "EET": "+0200",
    "EEST": "+0300",
    "BST": "+0100",
    "EST": "-0500",
    "EDT": "-0400",
    "CST": "-0600",
    "CDT": "-0500",
    "MST": "-0700",
    "MDT": "-0600",
    "PST": "-0800",
    "PDT": "-0700",
  ]

  private static func replaceNamedTimeZone(in value: String) -> String {
    guard
      let expression = try? NSRegularExpression(pattern: #"\b([A-Z]{2,5})\b"#),
      let match = expression.matches(
        in: value,
        range: NSRange(value.startIndex..., in: value)
      ).last,
      let tokenRange = Range(match.range(at: 1), in: value)
    else {
      return value
    }

    let token = String(value[tokenRange])
    guard let offset = namedTimeZoneOffsets[token] else {
      return value
    }
    return value.replacingCharacters(in: tokenRange, with: offset)
  }

  private static func rfc822DateString(from value: String) -> String {
    let pattern = #"GMT([+-])(\d{2}):?(\d{2})\s*$"#
    if let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
      let sign = Range(match.range(at: 1), in: value).map({ String(value[$0]) }),
      let hours = Range(match.range(at: 2), in: value).map({ String(value[$0]) }),
      let minutes = Range(match.range(at: 3), in: value).map({ String(value[$0]) }),
      let overall = Range(match.range, in: value)
    {
      var result = value
      result.replaceSubrange(overall, with: "\(sign)\(hours)\(minutes)")
      return result
    }

    for suffix in [" GMT", " UTC", " UT"] where value.hasSuffix(suffix) {
      return String(value.dropLast(suffix.count)) + " +0000"
    }

    return value
  }

  private func fetchReleaseNotes(from url: URL) async -> String? {
    do {
      if let apiURL = TauriReleaseNotes.githubReleaseAPIURL(from: url) {
        if let data = try? await fetchData(apiURL), data.count <= 2_000_000,
          let notes = TauriReleaseNotes.parseGitHubRelease(data) {
          return notes
        }
        guard !Task.isCancelled else { return nil }
        guard let data = try await fetchData(url), data.count <= 2_000_000,
          let html = String(data: data, encoding: .utf8) else { return nil }
        return ReleaseNotesHTML.githubReleaseText(html)
      }
      guard
        let data = try await fetchData(url),
        data.count <= 2_000_000,
        let html = String(data: data, encoding: .utf8)
      else {
        return nil
      }

      return ReleaseNotesHTML.text(html)
    } catch {
      return nil
    }
  }

  private static func plainText(fromHTML html: String) -> String? {
    ReleaseNotesHTML.text(html)
  }
}

struct SparkleCandidate: Hashable, Sendable {
  var title: String?
  var shortVersion: String?
  var buildVersion: String?
  var summary: String?
  var publicationDate: String?
  var releaseNotesURL: URL?
  var updatePageURL: URL?
  var downloadURL: URL?
  var packageByteCount: Int64?
  var minimumSystemVersion: String?
  var operatingSystem: String?
  var architecture: String?
  var channel: String?
  var edSignature: String?

  var displayVersion: String? {
    if let title {
      let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
      if let range = trimmedTitle.range(
        of: #"(?i)^version\s+"#,
        options: .regularExpression
      ) {
        let value = String(trimmedTitle[range.upperBound...])
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
          return value
        }
      }
    }

    return shortVersion ?? buildVersion
  }

  var isPrerelease: Bool {
    channel != nil
      || VersionComparator.isPrerelease(shortVersion ?? "")
      || VersionComparator.isPrerelease(displayVersion ?? "")
  }

  func hasSecureDownload(relativeTo feedURL: URL) -> Bool {
    resolvedDownloadURL(relativeTo: feedURL) != nil
  }

  func manualUpdateURL(relativeTo feedURL: URL) -> URL? {
    // Sparkle items without an enclosure use their item link for a web handoff.
    guard downloadURL == nil, let updatePageURL,
      let resolvedURL = URL(string: updatePageURL.relativeString, relativeTo: feedURL)?.absoluteURL
    else { return nil }
    return SecureUpdateURL.https(resolvedURL)
  }

  func supportedPackageURL(relativeTo feedURL: URL) -> URL? {
    guard let url = resolvedDownloadURL(relativeTo: feedURL),
      ApplicationPackageInstaller.packageKindScore(of: url.lastPathComponent) > 0
    else {
      return nil
    }
    return url
  }

  private func resolvedDownloadURL(relativeTo feedURL: URL) -> URL? {
    guard let downloadURL else { return nil }
    guard
      let resolvedURL = URL(
        string: downloadURL.relativeString,
        relativeTo: feedURL
      )?.absoluteURL
    else {
      return nil
    }
    return SecureUpdateURL.https(resolvedURL)
  }
}

enum SparkleParserError: Error {
  case invalidFeed
}

final class SparkleAppcastParser: NSObject, XMLParserDelegate {
  private let data: Data
  private var candidates: [SparkleCandidate] = []
  private var currentCandidate: SparkleCandidate?
  private var captureElement: String?
  private var captureBuffer = ""
  private var feedCaptureElement: String?
  private var feedCaptureBuffer = ""
  private var parserError: Error?
  private var deltaContainerDepth = 0
  private var channelDepth = 0
  private(set) var homepageURL: URL?

  init(data: Data) {
    self.data = data
  }

  func parse() throws -> [SparkleCandidate] {
    let parser = XMLParser(data: data)
    parser.delegate = self
    guard parser.parse(), parserError == nil else {
      throw parserError ?? SparkleParserError.invalidFeed
    }
    return candidates
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    let key = Self.normalized(elementName)

    if key == "item" {
      currentCandidate = SparkleCandidate()
      return
    }

    if currentCandidate == nil, key == "channel" {
      channelDepth += 1
      return
    }

    guard currentCandidate != nil else {
      if channelDepth > 0, key == "link" {
        feedCaptureElement = key
        feedCaptureBuffer = ""
      }
      return
    }

    if key == "deltas" {
      deltaContainerDepth += 1
      return
    }

    if key == "enclosure" {
      guard deltaContainerDepth == 0 else { return }
      guard var candidate = currentCandidate else { return }
      candidate.downloadURL =
        Self.attribute(named: "url", in: attributeDict)
        .flatMap(URL.init(string:)) ?? candidate.downloadURL
      candidate.shortVersion =
        Self.attribute(
          named: "shortversionstring",
          in: attributeDict
        ) ?? candidate.shortVersion
      candidate.buildVersion =
        Self.attribute(
          named: "version",
          in: attributeDict
        ) ?? candidate.buildVersion
      candidate.minimumSystemVersion =
        Self.attribute(
          named: "minimumsystemversion",
          in: attributeDict
        ) ?? candidate.minimumSystemVersion
      candidate.operatingSystem =
        Self.attribute(named: "os", in: attributeDict)
        ?? candidate.operatingSystem
      candidate.architecture =
        Self.attribute(named: "arch", in: attributeDict)
        ?? candidate.architecture
      candidate.edSignature =
        Self.attribute(named: "edsignature", in: attributeDict)
        ?? candidate.edSignature
      if let length = JSONByteCount.parse(Self.attribute(named: "length", in: attributeDict)) {
        candidate.packageByteCount = length
      }
      currentCandidate = candidate
      return
    }

    let capturable = [
      "title",
      "description",
      "pubdate",
      "releasenoteslink",
      "link",
      "shortversionstring",
      "version",
      "minimumsystemversion",
      "channel",
    ]

    if capturable.contains(key) {
      captureElement = key
      captureBuffer = ""
    }
  }

  func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
    guard let text = String(data: CDATABlock, encoding: .utf8) else { return }
    self.parser(parser, foundCharacters: text)
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if feedCaptureElement != nil {
      feedCaptureBuffer += string
    }
    if captureElement != nil {
      captureBuffer += string
    }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let key = Self.normalized(elementName)

    if key == feedCaptureElement {
      let value = feedCaptureBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
      if homepageURL == nil {
        homepageURL = SecureUpdateURL.https(string: value)
      }
      feedCaptureElement = nil
      feedCaptureBuffer = ""
      return
    }

    if key == "item" {
      if let currentCandidate {
        candidates.append(currentCandidate)
      }
      currentCandidate = nil
      captureElement = nil
      captureBuffer = ""
      return
    }

    if currentCandidate == nil, key == "channel" {
      channelDepth = max(0, channelDepth - 1)
      return
    }

    if key == "deltas" {
      deltaContainerDepth = max(0, deltaContainerDepth - 1)
      return
    }

    guard key == captureElement else { return }
    let value = captureBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

    switch key {
    case "title": currentCandidate?.title = value
    case "description": currentCandidate?.summary = value
    case "pubdate": currentCandidate?.publicationDate = value
    case "releasenoteslink": currentCandidate?.releaseNotesURL = URL(string: value)
    case "link": currentCandidate?.updatePageURL = URL(string: value)
    case "shortversionstring": currentCandidate?.shortVersion = value
    case "version": currentCandidate?.buildVersion = value
    case "minimumsystemversion": currentCandidate?.minimumSystemVersion = value
    case "channel": currentCandidate?.channel = value.nonBlankValue
    default: break
    }

    captureElement = nil
    captureBuffer = ""
  }

  func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
    parserError = parseError
  }

  private static func normalized(_ value: String) -> String {
    value.split(separator: ":").last.map(String.init)?.lowercased() ?? value.lowercased()
  }

  private static func attribute(named name: String, in attributes: [String: String]) -> String? {
    attributes.first { key, _ in
      normalized(key) == name
    }?.value
  }
}
