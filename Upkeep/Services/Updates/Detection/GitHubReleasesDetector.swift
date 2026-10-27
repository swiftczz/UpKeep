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

    var apiURL: URL? {
        GitHubRepository(owner: owner, name: repository)?.apiURL(path: ["releases", "tags", tag])
    }

    static func parse(_ value: String) -> GitHubReleaseDownload? {
        guard let url = SecureUpdateURL.https(string: value) else {
            return nil
        }
        return parse(url)
    }

    static func parse(_ url: URL) -> GitHubReleaseDownload? {
        guard let release = GitHubRepository.release(in: url), let fileName = release.fileName
        else {
            return nil
        }
        return GitHubReleaseDownload(
            owner: release.repository.owner, repository: release.repository.name,
            tag: release.tag, fileName: fileName)
    }

}

enum GitHubReleasesDetector {
    private static let githubNeedle = Data("github.com/".utf8)
    private static let expressions = [
        #"https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases/latest"#,
        #"https://api\.github\.com/repos/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases/latest"#,
        #"https://api\.github\.com/repos/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases(?!/)"#,
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
                let repository = String(text[repositoryRange])
                guard let repository = GitHubRepository(owner: owner, name: repository),
                    let homepageURL = repository.homepageURL,
                    let apiURL = repository.apiURL(path: ["releases", "latest"])
                else { return }

                matches.append(
                    (
                        match.range.location,
                        GitHubReleasesMetadata(
                            identifier: repository.identifier,
                            apiURL: apiURL,
                            homepageURL: homepageURL
                        )
                    )
                )
            }
        }

        var seen = Set<String>()
        return matches.sorted { $0.location < $1.location }.compactMap { match in
            guard seen.insert(match.metadata.apiURL.absoluteString).inserted else { return nil }
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
        let bundleParts = bundleIdentifier.split(separator: ".").map(String.init)
        let applicationValues = [name] + bundleParts
        if applicationValues.contains(where: {
            !repositoryAliases.isDisjoint(with: aliases(for: $0))
        }) {
            return true
        }
        return ownerReleasesProduct(metadata, bundleParts: bundleParts)
    }

    /// A developer's own repository named after the product, such as
    /// egoist/mygo-cloudmusic for dev.egoist.cloudmusic. Both the owner and a product
    /// part must appear, so a dependency's repository is not mistaken for the app.
    private static func ownerReleasesProduct(
        _ metadata: GitHubReleasesMetadata, bundleParts: [String]
    ) -> Bool {
        let parts = metadata.identifier.split(separator: "/").map { normalized(String($0)) }
        let bundleParts = bundleParts.map(normalized)
        guard parts.count == 2, bundleParts.contains(parts[0]) else { return false }
        return bundleParts.contains { part in
            part != parts[0] && part.count >= 4 && !genericBundleParts.contains(part)
                && parts[1].contains(part)
        }
    }

    private static let genericBundleParts: Set<String> = [
        "apple", "client", "desktop", "macos", "helper", "mobile", "release",
    ]

    private static func normalized(_ value: String) -> String {
        value.unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
            .lowercased()
    }

    private static func aliases(for value: String) -> Set<String> {
        let normalized = normalized(value)
        guard !normalized.isEmpty else { return [] }

        var values: Set<String> = [normalized]
        for suffix in ["desktop", "macos", "mac", "app"]
        where normalized.hasSuffix(suffix) && normalized.count > suffix.count + 2 {
            values.insert(String(normalized.dropLast(suffix.count)))
        }
        return values
    }
}
