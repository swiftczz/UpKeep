import XCTest
@testable import Upkeep

final class GitHubAPIErrorTests: XCTestCase {
  private func error(_ status: Int, headers: [String: String] = [:], message: String = "", host: String = "api.github.com") throws -> GitHubAPIError? {
    let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://\(host)/repos/example/app/releases/latest")!, statusCode: status, httpVersion: nil, headerFields: headers))
    let data = try JSONSerialization.data(withJSONObject: ["message": message])
    return GitHubAPIError.from(response: response, data: data, now: Date(timeIntervalSince1970: 1_000))
  }

  func testPrimaryLimitIncludesReportedIPAndResetTimeWithoutRetrying() throws {
    let value = try XCTUnwrap(error(403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "2000"], message: "API rate limit exceeded for 5.34.218.13. (Details)"))
    XCTAssertTrue(value.localizedDescription.contains("出口 IP：5.34.218.13。"))
    XCTAssertTrue(value.localizedDescription.contains("预计可重试时间"))
    XCTAssertFalse(NetworkRetryPolicy.shouldRetry(value))
  }

  func testSecondaryLimitUsesRetryAfterWithoutInventingIP() throws {
    let value = try XCTUnwrap(error(429, headers: ["Retry-After": "120"]))
    XCTAssertTrue(value.localizedDescription.contains("预计可重试时间"))
    XCTAssertFalse(value.localizedDescription.contains("当前请求出口 IP"))
  }

  func testMessageIdentifiesSecondary403Limit() throws {
    XCTAssertTrue(try XCTUnwrap(error(403, message: "You have exceeded a secondary rate limit.")).localizedDescription.contains("已被限流"))
  }

  func testOrdinaryForbiddenIsNotCalledRateLimiting() throws {
    XCTAssertNil(try error(403, message: "Resource not accessible"))
  }

  func testInvalidOrExpiredResetDoesNotInventRecoveryTime() throws {
    for reset in ["invalid", "nan", "900"] {
      let value = try XCTUnwrap(error(403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": reset]))
      XCTAssertFalse(value.localizedDescription.contains("预计可重试时间"))
    }
  }

  func testOtherHostsAndSuccessfulResponsesAreUnaffected() throws {
    XCTAssertNil(try error(429, host: "example.com"))
    XCTAssertNil(try error(200))
  }
}
