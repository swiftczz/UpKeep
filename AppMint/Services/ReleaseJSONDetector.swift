import Foundation

enum ReleaseJSONDetector {
  private static let latestNeedle = Data("latest.json".utf8)
  private static let httpsNeedle = Data("https://".utf8)
  private static let urlAllowed = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%"
  )
  private static let skippedPathComponents: Set<String> = [
    "alpha", "beta", "canary", "dev", "nightly", "preview", "rc",
  ]
  private static let chunkSize = 1024 * 1024
  private static let overlapSize = 512
  private static let maximumExecutableBytes = 400 * 1024 * 1024

  static func detect(bundleURL: URL) -> URL? {
    if hasElectronFramework(in: bundleURL) || hasTauriConfiguration(in: bundleURL) {
      return nil
    }
    return endpointFromExecutable(in: bundleURL)
  }

  static func endpoint(inFile fileURL: URL) -> URL? {
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
      if let endpoint = firstEndpoint(in: window) {
        return endpoint
      }
      previousTail = Data(window.suffix(overlapSize))
    }

    return nil
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
    components.percentEncodedPath = "/" + pathComponents.map(encodePathComponent).joined(separator: "/")
    return components.url.flatMap(SecureUpdateURL.https)
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
      if let endpoint = endpoint(inFile: fileURL) {
        return endpoint
      }
    }
    return nil
  }

  private static func firstEndpoint(in window: Data) -> URL? {
    var searchStart = window.startIndex
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
      if let rawValue = String(data: slice, encoding: .utf8),
        let url = validatedEndpoint(rawValue)
      {
        return url
      }
      if let url = reconstructedStableEndpoint(from: slice) {
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
      url.lastPathComponent.lowercased() == "latest.json"
    else {
      return nil
    }

    let directories = url.path.split(separator: "/").dropLast().map { $0.lowercased() }
    if directories.contains(where: { skippedPathComponents.contains($0) }) {
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

  private static func hasTauriConfiguration(in bundleURL: URL) -> Bool {
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
