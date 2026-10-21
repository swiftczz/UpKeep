import Foundation

/// A data-only update source: where an application's releases are published and
/// how to read them. A rule only chooses the route. The installer still requires
/// HTTPS, the installed bundle identifier and a matching code signature.
struct UpdateSourceRule: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        /// A JSON endpoint read with `fields`.
        case jsonFeed
        /// The latest release of a GitHub repository.
        case githubReleases
        /// A feed in a known updater's format, handled by that updater's provider.
        case updaterFeed
    }

    /// Updater formats whose providers need nothing but the feed URL.
    enum Format: String, Codable, Sendable, CaseIterable {
        /// electron-builder's `latest-mac.yml`.
        case electronBuilder
        /// A Sparkle appcast.
        case sparkle
        /// A Tauri updater manifest.
        case tauri

        var mechanism: UpdateMechanism {
            switch self {
            case .electronBuilder: .electronBuilder
            case .sparkle: .sparkle
            case .tauri: .tauri
            }
        }
    }

    enum Precedence: String, Codable, Sendable {
        /// Wins over heuristics, but not over a store receipt or a Sparkle feed.
        case beforeHeuristics
        /// Applies only when nothing else recognizes the application.
        case fallback
    }

    struct Match: Codable, Sendable, Equatable {
        var bundleIdentifier: String?
        /// Matched against the whole bundle identifier. Named groups such as
        /// `(?<slug>...)` become template placeholders.
        var bundleIdentifierPattern: String?
    }

    /// Paths into the JSON response, such as `release.version` or `assets.0.url`.
    /// `$` is the response itself. Each field lists alternatives; the first
    /// non-empty value wins.
    struct Fields: Codable, Sendable, Equatable {
        var version: PathList
        var notes: PathList?
        var notesURL: PathList?
        var date: PathList?
        /// An array of assets, an object of assets keyed by name, or one asset.
        /// Without it, the response itself is the only asset.
        var assets: PathList?
        /// Relative to each asset. Defaults to `url`.
        var assetURL: PathList?
        var assetName: PathList?
        var assetSHA256: PathList?
        var assetSHA512: PathList?
        var assetSize: PathList?
    }

    var id: String
    var name: String?
    var kind: Kind
    var precedence: Precedence?
    var match: Match
    /// `updaterFeed`: the format `feed` is published in.
    var format: Format?
    /// `jsonFeed` and `updaterFeed`: an HTTPS URL template.
    var feed: String?
    /// `githubReleases`: an `owner/name` template.
    var repository: String?
    /// `githubReleases`: installs only assets whose names start with this template.
    var assetNamePrefix: String?
    var homepage: String?
    var fields: Fields?

    static let identifierPrefix = "rule:"

    var effectivePrecedence: Precedence { precedence ?? .beforeHeuristics }

    /// Stored in `UpdateConfiguration.identifier` for `jsonFeed` and `updaterFeed` rules.
    var configurationIdentifier: String { Self.identifierPrefix + id }

    static func ruleID(fromConfigurationIdentifier identifier: String?) -> String? {
        guard let identifier, identifier.hasPrefix(identifierPrefix) else { return nil }
        return String(identifier.dropFirst(identifierPrefix.count)).nonBlankValue
    }
}

