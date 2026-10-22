import Foundation

enum TauriUpdaterDetector {
    private static let latestNeedle = Data("latest.json".utf8)
    private static let tauriNeedles = [
        Data("tauri_plugin_updater".utf8),
        Data("tauri://localhost".utf8),
        Data("__TAURI__".utf8),
        Data("tauri.conf.json".utf8),
    ]

    static func updaterJSONURL(inFile fileURL: URL) -> URL? {
        ExecutableUpdaterDetector.detect(fileURL: fileURL).tauriEndpoint
    }

    static func endpointFromConfiguration(in bundleURL: URL) -> URL? {
        let candidateURLs = [
            bundleURL.appendingPathComponent("Contents/Resources/tauri.conf.json"),
            bundleURL.appendingPathComponent("Contents/Resources/tauri.conf.json5"),
            bundleURL.appendingPathComponent("Contents/tauri.conf.json"),
        ]

        for fileURL in candidateURLs {
            guard
                let data = try? Data(contentsOf: fileURL),
                let json = try? JSONSerialization.jsonObject(with: data)
            else {
                continue
            }
            let endpoints = stringValues(in: json, keys: ["endpoints"])
                .compactMap(validatedUpdaterJSONURL)
            if let endpoint = endpoints.first {
                return endpoint
            }
        }

        return nil
    }

    static func updaterJSONURLs(in window: Data) -> [URL] {
        var urls: [URL] = []
        var searchStart = window.startIndex
        while let range = window[searchStart...].range(of: latestNeedle) {
            if let url = url(endingAt: range, in: window) {
                urls.append(url)
            }
            searchStart = range.upperBound
        }
        return urls
    }

    static func preferredUpdaterJSONURL(_ urls: [URL]) -> URL? {
        // Repository-wide pointers can be documentation strings or belong to another
        // product in a shared repo, so an application-specific manifest wins.
        urls.first(where: isDirectManifestURL) ?? urls.first(where: isRepositoryLatestManifestURL)
    }

    static func isRepositoryLatestManifestURL(_ url: URL) -> Bool {
        guard ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? "") else {
            return false
        }
        let parts = url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
        return parts.count == 6
            && Array(parts.dropFirst(2)) == ["releases", "latest", "download", "latest.json"]
    }

    static func isDirectManifestURL(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name == "latest.json" && !isRepositoryLatestManifestURL(url)
    }

    private static func url(
        endingAt needleRange: Range<Data.Index>,
        in window: Data
    ) -> URL? {
        ExecutableUpdateURL.find(endingAt: needleRange, in: window) { slice in
            String(data: slice, encoding: .utf8).flatMap(validatedUpdaterJSONURL)
        }
    }

    private static func validatedUpdaterJSONURL(_ rawValue: String) -> URL? {
        if rawValue.contains("%s") || rawValue.contains("%d") || rawValue.contains("{{")
            || rawValue.range(
                of: #"(?i)(?:^|[/_-])v?x\.y\.z(?:[/_-]|$)"#, options: .regularExpression)
                != nil
        {
            return nil
        }
        guard
            rawValue.unicodeScalars.allSatisfy({
                ExecutableUpdateURL.allowedCharacters.contains($0)
            })
        else {
            return nil
        }
        guard let url = SecureUpdateURL.https(string: rawValue), isUpdaterJSON(url) else {
            return nil
        }
        return url
    }

    static func hasElectronFramework(in bundleURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent(
                "Contents/Frameworks/Electron Framework.framework"
            ).path
        )
    }

    private static func isUpdaterJSON(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased() == "latest.json"
    }

    static func hasTauriEvidence(in data: Data) -> Bool {
        tauriNeedles.contains { data.range(of: $0) != nil }
    }

    private static func stringValues(in json: Any, keys: Set<String>) -> [String] {
        var results: [String] = []
        var stack: [Any] = [json]

        while let current = stack.popLast() {
            if let dictionary = current as? [String: Any] {
                for (key, value) in dictionary {
                    if keys.contains(key), let strings = value as? [String] {
                        results.append(contentsOf: strings)
                    } else if keys.contains(key), let string = value as? String {
                        results.append(string)
                    } else {
                        stack.append(value)
                    }
                }
            } else if let array = current as? [Any] {
                stack.append(contentsOf: array)
            }
        }

        return results
    }
}
