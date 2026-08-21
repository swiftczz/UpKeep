import Darwin
import Foundation

struct GitHubSourceMetadata: Equatable, Sendable {
  let repositoryIdentifier: String?
  let sourceURL: URL
}

struct GitHubSourceDetector {
  static func detect(applicationURL: URL, bundleURL: URL) -> GitHubSourceMetadata? {
    if let metadata = metadataFromDownloadOrigin(at: applicationURL) {
      return metadata
    }
    return metadataFromElectronUpdater(in: bundleURL)
  }

  private static func metadataFromDownloadOrigin(
    at applicationURL: URL
  ) -> GitHubSourceMetadata? {
    guard
      let data = extendedAttributeData(
        named: "com.apple.metadata:kMDItemWhereFroms",
        at: applicationURL
      ),
      let values = try? PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      ) as? [String]
    else {
      return nil
    }

    let githubURLs = values.compactMap { value -> URL? in
      guard let url = URL(string: value), isGitHubURL(url) else {
        return nil
      }
      return url
    }
    if let repositoryURL = githubURLs.first(where: isRepositoryURL) {
      return metadata(for: repositoryURL)
    }
    return githubURLs.first.map { metadata(for: $0) }
  }

  private static func metadataFromElectronUpdater(
    in bundleURL: URL
  ) -> GitHubSourceMetadata? {
    let resourcesURL = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
    let candidateURLs = [
      resourcesURL.appendingPathComponent("app-update.yml"),
      resourcesURL.appendingPathComponent("app-update.yaml"),
    ]

    for configurationURL in candidateURLs {
      guard
        let configuration = try? String(contentsOf: configurationURL, encoding: .utf8),
        let values = simpleYAMLValues(in: configuration),
        values["provider"]?.caseInsensitiveCompare("github") == .orderedSame
      else {
        continue
      }

      let owner = values["owner"]?.nonBlankValue
      let repository = values["repo"]?.nonBlankValue
      guard
        let owner,
        let repository,
        let sourceURL = URL(string: "https://github.com/\(owner)/\(repository)")
      else {
        continue
      }

      return GitHubSourceMetadata(
        repositoryIdentifier: "\(owner)/\(repository)",
        sourceURL: sourceURL
      )
    }

    return nil
  }

  private static func simpleYAMLValues(in configuration: String) -> [String: String]? {
    let values = configuration.split(whereSeparator: \.isNewline).reduce(
      into: [String: String]()
    ) { result, line in
      let components = line.split(separator: ":", maxSplits: 1)
      guard components.count == 2 else {
        return
      }

      let key = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
      let value = components[1]
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      result[key] = value
    }
    return values.isEmpty ? nil : values
  }

  private static func metadata(for url: URL) -> GitHubSourceMetadata {
    guard
      url.host?.lowercased() == "github.com",
      url.pathComponents.count >= 3
    else {
      return GitHubSourceMetadata(repositoryIdentifier: nil, sourceURL: url)
    }

    let owner = url.pathComponents[1]
    let repository = url.pathComponents[2].replacingOccurrences(of: ".git", with: "")
    let repositoryIdentifier = "\(owner)/\(repository)"
    return GitHubSourceMetadata(
      repositoryIdentifier: repositoryIdentifier,
      sourceURL: URL(string: "https://github.com/\(repositoryIdentifier)") ?? url
    )
  }

  private static func isGitHubURL(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else {
      return false
    }
    return host == "github.com"
      || host.hasSuffix(".github.com")
      || host == "githubusercontent.com"
      || host.hasSuffix(".githubusercontent.com")
  }

  private static func isRepositoryURL(_ url: URL) -> Bool {
    url.host?.lowercased() == "github.com" && url.pathComponents.count >= 3
  }

  private static func extendedAttributeData(named name: String, at url: URL) -> Data? {
    let length = url.path.withCString { path in
      name.withCString { attributeName in
        getxattr(path, attributeName, nil, 0, 0, 0)
      }
    }
    guard length > 0 else {
      return nil
    }

    var buffer = [UInt8](repeating: 0, count: length)
    let result = buffer.withUnsafeMutableBytes { bytes in
      url.path.withCString { path in
        name.withCString { attributeName in
          getxattr(path, attributeName, bytes.baseAddress, bytes.count, 0, 0)
        }
      }
    }
    guard result == length else {
      return nil
    }
    return Data(buffer)
  }
}

extension String {
  fileprivate var nonBlankValue: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
