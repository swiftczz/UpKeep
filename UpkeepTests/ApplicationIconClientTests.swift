import Foundation
import XCTest

@testable import Upkeep

final class ApplicationIconClientTests: XCTestCase {
    func testLoadsAnIconAtTheDisplayScaleAndCachesIt() async throws {
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Calculator.app is not available")
        }
        let client = ApplicationIconClient.live()
        XCTAssertNil(client.cached(url, 2))

        let loaded = await client.load(url, 2)
        let icon = try XCTUnwrap(loaded)
        XCTAssertEqual(icon.width, 256)
        XCTAssertEqual(icon.height, 256)
        XCTAssertTrue(client.cached(url, 2) === icon)

        let standard = await client.load(url, 1)
        XCTAssertEqual(standard?.width, 128)
    }
}
