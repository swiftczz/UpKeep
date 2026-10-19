import Foundation

enum TauriUpdaterDetector {
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
    charactersIn:
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%"
  )

  static func detect(bundleURL: URL) -> URL? {
    ExecutableUpdaterDetector.detect(bundleURL: bundleURL).tauriEndpoint
  }

  static func updaterJSONURL(inFile fileURL: URL) -> URL? {
    ExecutableUpdaterDetector.detect(fileURL: fileURL).tauriEndpoint
  }

  static func endpointFromConfiguration(in bundleURL: URL) -> URL? {
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

  static func updaterJSONURLs(in window: Data) -> [URL] {
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

  static func preferredUpdaterJSONURL(_ urls: [URL]) -> URL? {
    if let url = urls.first(where: {
      $0.lastPathComponent.lowercased() == "latest.json" && !isRepositoryLatestManifestURL($0)
    }) {
      return url
    }
    if let url = urls.first(where: { $0.lastPathComponent.lowercased() == "update-proxy.json" }) {
      return url
    }

    let catalogs = urls.filter { $0.lastPathComponent.lowercased() == "versions.json" }
    let catalog = catalogs.max { lhs, rhs in
      if lhs.pathComponents.count != rhs.pathComponents.count {
        return lhs.pathComponents.count < rhs.pathComponents.count
      }
      return lhs.absoluteString.count < rhs.absoluteString.count
    }
    // Repository-wide pointers can be documentation strings or belong to another
    // product in a shared repo. Prefer an embedded application-specific catalog.
    return catalog ?? urls.first(where: isRepositoryLatestManifestURL)
  }

  static func isRepositoryLatestManifestURL(_ url: URL) -> Bool {
    guard ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? "") else {
      return false
    }
    let parts = url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
    return parts.count == 6
      && Array(parts.dropFirst(2)) == ["releases", "latest", "download", "latest.json"]
  }

  static func isDirectManifestURL(_ url: URL) -> Bool {
    let name = url.lastPathComponent.lowercased()
    return (name == "latest.json" && !isRepositoryLatestManifestURL(url))
      || name == "update-proxy.json"
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
    if rawValue.contains("%s") || rawValue.contains("%d") || rawValue.contains("{{")
      || rawValue.range(of: #"(?i)(?:^|[/_-])v?x\.y\.z(?:[/_-]|$)"#, options: .regularExpression)
        != nil
    {
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

  static func hasElectronFramework(in bundleURL: URL) -> Bool {
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

  static func evidence(in data: Data) -> (sawTauri: Bool, sawGPUI: Bool) {
    (
      sawTauri: tauriNeedles.contains { data.range(of: $0) != nil },
      sawGPUI: data.range(of: gpuiNeedle) != nil
    )
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
