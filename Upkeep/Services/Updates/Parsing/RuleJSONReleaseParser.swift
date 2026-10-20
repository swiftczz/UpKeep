import Foundation

/// Reads a JSON update response with the field paths an `UpdateSourceRule` names.
/// Unlike the heuristic parser, it never guesses at other field names.
struct RuleJSONReleaseParser {
    let fields: UpdateSourceRule.Fields

    static let maximumResponseBytes = 5_000_000

    func parse(_ data: Data, sourceURL: URL? = nil) -> ReleaseCandidate? {
        guard data.count <= Self.maximumResponseBytes,
            let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
            let version = first(fields.version, in: root, ReleaseJSONValue.version)
        else { return nil }

        let assets = assetObjects(in: root).compactMap { object, key in
            asset(from: object, key: key, sourceURL: sourceURL)
        }
        return ReleaseCandidate(
            version: version,
            notes: fields.notes.flatMap { first($0, in: root, ReleaseJSONValue.string) },
            publicationDate: fields.date.flatMap { first($0, in: root, ReleaseJSONValue.date) },
            assets: assets,
            releaseURL: fields.notesURL.flatMap {
                first($0, in: root) { ReleaseJSONValue.string($0).flatMap(SecureUpdateURL.https) }
            }
        )
    }

    /// Asset objects with the key they were stored under, if any.
    private func assetObjects(in root: Any) -> [(object: Any, key: String?)] {
        guard let paths = fields.assets else { return [(root, nil)] }
        for path in paths.paths {
            switch JSONPath.value(at: path, in: root) {
            case let array as [Any]:
                return array.map { ($0, nil) }
            case let dictionary as [String: Any]:
                // An object either is one asset or holds assets keyed by name.
                if hasValue(fields.assetURL ?? "url", in: dictionary) {
                    return [(dictionary, nil)]
                }
                return dictionary.keys.sorted().compactMap { key in
                    dictionary[key].map { ($0, key) }
                }
            default:
                continue
            }
        }
        return []
    }

    private func asset(from object: Any, key: String?, sourceURL: URL?) -> ReleaseCandidate.Asset? {
        guard
            let url = first(fields.assetURL ?? "url", in: object, {
                ReleaseJSONValue.string($0).flatMap {
                    ReleaseJSONValue.assetURL($0, relativeTo: sourceURL)
                }
            })
        else { return nil }
        return ReleaseCandidate.Asset(
            name: fields.assetName.flatMap { first($0, in: object, ReleaseJSONValue.string) }
                ?? key ?? url.lastPathComponent,
            url: url,
            sha256: fields.assetSHA256.flatMap { first($0, in: object, ReleaseJSONValue.string) },
            sha512: fields.assetSHA512.flatMap { first($0, in: object, ReleaseJSONValue.string) },
            size: fields.assetSize.flatMap { first($0, in: object, JSONByteCount.parse) }
        )
    }

    private func hasValue(_ paths: PathList, in object: Any) -> Bool {
        paths.paths.contains { JSONPath.value(at: $0, in: object) != nil }
    }

    private func first<Value>(
        _ paths: PathList, in object: Any, _ transform: (Any?) -> Value?
    ) -> Value? {
        for path in paths.paths {
            if let value = transform(JSONPath.value(at: path, in: object)) {
                return value
            }
        }
        return nil
    }
}

/// Dot-separated paths into decoded JSON: `release.assets.0.url`. `$` is the root.
enum JSONPath {
    static func value(at path: String, in root: Any) -> Any? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "$" else { return root }
        var current: Any = root
        for segment in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            if let dictionary = current as? [String: Any], let next = dictionary[String(segment)] {
                current = next
            } else if let array = current as? [Any], let index = Int(segment),
                array.indices.contains(index)
            {
                current = array[index]
            } else {
                return nil
            }
        }
        return current is NSNull ? nil : current
    }
}
