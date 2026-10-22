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

    static func firstEndpoint(in window: Data) -> URL? {
        var searchStart = window.startIndex
        while let range = window[searchStart...].range(of: apiLatestNeedle) {
            if let url = url(endingAt: range, in: window) { return url }
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

    private static func url(endingAt needleRange: Range<Data.Index>, in window: Data) -> URL? {
        ExecutableUpdateURL.find(endingAt: needleRange, in: window) { slice in
            String(data: slice, encoding: .utf8).flatMap(validatedEndpoint)
        }
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
}