/// One path or a list of alternative paths.
struct PathList: Codable, Sendable, Equatable, ExpressibleByArrayLiteral,
    ExpressibleByStringLiteral
{
    var paths: [String]

    init(_ paths: [String]) {
        self.paths = paths
    }

    init(arrayLiteral elements: String...) {
        paths = elements
    }

    init(stringLiteral value: String) {
        paths = [value]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let path = try? container.decode(String.self) {
            paths = [path]
        } else {
            paths = try container.decode([String].self)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(paths)
    }
}

/// `{name}` placeholders in URL, repository and asset-prefix templates.
enum UpdateSourceTemplate {
    static let builtInPlaceholders: Set<String> = ["version", "build", "bundleIdentifier", "arch"]

    static func placeholders(in template: String) -> [String] {
        var names: [String] = []
        var remainder = template[...]
        while let open = remainder.firstIndex(of: "{"),
            let close = remainder[open...].firstIndex(of: "}")
        {
            names.append(String(remainder[remainder.index(after: open)..<close]))
            remainder = remainder[remainder.index(after: close)...]
        }
        return names
    }

    /// Returns nil when a placeholder has no value. URL templates percent-encode
    /// values so a version string cannot add path segments or query items.
    static func expand(
        _ template: String, values: [String: String], percentEncoded: Bool
    ) -> String? {
        var result = ""
        var remainder = template[...]
        while let open = remainder.firstIndex(of: "{") {
            guard let close = remainder[open...].firstIndex(of: "}") else { return nil }
            result += remainder[..<open]
            let name = String(remainder[remainder.index(after: open)..<close])
            guard let value = values[name] else { return nil }
            if percentEncoded {
                guard let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved)
                else { return nil }
                result += encoded
            } else {
                result += value
            }
            remainder = remainder[remainder.index(after: close)...]
        }
        return result + remainder
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

struct UpdateSourceRuleError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

extension UpdateSourceRule {
    static let maximumPatternLength = 256

    /// Checks everything that does not depend on an installed application.
    func validate() throws {
        guard id.range(of: #"\A[a-z0-9][a-z0-9._-]{0,63}\z"#, options: .regularExpression) != nil
        else {
            throw UpdateSourceRuleError(message: "id 只能使用小写字母、数字、点、下划线和连字符，最长 64 个字符。")
        }

        let exact = match.bundleIdentifier?.nonBlankValue
        let pattern = match.bundleIdentifierPattern?.nonBlankValue
        guard (exact == nil) != (pattern == nil) else {
            throw UpdateSourceRuleError(
                message: "match 需要且只能填写 bundleIdentifier 或 bundleIdentifierPattern 之一。")
        }
        var placeholders = UpdateSourceTemplate.builtInPlaceholders
        if let pattern {
            guard pattern.count <= Self.maximumPatternLength,
                (try? NSRegularExpression(pattern: pattern)) != nil
            else {
                throw UpdateSourceRuleError(message: "bundleIdentifierPattern 不是有效的正则表达式。")
            }
            placeholders.formUnion(Self.captureGroupNames(in: pattern))
        }

        switch kind {
        case .jsonFeed, .updaterFeed:
            guard let feed = feed?.nonBlankValue, feed.lowercased().hasPrefix("https://") else {
                throw UpdateSourceRuleError(
                    message: "\(kind.rawValue) 规则需要以 https:// 开头的 feed。")
            }
            try checkPlaceholders(in: feed, field: "feed", allowed: placeholders)
            if kind == .jsonFeed {
                guard let fields, !fields.version.paths.isEmpty else {
                    throw UpdateSourceRuleError(message: "jsonFeed 规则需要 fields.version。")
                }
            } else if format == nil {
                let formats = Format.allCases.map(\.rawValue).joined(separator: "、")
                throw UpdateSourceRuleError(message: "updaterFeed 规则需要 format：\(formats)。")
            }
        case .githubReleases:
            guard let repository = repository?.nonBlankValue,
                repository.split(separator: "/", omittingEmptySubsequences: false).count == 2
            else {
                throw UpdateSourceRuleError(message: "githubReleases 规则需要 owner/name 形式的 repository。")
            }
            try checkPlaceholders(in: repository, field: "repository", allowed: placeholders)
            if let assetNamePrefix {
                try checkPlaceholders(
                    in: assetNamePrefix, field: "assetNamePrefix", allowed: placeholders)
            }
        }

        if let homepage = homepage?.nonBlankValue {
            guard homepage.lowercased().hasPrefix("https://") else {
                throw UpdateSourceRuleError(message: "homepage 必须以 https:// 开头。")
            }
            try checkPlaceholders(in: homepage, field: "homepage", allowed: placeholders)
        }
    }

    private func checkPlaceholders(in template: String, field: String, allowed: Set<String>) throws
    {
        for name in UpdateSourceTemplate.placeholders(in: template) where !allowed.contains(name) {
            throw UpdateSourceRuleError(message: "\(field) 使用了未知的占位符 {\(name)}。")
        }
    }

    static func captureGroupNames(in pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"\(\?<([A-Za-z][A-Za-z0-9]*)>"#)
        else { return [] }
        return expression.matches(in: pattern, range: NSRange(pattern.startIndex..., in: pattern))
            .compactMap { Range($0.range(at: 1), in: pattern).map { String(pattern[$0]) } }
    }
}

/// A rule that matched one bundle identifier, with its placeholder values.
struct UpdateSourceRuleMatch: Sendable {
    let rule: UpdateSourceRule
    let captures: [String: String]

    func values(
        version: String, build: String?, bundleIdentifier: String,
        architecture: MacCPUArchitecture = .current
    ) -> [String: String] {
        var values = captures
        values["version"] = version
        values["build"] = build ?? version
        values["bundleIdentifier"] = bundleIdentifier
        values["arch"] = architecture == .arm64 ? "arm64" : "x64"
        return values
    }

    func feedURL(values: [String: String]) -> URL? {
        guard rule.kind != .githubReleases, let feed = rule.feed else { return nil }
        return httpsURL(feed, values: values)
    }

    func homepageURL(values: [String: String]) -> URL? {
        rule.homepage.flatMap { httpsURL($0, values: values) }
    }

    func gitHubRepository(values: [String: String]) -> GitHubRepository? {
        guard rule.kind == .githubReleases, let template = rule.repository,
            let expanded = UpdateSourceTemplate.expand(
                template, values: values, percentEncoded: false)
        else { return nil }
        let parts = expanded.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return GitHubRepository(owner: String(parts[0]), name: String(parts[1]))
    }

    func assetNamePrefix(values: [String: String]) -> String? {
        rule.assetNamePrefix.flatMap {
            UpdateSourceTemplate.expand($0, values: values, percentEncoded: false)?.nonBlankValue
        }
    }

    func gitHubReleasesMetadata(values: [String: String]) -> GitHubReleasesMetadata? {
        guard let repository = gitHubRepository(values: values),
            let apiURL = repository.apiURL(path: ["releases", "latest"]),
            let homepageURL = homepageURL(values: values) ?? repository.homepageURL
        else { return nil }
        return GitHubReleasesMetadata(
            identifier: repository.identifier, apiURL: apiURL, homepageURL: homepageURL)
    }

    func configuration(values: [String: String]) -> UpdateConfiguration? {
        switch rule.kind {
        case .jsonFeed:
            guard let feedURL = feedURL(values: values) else { return nil }
            return UpdateConfiguration(
                mechanism: .customAPI, feedURL: feedURL,
                homepageURL: homepageURL(values: values),
                identifier: rule.configurationIdentifier)
        case .githubReleases:
            guard let metadata = gitHubReleasesMetadata(values: values) else { return nil }
            return UpdateConfiguration(
                mechanism: .githubReleases, feedURL: metadata.apiURL,
                homepageURL: metadata.homepageURL, identifier: metadata.identifier)
        case .updaterFeed:
            // The updater's provider reads the stored feed; placeholders are resolved
            // again whenever the scanner sees a new version.
            guard let format = rule.format, let feedURL = feedURL(values: values) else {
                return nil
            }
            return UpdateConfiguration(
                mechanism: format.mechanism, feedURL: feedURL,
                homepageURL: homepageURL(values: values),
                identifier: rule.configurationIdentifier)
        }
    }

    private func httpsURL(_ template: String, values: [String: String]) -> URL? {
        guard
            let expanded = UpdateSourceTemplate.expand(
                template, values: values, percentEncoded: true),
            let url = SecureUpdateURL.https(string: expanded),
            url.user == nil, url.password == nil
        else { return nil }
        return url
    }
}
