import Foundation
import XCTest

@testable import AppMint

final class UpdateHTTPTests: XCTestCase {
  func testUpdateRequestIgnoresCachedManifests() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/appcast.xml"))

    let request = UpdateHTTP.request(for: url)

    XCTAssertEqual(request.url, url)
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertEqual(request.timeoutInterval, 20)
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "AppMint")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache")

    let configuration = UpdateHTTP.sessionConfiguration()
    XCTAssertTrue(configuration.waitsForConnectivity)
    XCTAssertEqual(configuration.httpMaximumConnectionsPerHost, 4)
    XCTAssertEqual(configuration.timeoutIntervalForRequest, 20)
    XCTAssertEqual(configuration.timeoutIntervalForResource, 45)
    XCTAssertNil(configuration.urlCache)
  }

  func testGitHubMetadataRequestUsesVersionedJSONAPI() throws {
    let url = try XCTUnwrap(
      URL(string: "https://api.github.com/repos/l0ng-ai/tty7/releases/latest")
    )

    let request = UpdateHTTP.request(for: url)

    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
  }

  func testPackageDownloadDisablesClientAndProtocolCaches() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/App.zip"))

    let request = ApplicationPackageInstaller.downloadRequest(for: url)
    let configuration = ApplicationPackageInstaller.downloadSessionConfiguration()

    XCTAssertEqual(request.url, url)
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertEqual(request.timeoutInterval, 60)
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "AppMint")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache, no-store")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Pragma"), "no-cache")
    XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertTrue(configuration.waitsForConnectivity)
    XCTAssertEqual(configuration.httpMaximumConnectionsPerHost, 4)
    XCTAssertEqual(configuration.timeoutIntervalForRequest, 60)
    XCTAssertEqual(configuration.timeoutIntervalForResource, 30 * 60)
    XCTAssertNil(configuration.urlCache)
  }

  func testGitHubReleaseAssetRequestDownloadsBinaryAndUsesResponseFileName() throws {
    let url = try XCTUnwrap(
      URL(string: "https://api.github.com/repos/readest/readest/releases/assets/534295058")
    )

    let request = ApplicationPackageInstaller.downloadRequest(for: url)

    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/octet-stream")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
    XCTAssertEqual(
      ApplicationPackageInstaller.supportedPackageFileName(
        suggestedFilename: "Readest_0.12.6_universal.app.tar.gz",
        sourceURL: url
      ),
      "Readest_0.12.6_universal.app.tar.gz"
    )
  }

  func testRejectsUnsupportedSuggestedPackageFileName() throws {
    let url = try XCTUnwrap(
      URL(string: "https://api.github.com/repos/example/app/releases/assets/123")
    )

    XCTAssertNil(
      ApplicationPackageInstaller.supportedPackageFileName(
        suggestedFilename: "metadata.json",
        sourceURL: url
      )
    )
  }

  func testRetriesTransientTLSFailureButNotCertificateFailure() {
    XCTAssertTrue(NetworkRetryPolicy.shouldRetry(URLError(.secureConnectionFailed)))
    XCTAssertFalse(NetworkRetryPolicy.shouldRetry(URLError(.serverCertificateHasBadDate)))
    XCTAssertFalse(NetworkRetryPolicy.shouldRetry(URLError(.serverCertificateUntrusted)))
    XCTAssertFalse(NetworkRetryPolicy.shouldRetry(CancellationError()))
  }

  func testRetriesTemporaryHTTPResponses() {
    for statusCode in [408, 425, 429, 500, 502, 503, 504] {
      XCTAssertTrue(NetworkRetryPolicy.isRetryableHTTPStatus(statusCode))
      XCTAssertTrue(
        NetworkRetryPolicy.shouldRetry(
          UpdateHTTPError.statusCode(statusCode, retryAfter: nil)
        )
      )
    }

    for statusCode in [400, 401, 403, 404, 422] {
      XCTAssertFalse(NetworkRetryPolicy.isRetryableHTTPStatus(statusCode))
    }
  }

  func testRetryDelayUsesBoundedJitter() {
    XCTAssertEqual(
      NetworkRetryPolicy.retryDelay(afterAttempt: 0, jitter: -0.2),
      0.64,
      accuracy: 0.001
    )
    XCTAssertEqual(
      NetworkRetryPolicy.retryDelay(afterAttempt: 1, jitter: 0),
      2,
      accuracy: 0.001
    )
    XCTAssertEqual(
      NetworkRetryPolicy.retryDelay(afterAttempt: 2, jitter: 0.2),
      6,
      accuracy: 0.001
    )
  }

  func testRetryAfterHeaderOverridesBackoffAndIsCapped() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/update.zip"))
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: url,
        statusCode: 503,
        httpVersion: "HTTP/2",
        headerFields: ["Retry-After": "45"]
      )
    )

    XCTAssertEqual(NetworkRetryPolicy.retryAfterDelay(from: response), 30)
  }

  func testTLSFailureGetsActionableMessageAfterRetries() {
    let error = NetworkRetryPolicy.presentableError(
      URLError(.secureConnectionFailed),
      attempts: NetworkRetryPolicy.downloadAttempts
    )

    XCTAssertEqual(
      error.localizedDescription,
      "TLS 连接被更新服务器或网络代理中断，已尝试 4 次。"
    )
  }
}
