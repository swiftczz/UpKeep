import Foundation

enum CustomAPIUpdateDetector {
  private static let latestNeedle = Data("latest.json".utf8)
  private static let apiLatestNeedle = Data("/api/latest".utf8)
  private static let httpsNeedle = Data("https://".utf8)
  private static let urlAllowed = CharacterSet(
    charactersIn:
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%"
  )
  private static let skippedPathComponents: Set<String> = [
    "alpha", "beta", "canary", "dev", "nightly", "preview", "rc",
  ]

  static func detect(bundleURL: URL) -> URL? {
    ExecutableUpdaterDetector.detect(bundleURL: bundleURL).customAPIUpdateEndpoint
  }

  static func endpoint(inFile fileURL: URL) -> URL? {
    ExecutableUpdaterDetector.detect(fileURL: fileURL).customAPIUpdateEndpoint
  }

  static func stableChannelURL(from url: URL) -> URL? {
    var pathComponents = url.path.split(separator: "/").map(String.init)
    guard pathComponents.last?.lowercased() == "latest.json" else {
      return nil
    }

    let directories = pathComponents.dropLast().map { $0.lowercased() }
    if directories.contains("stable")
      || directories.contains(where: { skippedPathComponents.contains($0) })
    {
      return nil
    }

    pathComponents.insert("stable", at: pathComponents.count - 1)
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.percentEncodedPath =
      "/" + pathComponents.map(encodePathComponent).joined(separator: "/")
    return components.url.flatMap(SecureUpdateURL.https)
  }

  static func firstEndpoint(in window: Data) -> URL? {
    var searchStart = window.startIndex
    while let range = window[searchStart...].range(of: apiLatestNeedle) {
      if let url = url(endingAt: range, in: window, allowReconstruction: false) { return url }
      searchStart = range.upperBound
    }
    searchStart = window.startIndex
    while let range = window[searchStart...].range(of: latestNeedle) {
      if let url = url(endingAt: range, in: window) {
        return url
      }
      searchStart = range.upperBound
    }
    return nil
  }

  private static func url(
    endingAt needleRange: Range<Data.Index>,
    in window: Data,
    allowReconstruction: Bool = true
  ) -> URL? {
    let maximumURLLength = 400
    var search = needleRange.lowerBound
    var steps = 0

    while search > window.startIndex && steps < maximumURLLength {
      search = window.index(before: search)
      steps += 1
      guard window.distance(from: search, to: needleRange.lowerBound) >= httpsNeedle.count else {
        continue
      }
      let httpsEnd = window.index(search, offsetBy: httpsNeedle.count)
      guard window[search..<httpsEnd].elementsEqual(httpsNeedle) else {
        continue
      }

      let slice = Data(window[search..<needleRange.upperBound])
      if let rawValue = String(data: slice, encoding: .utf8),
        let url = validatedEndpoint(rawValue)
      {
        return url
      }
      if allowReconstruction, let url = reconstructedStableEndpoint(from: slice) {
        return url
      }
    }

    return nil
  }

  private static func reconstructedStableEndpoint(from slice: Data) -> URL? {
    var ascii = Data()
    for byte in slice {
      guard (32..<127).contains(byte), urlAllowed.contains(UnicodeScalar(byte)) else {
        break
      }
      ascii.append(byte)
    }

    guard let prefix = String(data: ascii, encoding: .ascii), prefix.hasPrefix("https://") else {
      return nil
    }
    let joined =
      prefix.hasSuffix("/")
      ? prefix + "stable/latest.json"
      : prefix + "/stable/latest.json"
    return validatedEndpoint(joined)
  }

  private static func validatedEndpoint(_ rawValue: String) -> URL? {
    if rawValue.contains("%s") || rawValue.contains("%d") || rawValue.contains("{{") {
      return nil
    }
    guard rawValue.unicodeScalars.allSatisfy({ urlAllowed.contains($0) }) else {
      return nil
    }
    guard let url = SecureUpdateURL.https(string: rawValue),
      url.lastPathComponent.lowercased() == "latest.json" || url.path == "/api/latest",
      url.user == nil, url.password == nil
    else {
      return nil
    }

    let directories = url.path.split(separator: "/").dropLast().map { $0.lowercased() }
    if directories.contains(where: { skippedPathComponents.contains($0) }) {
      return nil
    }
    return url
  }

  // Rust/Go can store a base URL separately from the update API path.
  // Reconstruct only with both API markers and an origin belonging to the app.
  static func apiOrigins(in data: Data) -> [URL] {
    guard data.range(of: httpsNeedle) != nil else { return [] }
    let text = String(decoding: data, as: UTF8.self)
    guard
      let expression = try? NSRegularExpression(
        pattern: #"https://[A-Za-z0-9.-]+?(?=https://|[\x00-\x20\"'<>]|$)"#)
    else { return [] }
    return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
      match in
      guard let range = Range(match.range, in: text),
        let url = SecureUpdateURL.https(string: String(text[range])),
        url.user == nil, url.password == nil, url.port == nil,
        url.host?.contains(".") == true
      else { return nil }
      return url
    }
  }

  static func releaseAPIURL(origins: [URL], applicationName: String?) -> URL? {
    guard let name = applicationName?.lowercased().filter({ $0.isLetter || $0.isNumber }),
      name.count >= 3,
      let origin = origins.first(where: { origin in
        origin.host?.lowercased().split(separator: ".").contains { $0 == name } == true
      }), var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)
    else { return nil }
    components.path = "/api/release"
    components.queryItems = [URLQueryItem(name: "channel", value: "stable")]
    return components.url
  }

  static func hasTauriConfiguration(in bundleURL: URL) -> Bool {
    [
      bundleURL.appendingPathComponent("Contents/Resources/tauri.conf.json"),
      bundleURL.appendingPathComponent("Contents/Resources/tauri.conf.json5"),
      bundleURL.appendingPathComponent("Contents/tauri.conf.json"),
    ].contains { FileManager.default.fileExists(atPath: $0.path) }
  }

  private static func encodePathComponent(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
  }
}
