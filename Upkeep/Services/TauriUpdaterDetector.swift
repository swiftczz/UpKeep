import Foundation

struct ExecutableUpdaterDetection: Sendable {
  var tauriEndpoint: URL?
  var releaseJSONEndpoint: URL?
  var githubReleases: [GitHubReleasesMetadata] = []
}

enum ExecutableUpdaterDetector {
  private static let chunkSize = 1024 * 1024
  private static let overlapSize = 512
  private static let maximumExecutableBytes = 400 * 1024 * 1024

  static func detect(bundleURL: URL) -> ExecutableUpdaterDetection {
    if let endpoint = TauriUpdaterDetector.endpointFromConfiguration(in: bundleURL) {
      return ExecutableUpdaterDetection(tauriEndpoint: endpoint, releaseJSONEndpoint: nil)
    }
    // Electron can delegate updates to its own native service. Never inspect the
    // shared Electron runtime for application-specific endpoints.
    let files = TauriUpdaterDetector.hasElectronFramework(in: bundleURL)
      ? applicationServiceExecutables(in: bundleURL) : executableFiles(in: bundleURL)

    let suppressReleaseJSON = ReleaseJSONDetector.hasTauriConfiguration(in: bundleURL)
    var releaseJSONEndpoint: URL?
    var githubReleases: [GitHubReleasesMetadata] = []
    var seenGitHubReleases = Set<String>()
    for fileURL in files {
      let detection = detect(fileURL: fileURL)
      if let tauriEndpoint = detection.tauriEndpoint {
        return ExecutableUpdaterDetection(
          tauriEndpoint: tauriEndpoint,
          releaseJSONEndpoint: nil
        )
      }
      if releaseJSONEndpoint == nil, !suppressReleaseJSON {
        releaseJSONEndpoint = detection.releaseJSONEndpoint
      }
      for candidate in detection.githubReleases
      where seenGitHubReleases.insert(candidate.identifier).inserted {
        githubReleases.append(candidate)
      }
    }
    return ExecutableUpdaterDetection(
      tauriEndpoint: nil,
      releaseJSONEndpoint: releaseJSONEndpoint,
      githubReleases: githubReleases
    )
  }

  static func detect(fileURL: URL) -> ExecutableUpdaterDetection {
    guard
      let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
      values.isRegularFile == true,
      let fileSize = values.fileSize,
      fileSize > 0,
      fileSize <= maximumExecutableBytes,
      let handle = try? FileHandle(forReadingFrom: fileURL)
    else {
      return ExecutableUpdaterDetection(tauriEndpoint: nil, releaseJSONEndpoint: nil)
    }
    defer { try? handle.close() }

    var previousTail = Data()
    var foundURLs: [URL] = []
    var seen = Set<String>()
    var sawTauri = false
    var sawGPUI = false
    var releaseJSONEndpoint: URL?
    var githubReleases: [GitHubReleasesMetadata] = []
    var seenGitHubReleases = Set<String>()

    while true {
      let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
      if chunk.isEmpty {
        break
      }

      let window = previousTail + chunk
      let evidence = TauriUpdaterDetector.evidence(in: window)
      sawTauri = sawTauri || evidence.sawTauri
      sawGPUI = sawGPUI || evidence.sawGPUI
      for url in TauriUpdaterDetector.updaterJSONURLs(in: window)
      where seen.insert(url.absoluteString).inserted {
        foundURLs.append(url)
      }
      if releaseJSONEndpoint == nil {
        releaseJSONEndpoint = ReleaseJSONDetector.firstEndpoint(in: window)
      }
      for candidate in GitHubReleasesDetector.metadataCandidates(in: window)
      where seenGitHubReleases.insert(candidate.identifier).inserted {
        githubReleases.append(candidate)
      }
      if sawTauri, foundURLs.contains(where: TauriUpdaterDetector.isDirectManifestURL) {
        break
      }
      previousTail = Data(window.suffix(overlapSize))
    }

    let tauriEndpoint =
      sawGPUI && !sawTauri
      ? nil
      : TauriUpdaterDetector.preferredUpdaterJSONURL(foundURLs)
    return ExecutableUpdaterDetection(
      tauriEndpoint: tauriEndpoint,
      releaseJSONEndpoint: releaseJSONEndpoint,
      githubReleases: githubReleases
    )
  }

  static func hasApplicationService(in bundleURL: URL) -> Bool {
    !applicationServiceExecutables(in: bundleURL).isEmpty
  }

  private static func applicationServiceExecutables(in bundleURL: URL) -> [URL] {
    guard let name = Bundle(url: bundleURL)?.executableURL?.lastPathComponent.lowercased(),
      !name.isEmpty else { return [] }
    let root = bundleURL.resolvingSymlinksInPath().standardizedFileURL
    let directory = root.appendingPathComponent("Contents/Resources/service")
    return [name + "-desktop", name].compactMap { name in
      let url = directory.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
      guard url.path.hasPrefix(root.path + "/"), isRegularFile(url),
        FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
      return url
    }
  }

  private static func executableFiles(in bundleURL: URL) -> [URL] {
    let macosURL = bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
    let preferredName = Bundle(url: bundleURL)?.executableURL?.lastPathComponent
    var files =
      (try? FileManager.default.contentsOfDirectory(
        at: macosURL,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
      )) ?? []

    if let preferredName,
      let preferredIndex = files.firstIndex(where: { $0.lastPathComponent == preferredName })
    {
      files.swapAt(0, preferredIndex)
    }

    var seen = Set(files.map(\.standardizedFileURL.path))
    for file in applicationPayloadExecutables(in: bundleURL, preferredName: preferredName)
    where seen.insert(file.standardizedFileURL.path).inserted {
      files.append(file)
    }
    return files
  }

  private static func applicationPayloadExecutables(
    in bundleURL: URL,
    preferredName: String?
  ) -> [URL] {
    let frameworksURL = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
    let frameworkNames = ["App", preferredName].compactMap(\.self)
    var files: [URL] = []

    for frameworkName in frameworkNames {
      let frameworkURL = frameworksURL.appendingPathComponent(
        "\(frameworkName).framework",
        isDirectory: true
      )
      let candidates = [
        Bundle(url: frameworkURL)?.executableURL,
        frameworkURL
          .appendingPathComponent("Versions/A", isDirectory: true)
          .appendingPathComponent(frameworkName),
        frameworkURL.appendingPathComponent(frameworkName),
      ].compactMap(\.self)

      for candidate in candidates where isRegularFile(candidate) {
        files.append(candidate)
        break
      }
    }

    return files
  }

  private static func isRegularFile(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
  }
}

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

  fileprivate static func endpointFromConfiguration(in bundleURL: URL) -> URL? {
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

  fileprivate static func updaterJSONURLs(in window: Data) -> [URL] {
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

  fileprivate static func preferredUpdaterJSONURL(_ urls: [URL]) -> URL? {
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

  fileprivate static func isDirectManifestURL(_ url: URL) -> Bool {
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

  fileprivate static func hasElectronFramework(in bundleURL: URL) -> Bool {
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

  fileprivate static func evidence(in data: Data) -> (sawTauri: Bool, sawGPUI: Bool) {
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
