import Foundation
import Synchronization

/// Validated rules, ready to match bundle identifiers.
struct UpdateSourceRuleSet: Sendable {
    struct Issue: Sendable, Equatable, Hashable {
        /// The file or rule the problem was found in.
        let source: String
        let message: String
    }

    private struct Entry: Sendable {
        let rule: UpdateSourceRule
        let pattern: RulePattern?
        let captureNames: [String]
    }

    private let entries: [Entry]
    let issues: [Issue]

    var rules: [UpdateSourceRule] { entries.map(\.rule) }

    static let empty = UpdateSourceRuleSet(rules: [])

    /// Invalid rules and repeated ids are reported in `issues` and skipped.
    init(rules: [UpdateSourceRule], source: String = "内置规则", issues: [Issue] = []) {
        var entries: [Entry] = []
        var issues = issues
        var seen = Set<String>()
        for rule in rules {
            do {
                try rule.validate()
            } catch {
                issues.append(Issue(source: "\(source) · \(rule.id)", message: error.localizedDescription))
                continue
            }
            guard seen.insert(rule.id).inserted else {
                issues.append(Issue(source: "\(source) · \(rule.id)", message: "规则 id 重复，已忽略后出现的规则。"))
                continue
            }
            let pattern = rule.match.bundleIdentifierPattern?.nonBlankValue.flatMap(RulePattern.init)
            entries.append(
                Entry(
                    rule: rule, pattern: pattern,
                    captureNames: rule.match.bundleIdentifierPattern.map(
                        UpdateSourceRule.captureGroupNames(in:)) ?? []))
        }
        self.entries = entries
        self.issues = issues
    }

    private init(entries: [Entry], issues: [Issue]) {
        self.entries = entries
        self.issues = issues
    }

    /// `overrides` replaces rules with the same id and is consulted first.
    func overlaid(by overrides: UpdateSourceRuleSet) -> UpdateSourceRuleSet {
        let overriddenIDs = Set(overrides.entries.map(\.rule.id))
        return UpdateSourceRuleSet(
            entries: overrides.entries + entries.filter { !overriddenIDs.contains($0.rule.id) },
            issues: overrides.issues + issues)
    }

    func firstMatch(
        for bundleIdentifier: String,
        precedence: UpdateSourceRule.Precedence? = nil,
        kind: UpdateSourceRule.Kind? = nil
    ) -> UpdateSourceRuleMatch? {
        for entry in entries
        where precedence.map({ entry.rule.effectivePrecedence == $0 }) ?? true
            && kind.map({ entry.rule.kind == $0 }) ?? true
        {
            if let captures = captures(of: entry, in: bundleIdentifier) {
                return UpdateSourceRuleMatch(rule: entry.rule, captures: captures)
            }
        }
        return nil
    }

    /// The rule a stored configuration came from, if it still applies to the app.
    func match(
        configurationIdentifier: String?, bundleIdentifier: String
    ) -> UpdateSourceRuleMatch? {
        guard let id = UpdateSourceRule.ruleID(fromConfigurationIdentifier: configurationIdentifier),
            let entry = entries.first(where: { $0.rule.id == id }),
            let captures = captures(of: entry, in: bundleIdentifier)
        else { return nil }
        return UpdateSourceRuleMatch(rule: entry.rule, captures: captures)
    }

    /// The repository a GitHub rule assigns to this bundle identifier.
    func gitHubReleasesMatch(
        for bundleIdentifier: String
    ) -> (match: UpdateSourceRuleMatch, values: [String: String])? {
        guard let match = firstMatch(for: bundleIdentifier, kind: .githubReleases) else {
            return nil
        }
        var values = match.captures
        values["bundleIdentifier"] = bundleIdentifier
        return (match, values)
    }

    func gitHubReleasesMetadata(for bundleIdentifier: String) -> GitHubReleasesMetadata? {
        gitHubReleasesMatch(for: bundleIdentifier).flatMap {
            $0.match.gitHubReleasesMetadata(values: $0.values)
        }
    }

