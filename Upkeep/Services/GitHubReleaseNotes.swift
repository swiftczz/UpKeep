import Foundation

/// Source-independent GitHub notes. Version/asset eligibility stays with each updater.
enum GitHubReleaseNotes {
  static func isGitHubPage(_ url: URL) -> Bool {
    ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? "")
  }

  static func fetch(from url: URL, fetchData: ReleaseNotesFetcher.FetchData) async -> String? {
    guard !Task.isCancelled, SecureUpdateURL.https(url) != nil,
      let api = apiURL(from: url), let page = releasePageURL(from: url)
    else { return nil }

    do {
      if let data = try await fetchData(api), data.count <= ReleaseNotesFetcher.maximumBytes,
        let notes = parseAPIResponse(data), !Task.isCancelled {
        return notes
      }
    } catch is CancellationError {
      return nil
    } catch {
      // API rate limits and transient failures may still leave the public page available.
    }
    guard !Task.isCancelled else { return nil }
    do {
      guard let data = try await fetchData(page), data.count <= ReleaseNotesFetcher.maximumBytes,
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
    guard apiURL(from: url) != nil else { return nil }
    let parts = pathParts(of: url)
    guard parts[3].lowercased() == "download" else { return url }
    // A package URL must fall back to its release page, never download the asset as HTML.
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    let path = [parts[0], parts[1], "releases", "tag", parts[4]]
      .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
      .joined(separator: "/")
    return URL(string: "https://github.com/" + path)
  }

  private static func pathParts(of url: URL) -> [String] {
    // Decode each component once, preserving encoded slashes inside release tags.
    let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
    return path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
  }

  static func apiURL(from releaseURL: URL) -> URL? {
    guard SecureUpdateURL.https(releaseURL) != nil, let host = releaseURL.host?.lowercased(),
      host == "github.com" || host == "www.github.com"
    else {
      return nil
    }

    let components = pathParts(of: releaseURL)
    guard components.count >= 5, components[2].lowercased() == "releases" else {
      return nil
    }

    let owner = components[0]
    let repository = components[1]
    let tag: String
    switch components[3].lowercased() {
    case "tag":
      tag = components[4...].joined(separator: "/")
    case "download":
      tag = components[4]
    default:
      return nil
    }

    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    guard
      let encodedOwner = owner.addingPercentEncoding(withAllowedCharacters: allowed),
      let encodedRepository = repository.addingPercentEncoding(withAllowedCharacters: allowed),
      let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: allowed),
      let url = URL(
        string:
          "https://api.github.com/repos/\(encodedOwner)/\(encodedRepository)/releases/tags/\(encodedTag)"
      )
    else {
      return nil
    }
    return url
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
