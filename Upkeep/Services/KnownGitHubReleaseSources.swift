import Foundation

/// Verified repository associations for apps that do not embed a release endpoint.
/// Match exact bundle IDs rather than guessing from app names or arbitrary GitHub links.
enum KnownGitHubReleaseSources {
  private static let repositories: [String: String] = [
    "ai.storyteller.photocraft": "storytold/photocraft",
    "ai.storyteller.vectorcraft": "storytold/vectorcraft",
    "ai.storyteller.filmcraft": "storytold/filmcraft",
    "ai.storyteller.lightcraft": "storytold/lightcraft",
    "ai.storyteller.pdfcraft": "storytold/pdfcraft",
    "ai.storyteller.effectcraft": "storytold/effectcraft",
    "ai.storyteller.designcraft": "storytold/designcraft",
    "ai.storyteller.wordcraft": "storytold/wordcraft",
    "ai.storyteller.deckcraft": "storytold/deckcraft",
    "ai.storyteller.gridcraft": "storytold/gridcraft",
    "ai.storyteller.cadcraft": "storytold/cadcraft",
    "ai.storyteller.soundcraft": "storytold/soundcraft",
  ]

  static func metadata(for bundleIdentifier: String) -> GitHubReleasesMetadata? {
    guard let repository = repositories[bundleIdentifier],
      let apiURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest"),
      let homepageURL = URL(string: "https://github.com/\(repository)")
    else {
      return nil
    }
    return GitHubReleasesMetadata(
      identifier: repository,
      apiURL: apiURL,
      homepageURL: homepageURL
    )
  }
}
