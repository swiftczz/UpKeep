import Foundation

struct ElectronBuilderMetadata: Equatable, Sendable {
  let identifier: String
  let feedURL: URL
  let homepageURL: URL?
}

enum ElectronBuilderDetector {
  static func detect(in bundleURL: URL) -> ElectronBuilderMetadata? {
    let resourcesURL = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
    let candidateURLs = [
      resourcesURL.appendingPathComponent("app-update.yml"),
      resourcesURL.appendingPathComponent("app-update.yaml"),
    ]

    for configurationURL in candidateURLs {
      guard
        let configuration = try? String(contentsOf: configurationURL, encoding: .utf8),
        let metadata = metadata(from: configuration)
      else {
        continue
      }
      return metadata
    }

    return nil
  }

  static func metadata(from configuration: String) -> ElectronBuilderMetadata? {
    guard let values = ElectronBuilderYAML.flatValues(in: configuration) else {
      return nil
    }
    if isTruthy(values["private"]) {
      return nil
    }

    let provider = values["provider"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch provider {
    case "github":
      return githubMetadata(from: values)
    case "generic":
      return genericMetadata(from: values)
    default:
      return nil
    }
  }

  private static func githubMetadata(from values: [String: String]) -> ElectronBuilderMetadata? {
    guard
      let owner = values["owner"]?.nonBlankYAMLValue,
      let repository = values["repo"]?.nonBlankYAMLValue
    else {
      return nil
    }

    let fileName = macYMLFileName(channel: values["channel"]?.nonBlankYAMLValue)
    guard
      let feedURL = SecureUpdateURL.https(
        string: "https://github.com/\(owner)/\(repository)/releases/latest/download/\(fileName)"
      )
    else {
      return nil
    }

    return ElectronBuilderMetadata(
      identifier: "\(owner)/\(repository)",
      feedURL: feedURL,
      homepageURL: URL(string: "https://github.com/\(owner)/\(repository)")
    )
  }

  private static func genericMetadata(from values: [String: String]) -> ElectronBuilderMetadata? {
    guard
      let rawURL = values["url"]?.nonBlankYAMLValue,
      let baseURL = SecureUpdateURL.https(string: rawURL)
    else {
      return nil
    }

    let feedURL = latestMacFeedURL(from: baseURL, channel: values["channel"]?.nonBlankYAMLValue)
    guard SecureUpdateURL.https(feedURL) != nil else {
      return nil
    }

    return ElectronBuilderMetadata(
      identifier: baseURL.absoluteString,
      feedURL: feedURL,
      homepageURL: baseURL
    )
  }

  private static func latestMacFeedURL(from baseURL: URL, channel: String?) -> URL {
    let lastComponent = baseURL.lastPathComponent.lowercased()
    if lastComponent.hasSuffix(".yml") || lastComponent.hasSuffix(".yaml") {
      return baseURL
    }

    let fileName = macYMLFileName(channel: channel)
    var directory = baseURL.absoluteString
    if !directory.hasSuffix("/") {
      directory.append("/")
    }
    return URL(string: directory + fileName) ?? baseURL.appendingPathComponent(fileName)
  }

  private static func macYMLFileName(channel: String?) -> String {
    guard let channel, channel.lowercased() != "latest" else {
      return "latest-mac.yml"
    }
    return "\(channel)-mac.yml"
  }

  private static func isTruthy(_ value: String?) -> Bool {
    guard let value else { return false }
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "true", "yes", "1":
      return true
    default:
      return false
    }
  }
}

enum ElectronBuilderYAML {
  static func flatValues(in configuration: String) -> [String: String]? {
    let values = configuration.split(whereSeparator: \.isNewline).reduce(
      into: [String: String]()
    ) { result, line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("-") else {
        return
      }
      let components = trimmed.split(separator: ":", maxSplits: 1)
      guard components.count == 2 else {
        return
      }
      let key = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
      let value = String(components[1]).yamlScalar
      if !key.isEmpty {
        result[key] = value
      }
    }
    return values.isEmpty ? nil : values
  }

