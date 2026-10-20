import Foundation

/// Repository naming rules for application families without an embedded release endpoint.
/// These are candidates: the provider must still read a valid release before offering an update.
enum KnownGitHubReleaseSources {
    static func metadata(for bundleIdentifier: String) -> GitHubReleasesMetadata? {
        let prefix = "ai.storyteller."
        guard bundleIdentifier.hasPrefix(prefix) else { return nil }
        let slug = String(bundleIdentifier.dropFirst(prefix.count))
        guard slug.count > "craft".count, slug.count <= 100, slug.hasSuffix("craft"),
            let first = slug.utf8.first, (97...122).contains(first) || (48...57).contains(first),
            slug.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
        else { return nil }

        guard let repository = GitHubRepository(owner: "storytold", name: slug),
            let apiURL = repository.apiURL(path: ["releases", "latest"]),
            let homepageURL = repository.homepageURL
        else { return nil }
        return GitHubReleasesMetadata(
            identifier: repository.identifier, apiURL: apiURL, homepageURL: homepageURL)

    }
}
