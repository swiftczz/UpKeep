import Foundation

struct SparkleUpdateProvider: Sendable {
  func check(_ application: AppRecord) async -> AppRecord {
    var application = application

    guard let feedURL = application.sourceURL,
      feedURL.scheme?.lowercased() == "https"
    else {
      application.status = .selfManaged
      return application
    }

    do {
      var request = URLRequest(url: feedURL)
      request.timeoutInterval = 15
      let (data, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse,
        (200..<300).contains(httpResponse.statusCode)
      else {
        application.status = .unavailable("Sparkle 更新源暂时无法访问。")
        return application
      }

      let parser = SparkleAppcastParser(data: data)
      let candidates = try parser.parse()
      guard let candidate = Self.bestCandidate(from: candidates) else {
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

      if application.releaseNotes == nil,
        let releaseNotesURL = candidate.releaseNotesURL,
        releaseNotesURL.scheme?.lowercased() == "https"
      {
        application.releaseNotes = await Self.fetchReleaseNotes(from: releaseNotesURL)
      }

      let updateIsAvailable: Bool

      if let candidateBuild = candidate.buildVersion,
        let installedBuild = application.buildVersion
      {
        updateIsAvailable = VersionComparator.isNewer(candidateBuild, than: installedBuild)
      } else {
        updateIsAvailable = VersionComparator.isNewer(
          latestVersion,
          than: application.currentVersion
        )
      }

      application.status =
        updateIsAvailable
        ? .updateAvailable
        : .upToDate
    } catch is CancellationError {
      return application
    } catch {
      application.status = .unavailable("Sparkle 更新信息解析失败。")
    }

    return application
  }

  private static func bestCandidate(from candidates: [SparkleCandidate]) -> SparkleCandidate? {
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
        let left = lhs.shortVersion ?? lhs.buildVersion ?? "0"
        let right = rhs.shortVersion ?? rhs.buildVersion ?? "0"
        return VersionComparator.isNewer(right, than: left)
      }
  }

  private static func parsePublicationDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")

    for format in [
      "EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssXXXXX",
    ] {
      formatter.dateFormat = format
      if let date = formatter.date(from: value) {
        return date
      }
    }

    return nil
  }

  private static func fetchReleaseNotes(from url: URL) async -> String? {
    do {
      var request = URLRequest(url: url)
      request.timeoutInterval = 10
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse,
        (200..<300).contains(httpResponse.statusCode),
        data.count <= 2_000_000,
        let html = String(data: data, encoding: .utf8)
      else {
        return nil
      }

      return plainText(fromHTML: html)
    } catch {
      return nil
    }
  }

  private static func plainText(fromHTML html: String) -> String? {
    let lineBreakPatterns = [
      "(?i)<br\\s*/?>",
      "(?i)</p\\s*>",
      "(?i)</li\\s*>",
    ]

    var value = html
    for pattern in lineBreakPatterns {
      value = value.replacingOccurrences(
        of: pattern,
        with: "\n",
        options: .regularExpression
      )
    }

    value = value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    value =
      value
      .replacingOccurrences(of: "&nbsp;", with: " ")
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")

    let lines =
      value
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let result = lines.joined(separator: "\n")
    return result.isEmpty ? nil : result
  }
}

struct SparkleCandidate: Hashable, Sendable {
  var title: String?
  var shortVersion: String?
  var buildVersion: String?
  var summary: String?
  var publicationDate: String?
  var releaseNotesURL: URL?
  var minimumSystemVersion: String?
  var operatingSystem: String?
  var architecture: String?

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
  private var parserError: Error?

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

    guard currentCandidate != nil else { return }

    if key == "enclosure" {
      guard var candidate = currentCandidate else { return }
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
      currentCandidate = candidate
      return
    }

    let capturable = [
      "title",
      "description",
      "pubdate",
      "releasenoteslink",
      "shortversionstring",
      "version",
      "minimumsystemversion",
    ]

    if capturable.contains(key) {
      captureElement = key
      captureBuffer = ""
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard captureElement != nil else { return }
    captureBuffer += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let key = Self.normalized(elementName)

    if key == "item" {
      if let currentCandidate {
        candidates.append(currentCandidate)
      }
      currentCandidate = nil
      captureElement = nil
      captureBuffer = ""
      return
    }

    guard key == captureElement else { return }
    let value = captureBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

    switch key {
    case "title": currentCandidate?.title = value
    case "description": currentCandidate?.summary = value
    case "pubdate": currentCandidate?.publicationDate = value
    case "releasenoteslink": currentCandidate?.releaseNotesURL = URL(string: value)
    case "shortversionstring": currentCandidate?.shortVersion = value
    case "version": currentCandidate?.buildVersion = value
    case "minimumsystemversion": currentCandidate?.minimumSystemVersion = value
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
