import Foundation

/// The latest release a JSON update endpoint describes, independent of how its
/// fields were named. Parsers produce it; selection and installation consume it.
struct ReleaseCandidate: Equatable, Sendable {
    struct Asset: Equatable, Sendable {
        let name: String
        let url: URL
        let sha256: String?
        let sha512: String?
        let size: Int64?
    }

    var version: String
    var notes: String?
    var publicationDate: Date?
    var assets: [Asset]
    var releaseURL: URL? = nil

    func selectedPackage(architecture: MacCPUArchitecture = .current) -> Asset? {
        let ranked = assets.compactMap { asset -> (Int, Asset)? in
            let fileName = asset.name.nonBlankValue ?? asset.url.lastPathComponent
            let kindScore = ApplicationPackageInstaller.packageKindScore(of: fileName)
            guard kindScore > 0 else {
                return nil
            }
            let architectureScore = ApplicationPackageInstaller.architectureScore(
                of: fileName,
                architecture: architecture
            )
            let platformScore = Self.macPlatformScore(of: fileName)
            let tokens = fileName.lowercased().split { !$0.isLetter && !$0.isNumber }
            guard architectureScore > 0, platformScore > 0,
                !tokens.contains(where: {
                    ["cli", "server", "web", "chrome", "firefox", "extension", "android", "ios"]
                        .contains($0)
                })
            else { return nil }
            return (platformScore * 1_000 + architectureScore * 10 + kindScore, asset)
        }

        return ranked.max(by: { $0.0 < $1.0 })?.1
    }

    private static func macPlatformScore(of fileName: String) -> Int {
        let name = fileName.lowercased()
        if name.contains("macos") || name.contains("darwin") || name.contains("osx") {
            return 50
        }
        if name.contains("windows") || name.contains("win32") || name.contains("win64")
            || name.contains("linux")
        {
            return 0
        }
        return 10
    }
}

/// Value conversions shared by the JSON release parsers.
enum ReleaseJSONValue {
    static func version(_ value: Any?) -> String? {
        guard var version = string(value) else { return nil }
        if version.hasPrefix("v") || version.hasPrefix("V") {
            version = String(version.dropFirst())
        }
        return version.nonBlankValue
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            return text.trimmingCharacters(in: .whitespacesAndNewlines).nonBlankValue
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            return number.stringValue
        default:
            return nil
        }
    }

    static func date(_ value: Any?) -> Date? {
        if let text = value as? String {
            return ISO8601Parsing.date(from: text)
        }
        return epochDate(value)
    }

    static func epochDate(_ value: Any?) -> Date? {
        let number = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        guard let number, number.isFinite, number > 0 else { return nil }
        return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
    }

    /// Absolute HTTPS URLs, or a path on the endpoint's own host. Credentials and
    /// protocol-relative URLs are rejected.
    static func assetURL(_ raw: String, relativeTo sourceURL: URL?) -> URL? {
        let url: URL?
        if raw.hasPrefix("/"), !raw.hasPrefix("//"), let sourceURL,
            let relative = URL(string: raw, relativeTo: sourceURL),
            relative.absoluteURL.host == sourceURL.host
        {
            url = SecureUpdateURL.https(relative.absoluteURL)
        } else {
            url = SecureUpdateURL.https(string: raw)
        }
        guard let url, url.user == nil, url.password == nil else { return nil }
        return url
    }
}
