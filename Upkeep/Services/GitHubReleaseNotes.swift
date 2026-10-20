import Foundation

/// Source-independent GitHub notes. Version/asset eligibility stays with each updater.
enum GitHubReleaseNotes {
    static func isGitHubPage(_ url: URL) -> Bool {
        GitHubRepository.isWebURL(url)
    }

    static func fetch(from url: URL, fetchData: ReleaseNotesFetcher.FetchData) async -> String? {
        guard !Task.isCancelled, SecureUpdateURL.https(url) != nil,
            let api = apiURL(from: url), let page = releasePageURL(from: url)
        else { return nil }

        do {
            if let data = try await fetchData(api), data.count <= ReleaseNotesFetcher.maximumBytes,
                let notes = parseAPIResponse(data), !Task.isCancelled
            {
                return notes
            }
        } catch is CancellationError {
            return nil
        } catch {
            // API rate limits and transient failures may still leave the public page available.
        }
        guard !Task.isCancelled else { return nil }
        do {
            guard let data = try await fetchData(page),
                data.count <= ReleaseNotesFetcher.maximumBytes,
                let html = String(data: data, encoding: .utf8), !Task.isCancelled
            else { return nil }
            return ReleaseNotesHTML.githubReleaseText(html)
        } catch {
            return nil
        }
    }

    static func body(in json: [String: Any]) -> String? {
        (json["body"] as? String)?.nonBlankValue
    }

    private static func releasePageURL(from url: URL) -> URL? {
        guard let release = GitHubRepository.release(in: url) else { return nil }
        // Preserve the original page host, but never fetch an asset as HTML.
        return release.fileName == nil
            ? url
            : release.repository.webURL(path: ["releases", "tag", release.tag])
    }

    static func apiURL(from releaseURL: URL) -> URL? {
        guard let release = GitHubRepository.release(in: releaseURL) else { return nil }
        return release.repository.apiURL(path: ["releases", "tags", release.tag])
    }

    static func parseAPIResponse(_ data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return body(in: json)
    }
}
