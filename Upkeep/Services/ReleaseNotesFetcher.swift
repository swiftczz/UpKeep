import Foundation

/// Shared URL routing for external release notes; providers retain their inline-note priority.
enum ReleaseNotesFetcher {
  typealias FetchData = @Sendable (URL) async throws -> Data?
  static let maximumBytes = 2_000_000

  static func fetch(
    from releaseURL: URL?, packageURL: URL? = nil,
    fetchData: FetchData = { try await UpdateHTTP.successfulData(from: $0) }
  ) async -> String? {
    guard !Task.isCancelled else { return nil }
    var attemptedAPIURL: URL?
    if let releaseURL, SecureUpdateURL.https(releaseURL) != nil {
      if GitHubReleaseNotes.isGitHubPage(releaseURL) {
        attemptedAPIURL = GitHubReleaseNotes.apiURL(from: releaseURL)
        if let notes = await GitHubReleaseNotes.fetch(from: releaseURL, fetchData: fetchData) {
          return notes
        }
      } else {
        do {
          if let data = try await fetchData(releaseURL), data.count <= maximumBytes,
            let text = String(data: data, encoding: .utf8), !Task.isCancelled {
            let notes = text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
              ? ReleaseNotesHTML.text(text) : text.nonBlankValue
            if let notes { return notes }
          }
        } catch is CancellationError {
          return nil
        } catch {}
      }
    }
    guard !Task.isCancelled, let packageURL,
      let api = GitHubReleaseNotes.apiURL(from: packageURL), api != attemptedAPIURL
    else { return nil }
    return await GitHubReleaseNotes.fetch(from: packageURL, fetchData: fetchData)
  }
}