  static func parseManifest(_ text: String) -> ElectronBuilderManifest? {
    var version: String?
    var path: String?
    var sha512: String?
    var releaseDate: String?
    var releaseNotes: String?
    var files: [ElectronBuilderManifest.File] = []

    var currentFile: ElectronBuilderManifest.File?
    var multilineKey: String?
    var multilineLines: [String] = []
    var multilineIndent: Int?

    func commitMultiline() {
      guard let multilineKey else { return }
      let content = unindentYAMLBlock(multilineLines)
      switch multilineKey {
      case "releaseNotes":
        releaseNotes = content
      default:
        break
      }
      selfCommitReset()
    }

    func selfCommitReset() {
      multilineKey = nil
      multilineLines = []
      multilineIndent = nil
    }

    func commitFile() {
      if let currentFile, !currentFile.url.isEmpty {
        files.append(currentFile)
      }
      currentFile = nil
    }

    for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      let line = String(rawLine)
      let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

      if multilineKey != nil, let multilineIndent {
        if trimmed.isEmpty {
          multilineLines.append("")
          continue
        }
        if indent > multilineIndent {
          multilineLines.append(String(line.dropFirst(multilineIndent)))
          continue
        }
        commitMultiline()
      }

      if trimmed.isEmpty || trimmed.hasPrefix("#") {
        continue
      }

      if trimmed.hasPrefix("- ") {
        commitFile()
        currentFile = ElectronBuilderManifest.File(url: "", sha512: nil)
        let remainder = String(trimmed.dropFirst(2))
        applyFileField(remainder, to: &currentFile)
        continue
      }

      let components = trimmed.split(separator: ":", maxSplits: 1)
      guard components.count >= 1 else {
        continue
      }
      let key = String(components[0])
      let rawValue = components.count == 2 ? String(components[1]) : ""
      let value = rawValue.yamlScalar

      if currentFile != nil && indent >= 2 && ["url", "sha512"].contains(key) {
        applyFileField(trimmed, to: &currentFile)
        continue
      }

      commitFile()

      if rawValue.trimmingCharacters(in: .whitespaces).hasPrefix("|")
        || rawValue.trimmingCharacters(in: .whitespaces).hasPrefix(">")
      {
        multilineKey = key
        multilineIndent = indent
        continue
      }

      switch key {
      case "version":
        version = value.nonBlankYAMLValue
      case "path":
        path = value.nonBlankYAMLValue
      case "sha512":
        sha512 = value.nonBlankYAMLValue
      case "releaseDate":
        releaseDate = value.nonBlankYAMLValue
      case "releaseNotes":
        releaseNotes = value.nonBlankYAMLValue
      default:
        break
      }
    }

    commitMultiline()
    commitFile()

    guard let version, !version.isEmpty else {
      return nil
    }

    return ElectronBuilderManifest(
      version: version,
      files: files,
      path: path,
      sha512: sha512,
      releaseDate: releaseDate.flatMap(parseManifestDate),
      releaseNotes: releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  private static func applyFileField(
    _ text: String,
    to file: inout ElectronBuilderManifest.File?
  ) {
    let components = text.split(separator: ":", maxSplits: 1)
    guard components.count == 2 else { return }
    let key = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
    let value = String(components[1]).yamlScalar
    switch key {
    case "url":
      file?.url = value
    case "sha512":
      file?.sha512 = value.nonBlankYAMLValue
    default:
      break
    }
  }

  private static func unindentYAMLBlock(_ lines: [String]) -> String {
    let indent =
      lines
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }
      .min() ?? 0

    return
      lines
      .map { line in
        if line.count >= indent {
          return String(line.dropFirst(indent))
        }
        return line.trimmingCharacters(in: .whitespaces)
      }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func parseManifestDate(_ value: String) -> Date? {
    ISO8601Parsing.date(from: value)
  }
}

struct ElectronBuilderManifest: Equatable, Sendable {
  struct File: Equatable, Sendable {
    var url: String
    var sha512: String?
  }

  struct Package: Equatable, Sendable {
    let url: URL
    let sha512: String?
  }

  var version: String
  var files: [File]
  var path: String?
  var sha512: String?
  var releaseDate: Date?
  var releaseNotes: String?

  func selectedPackage(
    relativeTo feedURL: URL,
    architecture: MacCPUArchitecture = .current
  ) -> Package? {
    var candidates: [(fileName: String, url: String, sha512: String?)] = files.map {
      ($0.url, $0.url, $0.sha512)
    }
    if let path, !path.isEmpty {
      candidates.append((path, path, sha512))
    }

    let ranked = candidates.compactMap { candidate -> (Int, Package)? in
      let fileName = URL(string: candidate.url)?.lastPathComponent ?? candidate.url
      let kindScore = ApplicationPackageInstaller.packageKindScore(of: fileName)
      guard kindScore > 0 else {
        return nil
      }
      let score =
        ApplicationPackageInstaller.architectureScore(of: fileName, architecture: architecture)
        * 10 + kindScore
      guard let url = resolvedURL(candidate.url, relativeTo: feedURL) else {
        return nil
      }
      return (score, Package(url: url, sha512: candidate.sha512))
    }

    return ranked.max(by: { $0.0 < $1.0 })?.1
  }

  private func resolvedURL(_ value: String, relativeTo feedURL: URL) -> URL? {
    if let absolute = SecureUpdateURL.https(string: value) {
      return absolute
    }

    guard var directory = URL(string: feedURL.absoluteString) else {
      return nil
    }
    if !feedURL.lastPathComponent.isEmpty {
      directory.deleteLastPathComponent()
    }
    var base = directory.absoluteString
    if !base.hasSuffix("/") {
      base.append("/")
    }
    return SecureUpdateURL.https(string: base + value)
  }
}

extension String {
  fileprivate var yamlScalar: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
  }

  var nonBlankYAMLValue: String? {
    let value = yamlScalar
    return value.isEmpty ? nil : value
  }
}
