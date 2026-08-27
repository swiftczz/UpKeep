import Foundation
import XCTest

@testable import AppMint

final class UpdateHTTPTests: XCTestCase {
  func testUpdateRequestIgnoresCachedManifests() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/appcast.xml"))

    let request = UpdateHTTP.request(for: url)

    XCTAssertEqual(request.url, url)
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertEqual(request.timeoutInterval, 15)
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "AppMint")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache")
  }

  func testPackageDownloadDisablesClientAndProtocolCaches() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/App.zip"))

    let request = ApplicationPackageInstaller.downloadRequest(for: url)
    let configuration = ApplicationPackageInstaller.downloadSessionConfiguration()

    XCTAssertEqual(request.url, url)
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "AppMint")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache, no-store")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Pragma"), "no-cache")
    XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertNil(configuration.urlCache)
  }
}
