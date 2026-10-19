import Foundation

/// Recognizes Electron providers that replace a development feed with a public
/// service manifest. The response still uses the standard Electron YAML format.
enum ElectronServiceManifestDetector {
  static func detect(
    in bundleURL: URL, architecture: MacCPUArchitecture = .current
  ) -> ElectronBuilderMetadata? {
    guard let archive = ElectronApplicationArchive(bundleURL: bundleURL),
      let package = archive.json(for: "package.json", maximumBytes: 128 * 1024),
      (package["dependencies"] as? [String: Any])?["electron-updater"] != nil,
      let homepage = (package["homepage"] as? String).flatMap(publicURL),
      let code = archive.mainCode(in: package),
      code.contains("ManifestUpdateProvider"),
      let builder = functionBody(named: "buildElectronManifestUrl", in: code),
      builder.contains("searchParams.set(\"platform\","),
      builder.contains("searchParams.set(\"channel\","),
      let platformMapper = functionBody(named: "mapElectronReleaseArch", in: code),
      let channelMapper = functionBody(named: "mapReleaseChannelToApiValue", in: code),
      let stableChannel = uniqueMatch(
        #"\breturn\s+\w+\s*===\s*["']preview["']\s*\?\s*["'][^"']+["']\s*:\s*["']([a-zA-Z0-9-]+)["']"#,
        in: channelMapper)?.first,
      let platformArch = uniqueMatch(
        #"\bcase\s*["']"# + (architecture == .arm64 ? "arm64" : "x64")
          + #"["']\s*:\s*return\s*["']([a-zA-Z0-9_]+)["']"#,
        in: platformMapper)?.first,
      let feedOriginSymbol = uniqueMatch(
        #"\.setFeedURL\(\{provider:["']custom["'],updateProvider:[A-Za-z_$][A-Za-z0-9_$]*,endpointOrigin:([A-Za-z_$][A-Za-z0-9_$]*)[,}]"#,
        in: code)?.first,
      let origin = archive.mainStringLiteral(named: feedOriginSymbol, in: package).flatMap(
        publicURL),
      origin.query == nil, origin.fragment == nil,
      origin.host?.lowercased() == homepage.host?.lowercased(), origin.port == homepage.port,
      let pathSymbol = uniqueMatch(
        #"new\s+URL\(([A-Za-z_$][A-Za-z0-9_$]*),"#, in: builder)?.first,
      let path = archive.mainStringLiteral(named: pathSymbol, in: package),
      path.hasPrefix("/"), !path.hasPrefix("//"), path.hasSuffix("/manifest"),
      let manifestURL = URL(string: path, relativeTo: origin)?.absoluteURL,
      publicURL(manifestURL.absoluteString) != nil,
      manifestURL.host == origin.host,
      var components = URLComponents(url: manifestURL, resolvingAgainstBaseURL: false),
      components.query == nil, components.fragment == nil
    else { return nil }
    components.queryItems = [
      URLQueryItem(name: "platform", value: "darwin-" + platformArch),
      URLQueryItem(name: "channel", value: stableChannel),
    ]
    guard let feed = components.url else { return nil }
    return ElectronBuilderMetadata(
      identifier: feed.absoluteString, feedURL: feed, homepageURL: homepage)
  }

  private static func functionBody(named name: String, in code: String) -> String? {
    uniqueMatch(
      #"\bfunction\s+([A-Za-z_$][A-Za-z0-9_$]*)\([^()]{0,256}\)\{([\s\S]{1,3000}?)\}\s*;?\s*[A-Za-z_$][A-Za-z0-9_$]*\(\1,["']"#
        + NSRegularExpression.escapedPattern(for: name) + #"["']\)"#,
      in: code)?.last
  }

  private static func publicURL(_ value: String) -> URL? {
    guard let url = SecureUpdateURL.https(string: value), url.user == nil, url.password == nil,
      let host = url.host?.lowercased(),
      !["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
    else { return nil }
    return url
  }

  private static func uniqueMatch(_ pattern: String, in text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    guard matches.count == 1, let match = matches.first else { return nil }
    return (1..<match.numberOfRanges).map {
      Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? ""
    }
  }
}
