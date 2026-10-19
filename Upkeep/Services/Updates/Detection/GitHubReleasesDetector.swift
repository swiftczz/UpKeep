import Foundation

struct GitHubReleasesMetadata: Equatable, Sendable {
    let identifier: String
    let apiURL: URL
    let homepageURL: URL
    var tagPrefix: String? = nil
}

struct GitHubReleaseDownload: Equatable, Sendable {
    let owner: String
    let repository: String
    let tag: String
    let fileName: String

    var cacheKey: String {
        "\(owner)/\(repository)/\(tag)/\(fileName)"
    }

    var apiURL: URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return SecureUpdateURL.https(
            string:
                "https://api.github.com/repos/\(owner)/\(repository)/releases/tags/\(encodedTag)"
        )
    }

    static func parse(_ value: String) -> GitHubReleaseDownload? {
        guard let url = SecureUpdateURL.https(string: value) else {
            return nil
        }
        return parse(url)
    }

    static func parse(_ url: URL) -> GitHubReleaseDownload? {
        guard let host = url.host?.lowercased(),
            host == "github.com" || host == "www.github.com"
        else {
            return nil
        }

        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        let parts = path.split(separator: "/").map {
            String($0).removingPercentEncoding ?? String($0)
        }
        guard parts.count >= 6,
            parts[2].lowercased() == "releases",
            parts[3].lowercased() == "download"
        else {
            return nil
        }

        let owner = parts[0]
        let repository = parts[1].replacingOccurrences(
            of: ".git",
            with: "",
            options: [.anchored, .backwards]
        )
        let tag = parts[4..<parts.count - 1].joined(separator: "/")
        let fileName = parts[parts.count - 1]
        guard !owner.isEmpty, owner != "." && owner != "..",
            !repository.isEmpty, repository != "." && repository != "..",
            !tag.isEmpty, !fileName.isEmpty
        else {
            return nil
        }

        return GitHubReleaseDownload(
            owner: owner,
            repository: repository,
            tag: tag,
            fileName: fileName
        )
    }
}

enum GitHubReleasesDetector {
    private static let githubNeedle = Data("github.com/".utf8)
    private static let expressions = [
        #"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases/latest"#,
        #"https://api\.github\.com/repos/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases/latest"#,
        #"https://api\.github\.com/repos/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases(?!/)"#,
        #"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases/download/([A-Za-z0-9_-]*v)\{version\}/update-(?:darwin|macos)-[A-Za-z0-9_-]+\.json"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func metadata(in data: Data) -> GitHubReleasesMetadata? {
        guard data.range(of: githubNeedle) != nil else { return nil }
        return metadata(in: String(decoding: data, as: UTF8.self))
    }

    static func metadataCandidates(in data: Data) -> [GitHubReleasesMetadata] {
        guard data.range(of: githubNeedle) != nil else { return [] }
        return metadataCandidates(in: String(decoding: data, as: UTF8.self))
    }

    static func metadata(in text: String) -> GitHubReleasesMetadata? {
        metadataCandidates(in: text).first
    }

    static func metadataCandidates(in text: String) -> [GitHubReleasesMetadata] {
        var matches: [(location: Int, metadata: GitHubReleasesMetadata)] = []
        for expression in expressions {
            expression.enumerateMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            ) { match, _, _ in
                guard
                    let match,
                    let ownerRange = Range(match.range(at: 1), in: text),
                    let repositoryRange = Range(match.range(at: 2), in: text)
                else {
                    return
                }

                let owner = String(text[ownerRange])
                let repository = String(text[repositoryRange]).replacingOccurrences(
                    of: ".git",
                    with: "",
                    options: [.anchored, .backwards]
                )
                let prefix =
                    match.numberOfRanges > 3
                    ? Range(match.range(at: 3), in: text).map { String(text[$0]) } : nil
                let endpoint = prefix == nil ? "releases/latest" : "releases?per_page=100"
                guard isRepositoryComponent(owner), isRepositoryComponent(repository),
                    let apiURL = URL(
                        string: "https://api.github.com/repos/\(owner)/\(repository)/\(endpoint)"
                    ),
                    let homepageURL = URL(string: "https://github.com/\(owner)/\(repository)")
                else {
                    return
                }

                matches.append(
                    (
                        match.range.location,
                        GitHubReleasesMetadata(
                            identifier: "\(owner)/\(repository)",
                            apiURL: apiURL,
                            homepageURL: homepageURL,
                            tagPrefix: prefix
                        )
                    )
                )
            }
        }

        var seen = Set<String>()
        return matches.sorted { $0.location < $1.location }.compactMap { match in
            guard
                seen.insert(
                    match.metadata.apiURL.absoluteString + "|" + (match.metadata.tagPrefix ?? "")
                )
                .inserted
            else { return nil }
            return match.metadata
        }
    }

    static func matchesApplication(
        _ metadata: GitHubReleasesMetadata,
        name: String,
        bundleIdentifier: String
    ) -> Bool {
        guard let repository = metadata.identifier.split(separator: "/").last else {
            return false
        }
        var repositoryAliases = aliases(for: String(repository))
        // Some apps publish binaries in a separate <app>-feedback repository.
        // Only remove the explicit suffix; unrelated dependency names must still fail.
        let feedbackSuffix = "-feedback"
        if repository.lowercased().hasSuffix(feedbackSuffix) {
            repositoryAliases.formUnion(
                aliases(for: String(repository.dropLast(feedbackSuffix.count))))
        }
        let applicationValues = [name] + bundleIdentifier.split(separator: ".").map(String.init)
        return applicationValues.contains { value in
            !repositoryAliases.isDisjoint(with: aliases(for: value))
        }
    }

    private static func isRepositoryComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.count <= 100
    }

    private static func aliases(for value: String) -> Set<String> {
        let normalized = value.unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
            .lowercased()
        guard !normalized.isEmpty else { return [] }

        var values: Set<String> = [normalized]
        for suffix in ["desktop", "macos", "mac", "app"]
        where normalized.hasSuffix(suffix) && normalized.count > suffix.count + 2 {
            values.insert(String(normalized.dropLast(suffix.count)))
        }
        return values
    }
}
