import XCTest

@testable import Upkeep

final class GitHubRepositoryTests: XCTestCase {
    func testReleaseLinksPreserveSlashAndPercentInTagAcrossConsumers() throws {
        for encodedTag in ["desktop/v1.2.0", "desktop%2Fv1.2.0", "desktop%2Fv1.2.0%252Fpatch"] {
            let tag = try XCTUnwrap(encodedTag.removingPercentEncoding)
            let url = try XCTUnwrap(
                URL(
                    string: "https://github.com/example/app/releases/download/\(encodedTag)/App.dmg"
                ))
            let download = try XCTUnwrap(GitHubReleaseDownload.parse(url))
            XCTAssertEqual(download.tag, tag)
            XCTAssertEqual(download.apiURL, GitHubReleaseNotes.apiURL(from: url))
            let page = try XCTUnwrap(
                GitHubRepository.release(in: url)?.repository.webURL(
                    path: ["releases", "tag", tag]))
            XCTAssertEqual(GitHubReleaseNotes.apiURL(from: page), download.apiURL)
            XCTAssertEqual(GitHubRepository.release(in: page)?.tag, tag)
        }
    }

    func testRepositoryHomepageIsConsistentForAPIWebAndGitSuffix() throws {
        for raw in [
            "https://github.com/example/app.git/releases/latest",
            "https://www.github.com/example/app/releases/tag/v1.0",
            "https://api.github.com/repos/example/app/releases/latest",
        ] {
            let url = try XCTUnwrap(URL(string: raw))
            let repository = try XCTUnwrap(GitHubRepository(url: url))
            XCTAssertEqual(repository.identifier, "example/app")
            XCTAssertEqual(repository.homepageURL?.absoluteString, "https://github.com/example/app")
            XCTAssertEqual(
                TauriHomepage.githubRepositoryHomepage(from: url), repository.homepageURL)
        }
    }

    func testRejectsUnrelatedOrMalformedRepositoryAndReleaseLinks() throws {
        for raw in [
            "https://github.com/login/oauth", "https://example.com/example/app",
            "https://api.github.com/users/example", "https://github.com/example%2Fother/app",
        ] {
            XCTAssertNil(GitHubRepository(url: try XCTUnwrap(URL(string: raw))))
        }
        for raw in [
            "http://github.com/example/app/releases/download/v1.0/App.dmg",
            "https://github.com/example/app/releases/latest",
            "https://github.com/example/app/releases/download/v1.0",
        ] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertNil(GitHubRepository.release(in: url))
            XCTAssertNil(GitHubReleaseDownload.parse(url))
            XCTAssertNil(GitHubReleaseNotes.apiURL(from: url))
        }
    }
}
