import Foundation

enum CustomAPIUpdateDetector {
    private static let latestNeedle = Data("latest.json".utf8)
    private static let apiLatestNeedle = Data("/api/latest".utf8)
    private static let skippedPathComponents: Set<String> = [
        "alpha", "beta", "canary", "dev", "nightly", "preview", "rc",
    ]

    static func endpoint(inFile fileURL: URL) -> URL? {
        ExecutableUpdaterDetector.detect(fileURL: fileURL).customAPIUpdateEndpoint
    }

    static func stableChannelURL(from url: URL) -> URL? {
        var pathComponents = url.path.split(separator: "/").map(String.init)
        guard pathComponents.last?.lowercased() == "latest.json" else {
            return nil
        }

        let directories = pathComponents.dropLast().map { $0.lowercased() }
        if directories.contains("stable")
            || directories.contains(where: { skippedPathComponents.contains($0) })
        {
            return nil
        }

        pathComponents.insert("stable", at: pathComponents.count - 1)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.percentEncodedPath =
            "/" + pathComponents.map(encodePathComponent).joined(separator: "/")
        return components.url.flatMap(SecureUpdateURL.https)
    }

    static func firstEndpoint(in window: Data) -> URL? {
        var searchStart = window.startIndex
        while let range = window[searchStart...].range(of: apiLatestNeedle) {
            if let url = url(endingAt: range, in: window, allowReconstruction: false) { return url }
            searchStart = range.upperBound
        }
        searchStart = window.startIndex
        while let range = window[searchStart...].range(of: latestNeedle) {
            if let url = url(endingAt: range, in: window) {
                return url
            }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func url(
        endingAt needleRange: Range<Data.Index>,
        in window: Data,
        allowReconstruction: Bool = true
    ) -> URL? {
        ExecutableUpdateURL.find(endingAt: needleRange, in: window) { slice in
            if let raw = String(data: slice, encoding: .utf8), let url = validatedEndpoint(raw) {
                return url
            }
            return allowReconstruction ? reconstructedStableEndpoint(from: slice) : nil
        }
    }

    private static func reconstructedStableEndpoint(from slice: Data) -> URL? {
        var ascii = Data()
        for byte in slice {
            guard (32..<127).contains(byte),
                ExecutableUpdateURL.allowedCharacters.contains(UnicodeScalar(byte))
            else {
                break
            }
            ascii.append(byte)
        }

        guard let prefix = String(data: ascii, encoding: .ascii), prefix.hasPrefix("https://")
        else {
            return nil
        }
        let joined =
            prefix.hasSuffix("/")
            ? prefix + "stable/latest.json"
            : prefix + "/stable/latest.json"
        return validatedEndpoint(joined)
    }

    private static func validatedEndpoint(_ rawValue: String) -> URL? {
        if rawValue.contains("%s") || rawValue.contains("%d") || rawValue.contains("{{") {
            return nil
        }
        guard
            rawValue.unicodeScalars.allSatisfy({
                ExecutableUpdateURL.allowedCharacters.contains($0)
            })
        else {
            return nil
        }
        guard let url = SecureUpdateURL.https(string: rawValue),
            url.lastPathComponent.lowercased() == "latest.json" || url.path == "/api/latest",
            url.user == nil, url.password == nil
        else {
            return nil
        }

        let directories = url.path.split(separator: "/").dropLast().map { $0.lowercased() }
        if directories.contains(where: { skippedPathComponents.contains($0) }) {
            return nil
        }
        return url
    }

    static func hasTauriConfiguration(in bundleURL: URL) -> Bool {
        [
            bundleURL.appendingPathComponent("Contents/Resources/tauri.conf.json"),
            bundleURL.appendingPathComponent("Contents/Resources/tauri.conf.json5"),
            bundleURL.appendingPathComponent("Contents/tauri.conf.json"),
        ].contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func encodePathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}
