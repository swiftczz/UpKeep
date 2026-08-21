import Foundation

struct VSCodeUpdaterMetadata: Equatable, Sendable {
  let updateURL: URL
  let commit: String
  let quality: String
  let homepageURL: URL?
}

enum VSCodeUpdaterDetector {
  static func detect(in bundleURL: URL) -> VSCodeUpdaterMetadata? {
    let productURL = bundleURL.appendingPathComponent(
      "Contents/Resources/app/product.json"
    )
    guard let data = try? Data(contentsOf: productURL) else {
      return nil
    }
    return metadata(from: data)
  }

  static func metadata(from data: Data) -> VSCodeUpdaterMetadata? {
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let commit = (json["commit"] as? String)?.nonBlankValue,
      let updateURL = (json["updateUrl"] as? String).flatMap(SecureUpdateURL.https(string:))
    else {
      return nil
    }

    return VSCodeUpdaterMetadata(
      updateURL: updateURL,
      commit: commit,
      quality: (json["quality"] as? String)?.nonBlankValue ?? "stable",
      homepageURL: (json["downloadUrl"] as? String).flatMap(SecureUpdateURL.https(string:))
    )
  }

  static func platforms(for architecture: MacCPUArchitecture = .current) -> [String] {
    switch architecture {
    case .arm64:
      ["darwin-arm64", "darwin-universal"]
    case .x64:
      ["darwin", "darwin-universal"]
    }
  }

  static func checkURL(
    updateURL: URL,
    platform: String,
    quality: String,
    commit: String
  ) -> URL? {
    var base = updateURL.absoluteString
    while base.hasSuffix("/") {
      base.removeLast()
    }
    return SecureUpdateURL.https(
      string: "\(base)/api/update/\(platform)/\(quality)/\(commit)"
    )
  }

  static func sourceIdentifier(quality: String, commit: String) -> String {
    "\(quality)/\(commit)"
  }

  static func parseSourceIdentifier(_ value: String) -> (quality: String, commit: String)? {
    guard let separator = value.firstIndex(of: "/"), separator != value.startIndex else {
      return nil
    }
    let quality = String(value[..<separator])
    let commit = String(value[value.index(after: separator)...])
    guard !quality.isEmpty, !commit.isEmpty else {
      return nil
    }
    return (quality, commit)
  }
}