    private func captures(of entry: Entry, in bundleIdentifier: String) -> [String: String]? {
        if let exact = entry.rule.match.bundleIdentifier?.nonBlankValue {
            return exact.caseInsensitiveCompare(bundleIdentifier) == .orderedSame ? [:] : nil
        }
        guard let pattern = entry.pattern else { return nil }
        let fullRange = NSRange(bundleIdentifier.startIndex..., in: bundleIdentifier)
        // `$` also matches before a trailing newline, so require the whole string.
        guard let match = pattern.expression.firstMatch(in: bundleIdentifier, range: fullRange),
            match.range == fullRange
        else { return nil }
        var captures: [String: String] = [:]
        for name in entry.captureNames {
            if let range = Range(match.range(withName: name), in: bundleIdentifier) {
                captures[name] = String(bundleIdentifier[range])
            }
        }
        return captures
    }
}

/// `NSRegularExpression` is immutable and documented as safe to share across threads.
private final class RulePattern: @unchecked Sendable {
    let expression: NSRegularExpression

    init?(_ pattern: String) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        self.expression = expression
    }
}

/// Built-in rules plus the user's rule files, reloaded when the files change.
final class UpdateSourceRuleStore: Sendable {
    static let shared = UpdateSourceRuleStore(directory: defaultDirectory)

    static var defaultDirectory: URL {
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Upkeep/UpdateSources", isDirectory: true)
    }

    static let maximumFileSize = 256 * 1024

    let directory: URL
    private let builtIn: UpdateSourceRuleSet
    private let cache = Mutex<(signature: [String], rules: UpdateSourceRuleSet)?>(nil)

    init(directory: URL, builtIn: UpdateSourceRuleSet = .builtIn) {
        self.directory = directory
        self.builtIn = builtIn
    }

    /// User rules come first and replace built-in rules with the same id.
    func current() -> UpdateSourceRuleSet {
        let files = ruleFiles()
        let signature = files.map(\.signature)
        if let cached = cache.withLock({ $0 }), cached.signature == signature {
            return cached.rules
        }
        let rules = builtIn.overlaid(by: Self.load(files.map(\.url)))
        cache.withLock { $0 = (signature, rules) }
        return rules
    }

    /// The user's own rules, without the built-in ones.
    func userRules() -> UpdateSourceRuleSet {
        Self.load(ruleFiles().map(\.url))
    }

    private func ruleFiles() -> [(url: URL, signature: String)] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .contentModificationDateKey, .fileSizeKey,
        ]
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                    values.isRegularFile == true
                else { return nil }
                let modified = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
                return (url, "\(url.lastPathComponent)|\(modified)|\(values.fileSize ?? 0)")
            }
    }

    private static func load(_ urls: [URL]) -> UpdateSourceRuleSet {
        var combined = UpdateSourceRuleSet.empty
        for url in urls.reversed() {
            combined = combined.overlaid(by: load(url))
        }
        return combined
    }

    private static func load(_ url: URL) -> UpdateSourceRuleSet {
        let name = url.lastPathComponent
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumFileSize else {
                throw UpdateSourceRuleError(message: "文件超过 256 KB。")
            }
            let data = try Data(contentsOf: url)
            // A file holds one rule or an array of rules. Decode by its actual shape
            // so errors point at the field that is wrong.
            let decoder = JSONDecoder()
            let rules =
                (try JSONSerialization.jsonObject(with: data)) is [Any]
                ? try decoder.decode([UpdateSourceRule].self, from: data)
                : [try decoder.decode(UpdateSourceRule.self, from: data)]
            return UpdateSourceRuleSet(rules: rules, source: name)
        } catch {
            return UpdateSourceRuleSet(
                rules: [], issues: [Issue(source: name, message: describe(error))])
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return "缺少字段 \(path(context.codingPath + [key]))。"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "字段 \(path(context.codingPath)) 的类型不正确。"
        case DecodingError.dataCorrupted(let context):
            return context.codingPath.isEmpty
                ? "不是有效的 JSON。" : "字段 \(path(context.codingPath)) 的值无效。"
        case let error as NSError where error.domain == NSCocoaErrorDomain && error.code == 3840:
            return "不是有效的 JSON。"
        default:
            return error.localizedDescription
        }
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    }

    private typealias Issue = UpdateSourceRuleSet.Issue
}
