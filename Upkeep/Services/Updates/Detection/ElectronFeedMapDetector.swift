import Foundation

/// Recognizes bundled tenant/feedmap JSON modules used by branded Electron apps.
/// Only literal JSON is read; no JavaScript or account configuration is executed.
enum ElectronFeedMapDetector {
    static func detect(in bundleURL: URL) -> ElectronBuilderMetadata? {
        guard let bundleID = Bundle(url: bundleURL)?.bundleIdentifier,
            let archive = ElectronApplicationArchive(bundleURL: bundleURL),
            let package = archive.json(for: "package.json", maximumBytes: 128 * 1024),
            let code = archive.mainCode(in: package, maximumFileBytes: 16 * 1024 * 1024),
            matches(
                #"autoUpdater\.setFeedURL\(\{provider:["']generic["'],url:\w+,channel:\w+\}\)"#,
                in: code
            ).count > 0,
            // This convention explicitly selects prod independently of the API environment.
            matches(#"function\(\)\s*\{\s*return\s+\w+\.\w+\.prod\s*;?\s*\}"#, in: code).count > 0
        else { return nil }

        let mappings = matches(
            #"["']\./([A-Za-z0-9_-]+)/tenant\.json["']\s*:\s*["']?(\d+)["']?"#, in: code)
        var candidates: [ElectronBuilderMetadata] = []
        for mapping in mappings {
            let tenantName = mapping[1]
            guard let tenant = jsonModule(mapping[2], in: code),
                tenant["bundleID"] as? String == bundleID,
                let productName = tenant["productName"] as? String,
                !productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                let feeds = uniqueFeedMap(for: tenantName, in: code),
                let prod = feeds["prod"] as? [String: Any],
                prod["channel"] as? String == "latest",
                let rawURL = prod["url"] as? String,
                let baseURL = SecureUpdateURL.https(string: rawURL),
                baseURL.user == nil, baseURL.password == nil,
                baseURL.query == nil, baseURL.fragment == nil,
                let metadata = ElectronBuilderDetector.metadata(
                    from: "provider: generic\nurl: \(baseURL.absoluteString)\nchannel: latest")
            else { continue }
            candidates.append(
                ElectronBuilderMetadata(
                    identifier: metadata.identifier, feedURL: metadata.feedURL,
                    homepageURL: (package["homepage"] as? String).flatMap(
                        SecureUpdateURL.https(string:))
                        ?? metadata.homepageURL))
        }
        // Ambiguous brands or duplicate module mappings are never guessed.
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func uniqueFeedMap(for tenant: String, in code: String) -> [String: Any]? {
        let mappings = matches(
            #"["']\./"# + NSRegularExpression.escapedPattern(for: tenant)
                + #"/feedmap\.json["']\s*:\s*["']?(\d+)["']?"#, in: code)
        guard mappings.count == 1 else { return nil }
        return jsonModule(mappings[0][1], in: code)
    }

    private static func jsonModule(_ identifier: String, in code: String) -> [String: Any]? {
        // Accept only the webpack wrapper for a JSON module, never a computed export.
        let modules = matches(
            #"(?:^|[,\{])\s{0,128}"# + identifier
                + #"\s*:\s*function\(([A-Za-z_$][A-Za-z0-9_$]*)\)\s*\{\s*["']use strict["'];\s*\1\.exports=JSON\.parse\(('(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*")\)\s*;?\s*\}"#,
            in: code)
        guard modules.count == 1, let json = jsonStringLiteral(modules[0][2]),
            json.utf8.count <= 512 * 1024,
            let data = json.data(using: .utf8)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Normalize the small JavaScript string-literal subset used by JSON modules
    /// into a JSON string. Reject template literals, expressions and other escapes.
    private static func jsonStringLiteral(_ literal: String) -> String? {
        guard let quote = literal.first, literal.last == quote else { return nil }
        var normalized = "\""
        var scalars = literal.dropFirst().dropLast().unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            if scalar == "\\" {
                guard let escaped = scalars.next() else { return nil }
                if escaped == "'", quote == "'" {
                    normalized.append("'")
                } else if "\"\\/bfnrtu".unicodeScalars.contains(escaped) {
                    normalized.append("\\")
                    normalized.unicodeScalars.append(escaped)
                } else {
                    return nil
                }
            } else if scalar == "\"" {
                normalized.append("\\\"")
            } else {
                normalized.unicodeScalars.append(scalar)
            }
        }
        normalized.append("\"")
        return
            (try? JSONSerialization.jsonObject(
                with: Data(normalized.utf8), options: .fragmentsAllowed)) as? String
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
}
