import Foundation

/// Decode path components once and encode repository names and tags consistently.
struct GitHubRepository: Equatable, Sendable {
    let owner: String
    let name: String

    init?(owner: String, name: String) {
        let name = name.replacingOccurrences(
            of: ".git", with: "", options: [.anchored, .backwards])
        guard
            [owner, name].allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && $0.count <= 100 && !$0.contains("/")
            })
        else { return nil }
        self.owner = owner
        self.name = name
    }

    init?(url: URL) {
        let parts = Self.pathComponents(of: url)
        let offset: Int
        if Self.isWebURL(url) {
            offset = 0
        } else if url.host?.lowercased() == "api.github.com", parts.first?.lowercased() == "repos" {
            offset = 1
        } else {
            return nil
        }
        guard parts.count >= offset + 2,
            !Self.reservedOwners.contains(parts[offset].lowercased())
        else { return nil }
        self.init(owner: parts[offset], name: parts[offset + 1])
    }

    var identifier: String { "\(owner)/\(name)" }
    var homepageURL: URL? { webURL(path: []) }

    func apiURL(path: [String]) -> URL? {
        Self.url(host: "api.github.com", path: ["repos", owner, name] + path)
    }

    func webURL(path: [String]) -> URL? {
        Self.url(host: "github.com", path: [owner, name] + path)
    }

    static func isWebURL(_ url: URL) -> Bool {
        ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? "")
    }

    static func pathComponents(of url: URL) -> [String] {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        return path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
    }

    static func release(in url: URL) -> (repository: Self, tag: String, fileName: String?)? {
        let parts = pathComponents(of: url)
        guard SecureUpdateURL.https(url) != nil, isWebURL(url), let repository = Self(url: url),
            parts.count >= 5, parts[2].lowercased() == "releases"
        else { return nil }
        switch parts[3].lowercased() {
        case "tag": return (repository, parts[4...].joined(separator: "/"), nil)
        case "download" where parts.count >= 6:
            return (repository, parts[4..<parts.count - 1].joined(separator: "/"), parts.last)
        default: return nil
        }
    }

    private static func url(host: String, path: [String]) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath =
            "/"
            + path.map {
                $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0
            }.joined(separator: "/")
        return components.url.flatMap(SecureUpdateURL.https)
    }

    private static let reservedOwners: Set<String> = [
        "about", "apps", "collections", "events", "explore", "features", "login", "marketplace",
        "notifications", "orgs", "pricing", "settings", "sponsors", "topics", "users",
    ]
}
