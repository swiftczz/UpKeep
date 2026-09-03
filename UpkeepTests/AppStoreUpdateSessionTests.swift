import XCTest
@testable import Upkeep

final class AppStoreUpdateSessionTests: XCTestCase {
  func testIgnoresDownloadEventUntilPurchaseAuthorizationCompletes() {
    XCTAssertFalse(
      AppStoreUpdateSession.downloadEventMatchesSession(
        purchaseHasCompleted: false,
        expectedAdamID: 595_615_424,
        itemIdentifier: 595_615_424
      )
    )
    XCTAssertTrue(
      AppStoreUpdateSession.downloadEventMatchesSession(
        purchaseHasCompleted: true,
        expectedAdamID: 595_615_424,
        itemIdentifier: 595_615_424
      )
    )
    XCTAssertFalse(
      AppStoreUpdateSession.downloadEventMatchesSession(
        purchaseHasCompleted: true,
        expectedAdamID: 595_615_424,
        itemIdentifier: 123
      )
    )
  }

  func testRetainedReceiptKeepsRequiredFileName() {
    let receiptURL = URL(fileURLWithPath: "/private/tmp/download/receipt")

    XCTAssertEqual(
      AppStoreUpdateSession.retainedArtifactFileName(for: receiptURL),
      "receipt"
    )
  }

  func testRetainedPackageKeepsOriginalFileNameAndExtension() {
    let packageURL = URL(fileURLWithPath: "/private/tmp/download/QQMusic.pkg")

    XCTAssertEqual(
      AppStoreUpdateSession.retainedArtifactFileName(for: packageURL),
      "QQMusic.pkg"
    )
  }
}
