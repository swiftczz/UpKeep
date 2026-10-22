import Foundation

/// Reads the JSON shapes seen across vendors' update endpoints by trying every
/// known field name. Prefer an `UpdateSourceRule` for a new format: a rule names
/// its fields explicitly, so one vendor's change cannot alter another's parsing.
enum HeuristicJSONReleaseParser {
    static func parse(
        _ data: Data,
        languageCode: String = Locale.current.language.languageCode?.identifier ?? "en"
    ) -> ReleaseCandidate? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = normalizedVersion(json["version"] as? String)
        else {
            return nil
        }

        let rawAssets: [[String: Any]]
        if let array = json["assets"] as? [[String: Any]] {
            rawAssets = array
        } else if let dictionary = json["assets"] as? [String: Any] {
            rawAssets = dictionary.keys.sorted().compactMap { key in
                guard var asset = dictionary[key] as? [String: Any] else { return nil }
                if asset["name"] == nil { asset["name"] = key }
                return asset
            }
        } else {
            return nil
        }
        let assets = rawAssets.compactMap { raw -> ReleaseCandidate.Asset? in
            let name = (raw["name"] as? String)?.nonBlankValue
            guard let rawURL = (raw["url"] as? String)?.nonBlankValue ?? name,
                let url = SecureUpdateURL.https(string: rawURL),
                url.user == nil, url.password == nil
            else { return nil }
            return ReleaseCandidate.Asset(
                name: name ?? url.lastPathComponent, url: url,
                sha256: (raw["sha256"] as? String)?.nonBlankValue,
                sha512: (raw["sha512"] as? String)?.nonBlankValue,
                size: JSONByteCount.parse(raw["size"]))
        }

        guard !assets.isEmpty else {
            return nil
        }

        return ReleaseCandidate(
            version: version,
            notes: localizedNotes(json, languageCode: languageCode),
            publicationDate: date(from: json["published_at"]) ?? date(from: json["created_at"])
                ?? date(from: json["pub_date"]) ?? date(from: json["published"]),
            assets: assets,
            releaseURL: (json["releaseNotesUrl"] as? String ?? json["release_notes_url"] as? String
                ?? json["html_url"] as? String ?? json["url"] as? String)
                .flatMap(SecureUpdateURL.https(string:))
        )
    }

    static func localizedNotes(
        _ json: [String: Any],
        languageCode: String
    ) -> String? {
        if let notes = (json["notes"] as? String)?.nonBlankValue {
            return notes
        }
        if let notes = (json["releaseNotes"] as? String)?.nonBlankValue { return notes }
        if let notes = (json["release_notes"] as? String)?.nonBlankValue {
            return notes
        }
        guard let values = json["release_notes"] as? [String: String] else {
            return nil
        }

        let prefersChinese = languageCode.lowercased().hasPrefix("zh")
        let keys =
            prefersChinese
            ? ["zh-CN", "zh-Hans", "zh", "zh-HK", "zh-Hant", "en"]
            : ["en", "zh-CN", "zh"]
        for key in keys {
            if let notes = values[key]?.nonBlankValue {
                return notes
            }
        }
        return values.values.compactMap(\.nonBlankValue).first
    }

    private static func normalizedVersion(_ value: String?) -> String? {
        guard var version = value?.nonBlankValue else {
            return nil
        }
        if version.hasPrefix("v") || version.hasPrefix("V") {
            version = String(version.dropFirst())
        }
        return version.nonBlankValue
    }

    private static func date(from value: Any?) -> Date? {
        guard let text = value as? String else {
            return nil
        }
        return ISO8601Parsing.date(from: text)
    }
}
