import Foundation

enum TauriUpdaterDetector {
  private static let endpointPattern = try! NSRegularExpression(
    pattern: #"https://[A-Za-z0-9._~:/?#@!$&'()*+,;=%\-]+"#
  )
  private static let latestNeedle = Data("latest.json".utf8)
  private static let proxyNeedle = Data("update-proxy.json".utf8)
  private static let catalogNeedle = Data("versions.json".utf8)
  private static let httpsNeedle = Data("https://".utf8)
  private static let gpuiNeedle = Data("gpui::".utf8)
  private static let tauriNeedles = [
    Data("tauri_plugin_updater".utf8),
    Data("tauri://localhost".utf8),
    Data("__TAURI__".utf8),
    Data("tauri.conf.json".utf8),
  ]
  private static let urlAllowed = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%"
  )
  private static let chunkSize = 1024 * 1024
  private static let overlapSize = 512
  private static let maximumExecutableBytes = 400 * 1024 * 1024

  static func detect(bundleURL: URL) -> URL? {
    if let endpoint = endpointFromConfiguration(in: bundleURL) {
      return endpoint
    }
    if hasElectronFramework(in: bundleURL) {
      return nil
    }
    return endpointFromExecutable(in: bundleURL)
  }

  static func updaterJSONURLs(in text: String) -> [URL] {
    let range = NSRange(text.startIndex..., in: text)
    let matches = endpointPattern.matches(in: text, range: range)
    var urls: [URL] = []
    var seen = Set<String>()

    for match in matches {
      guard let matchRange = Range(match.range, in: text) else {
        continue
      }
      var candidate = String(text[matchRange])
      if let jsonRange = candidate.range(of: ".json", options: [.backwards, .caseInsensitive]) {
        candidate = String(candidate[..<jsonRange.upperBound])
      }
      guard let url = validatedUpdaterJSONURL(candidate) else {
        continue
      }
      if seen.insert(url.absoluteString).inserted {
        urls.append(url)
      }
    }

    return urls
  }

  static func updaterJSONURL(inFile fileURL: URL) -> URL? {
    guard
      let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
      values.isRegularFile == true,
      let fileSize = values.fileSize,
      fileSize > 0,
      fileSize <= maximumExecutableBytes,
      let handle = try? FileHandle(forReadingFrom: fileURL)
    else {
      return nil
    }
    defer { try? handle.close() }

    var previousTail = Data()
    var foundURLs: [URL] = []
    var seen = Set<String>()
    var sawTauri = false
    var sawGPUI = false

    while true {
      let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
      if chunk.isEmpty {
        break
      }

      let window = previousTail + chunk
      if !sawTauri {
        sawTauri = tauriNeedles.contains { window.range(of: $0) != nil }
      }
      if !sawGPUI, window.range(of: gpuiNeedle) != nil {
        sawGPUI = true
      }
      for url in updaterJSONURLs(in: window) where seen.insert(url.absoluteString).inserted {
        foundURLs.append(url)
      }
      if sawTauri, foundURLs.contains(where: isDirectManifestURL) {
        break
      }
      previousTail = Data(window.suffix(overlapSize))
    }

    if sawGPUI, !sawTauri {
      return nil
    }
    return preferredUpdaterJSONURL(foundURLs)
  }

  private static func endpointFromConfiguration(in bundleURL: URL) -> URL? {
    let candidateURLs = [
      bundleURL.appendingPathComponent("Contents/Resources/tauri.conf.json"),
      bundleURL.appendingPathComponent("Contents/Resources/tauri.conf.json5"),
      bundleURL.appendingPathComponent("Contents/tauri.conf.json"),
    ]

    for fileURL in candidateURLs {
      guard
        let data = try? Data(contentsOf: fileURL),
        let json = try? JSONSerialization.jsonObject(with: data)
      else {
        continue
      }
      let endpoints = stringValues(in: json, keys: ["endpoints"])
        .compactMap(validatedUpdaterJSONURL)
      if let endpoint = endpoints.first {
        return endpoint
      }
    }

    return nil
  }

  private static func endpointFromExecutable(in bundleURL: URL) -> URL? {
    let macosURL = bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
    let preferredName = Bundle(url: bundleURL)?.executableURL?.lastPathComponent
    let listed =
      (try? FileManager.default.contentsOfDirectory(
        at: macosURL,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
      )) ?? []

    var files = listed
    if let preferredName,
      let preferredIndex = files.firstIndex(where: { $0.lastPathComponent == preferredName })
    {
      files.swapAt(0, preferredIndex)
    }

    for fileURL in files {
      if let endpoint = updaterJSONURL(inFile: fileURL) {
        return endpoint
      }
    }
    return nil
  }

  private static func updaterJSONURLs(in window: Data) -> [URL] {
    var urls: [URL] = []
    for needle in [latestNeedle, proxyNeedle, catalogNeedle] {
      var searchStart = window.startIndex
      while let range = window[searchStart...].range(of: needle) {
        if let url = url(endingAt: range, in: window) {
          urls.append(url)
        }
        searchStart = range.upperBound
      }
    }
    return urls
  }

  private static func preferredUpdaterJSONURL(_ urls: [URL]) -> URL? {
    if let url = urls.first(where: { $0.lastPathComponent.lowercased() == "latest.json" }) {
      return url
    }
    if let url = urls.first(where: { $0.lastPathComponent.lowercased() == "update-proxy.json" }) {
      return url
    }

    let catalogs = urls.filter { $0.lastPathComponent.lowercased() == "versions.json" }
    return catalogs.max { lhs, rhs in
      if lhs.pathComponents.count != rhs.pathComponents.count {
        return lhs.pathComponents.count < rhs.pathComponents.count
      }
      return lhs.absoluteString.count < rhs.absoluteString.count
    }
  }

  private static func isDirectManifestURL(_ url: URL) -> Bool {
    let name = url.lastPathComponent.lowercased()
    return name == "latest.json" || name == "update-proxy.json"
  }

  private static func url(
    endingAt needleRange: Range<Data.Index>,
    in window: Data
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
      guard let rawValue = String(data: slice, encoding: .utf8) else {
        continue
      }
      if let url = validatedUpdaterJSONURL(rawValue) {
        return url
      }
    }

    return nil
  }

  private static func validatedUpdaterJSONURL(_ rawValue: String) -> URL? {
    if rawValue.contains("%s") || rawValue.contains("%d") || rawValue.contains("{{") {
      return nil
    }
    guard rawValue.unicodeScalars.allSatisfy({ urlAllowed.contains($0) }) else {
      return nil
    }
    guard let url = SecureUpdateURL.https(string: rawValue), isUpdaterJSON(url) else {
      return nil
    }
    return url
  }

  private static func hasElectronFramework(in bundleURL: URL) -> Bool {
    FileManager.default.fileExists(
      atPath: bundleURL.appendingPathComponent(
        "Contents/Frameworks/Electron Framework.framework"
      ).path
    )
  }

  private static func isUpdaterJSON(_ url: URL) -> Bool {
    let name = url.lastPathComponent.lowercased()
    return name == "latest.json" || name == "update-proxy.json" || name == "versions.json"
  }

  private static func stringValues(in json: Any, keys: Set<String>) -> [String] {
    var results: [String] = []
    var stack: [Any] = [json]

    while let current = stack.popLast() {
      if let dictionary = current as? [String: Any] {
        for (key, value) in dictionary {
          if keys.contains(key), let strings = value as? [String] {
            results.append(contentsOf: strings)
          } else if keys.contains(key), let string = value as? String {
            results.append(string)
          } else {
            stack.append(value)
          }
        }
      } else if let array = current as? [Any] {
        stack.append(contentsOf: array)
      }
    }

    return results
  }
}
