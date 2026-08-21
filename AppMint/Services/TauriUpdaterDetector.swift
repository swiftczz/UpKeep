import Foundation

enum TauriUpdaterDetector {
  private static let endpointPattern = try! NSRegularExpression(
    pattern: #"https://[A-Za-z0-9._~:/?#@!$&'()*+,;=%\-]+"#
  )
  private static let latestNeedle = Data("latest.json".utf8)
  private static let proxyNeedle = Data("update-proxy.json".utf8)
  private static let httpsNeedle = Data("https://".utf8)
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
    while true {
      let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
      if chunk.isEmpty {
        break
      }

      let window = previousTail + chunk
      if let url = firstUpdaterJSONURL(in: window) {
        return url
      }
      previousTail = Data(window.suffix(overlapSize))
    }

    return nil
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

  private static func firstUpdaterJSONURL(in window: Data) -> URL? {
    for needle in [latestNeedle, proxyNeedle] {
      var searchStart = window.startIndex
      while let range = window[searchStart...].range(of: needle) {
        if let url = url(endingAt: range, in: window) {
          return url
        }
        searchStart = range.upperBound
      }
    }
    return nil
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
      return validatedUpdaterJSONURL(
        String(decoding: window[search..<needleRange.upperBound], as: UTF8.self)
      )
    }

    return nil
  }

  private static func validatedUpdaterJSONURL(_ rawValue: String) -> URL? {
    if rawValue.contains("%s") || rawValue.contains("%d") || rawValue.contains("{{") {
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
    return name == "latest.json" || name == "update-proxy.json"
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
