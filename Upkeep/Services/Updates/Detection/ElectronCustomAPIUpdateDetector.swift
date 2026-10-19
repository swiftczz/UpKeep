import Foundation

/// Detects the product-configured v2 update protocol used by the WorkBuddy
/// family. Endpoints and channels come from the installed app, not a repo list.
enum ElectronCustomAPIUpdateDetector {
  private static let identifierPrefix = "electron-custom-api/v2/"

  static func detect(
    in bundleURL: URL, currentVersion: String,
    architecture: MacCPUArchitecture = .current
  ) -> UpdateConfiguration? {
    guard let archive = ElectronApplicationArchive(bundleURL: bundleURL),
      let packageData = archive.data(for: "package.json", maximumBytes: 128 * 1024),
      let package = try? JSONSerialization.jsonObject(with: packageData) as? [String: Any],
      let main = package["main"] as? String,
      let mainData = archive.data(for: main, maximumBytes: 8 * 1024 * 1024),
      let code = String(data: mainData, encoding: .utf8),
      code.contains("buildUpdateFeedUrl"), code.contains("/v2/update?platform="),
      code.contains("resolveUpdateClientTypePrefix"), code.contains("getFeedVersion"),
      let productData = archive.data(for: "cli/product.json", maximumBytes: 512 * 1024),
      let product = try? JSONSerialization.jsonObject(with: productData) as? [String: Any],
      let updates = product["updates"] as? [String: Any], updates["apiVersion"] as? String == "v2",
      let check = updates["checkVersion"] as? [String: Any], check["scene"] as? String == "saas",
      let download = updates["download"] as? [String: Any], download["scene"] as? String == "saas",
      let applicationName = (product["applicationName"] as? String)?.lowercased(),
      applicationName == "workbuddy" || applicationName.hasPrefix("workbuddy-"),
      applicationName.range(of: #"\A[a-z0-9-]+\z"#, options: .regularExpression) != nil,
      let endpoint = (product["endpoint"] as? String).flatMap(SecureUpdateURL.https(string:)),
      endpoint.user == nil, endpoint.password == nil, endpoint.query == nil,
      endpoint.fragment == nil,
      let feedURL = checkURL(
        endpoint: endpoint, applicationName: applicationName,
        version: currentVersion, architecture: architecture)
    else { return nil }

    // The app's own updater declares this migration. Never relax the installer's
    // bundle identity check; the legacy copy must finish it inside the app.
    let installedID = Bundle(url: bundleURL)?.bundleIdentifier
    let legacyID = literal(named: "CURRENT_DARWIN_BUNDLE_ID", in: code)
    let migrationID = literal(named: "TARGET_DARWIN_BUNDLE_ID", in: code)
    let targetID = installedID != nil && installedID == legacyID ? migrationID : nil
    let officialWebsite = (product["links"] as? [String: Any])?["officialWebsite"] as? String
    return UpdateConfiguration(
      mechanism: .customAPI, feedURL: feedURL,
      homepageURL: officialWebsite.flatMap(SecureUpdateURL.https(string:))
        ?? (package["homepage"] as? String).flatMap(SecureUpdateURL.https(string:)) ?? endpoint,
      identifier: identifierPrefix + applicationName,
      targetBundleIdentifier: targetID)
  }

  static func currentFeedURL(for application: AppRecord) -> URL? {
    guard let feed = application.updateConfiguration.feedURL.flatMap(SecureUpdateURL.https) else {
      return nil
    }
    guard usesVersionedFeed(application.updateConfiguration) else { return feed }
    guard var components = URLComponents(url: feed, resolvingAgainstBaseURL: false),
      components.path.hasSuffix("/v2/update"),
      let queries = components.queryItems, queries.filter({ $0.name == "version" }).count == 1,
      queries.filter({ $0.name == "platform" }).count == 1,
      queries.allSatisfy({ ["platform", "version"].contains($0.name) })
    else { return nil }
    components.queryItems = queries.map {
      $0.name == "version" ? URLQueryItem(name: "version", value: application.currentVersion) : $0
    }
    return components.url.flatMap(SecureUpdateURL.https)
  }

  static func usesVersionedFeed(_ configuration: UpdateConfiguration) -> Bool {
    configuration.identifier?.hasPrefix(identifierPrefix) == true
  }

  private static func checkURL(
    endpoint: URL, applicationName: String, version: String, architecture: MacCPUArchitecture
  ) -> URL? {
    let prefix =
      applicationName == "workbuddy-learn" || applicationName.hasPrefix("workbuddy-learn-")
      ? applicationName : "workbuddy"
    let arch = architecture == .arm64 ? "arm64" : "x64"
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.path =
      components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      .nonBlankValue.map { "/" + $0 + "/v2/update" } ?? "/v2/update"
    components.queryItems = [
      URLQueryItem(name: "platform", value: "\(prefix)-darwin-\(arch)"),
      URLQueryItem(name: "version", value: version),
    ]
    return components.url.flatMap(SecureUpdateURL.https)
  }

  private static func literal(named name: String, in code: String) -> String? {
    guard
      let pattern = try? NSRegularExpression(
        pattern: "(?:var|let|const)\\s+" + name + "\\s*=\\s*[\"']([a-zA-Z0-9.-]+)[\"']"),
      let match = pattern.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
      let range = Range(match.range(at: 1), in: code)
    else { return nil }
    return String(code[range])
  }
}
