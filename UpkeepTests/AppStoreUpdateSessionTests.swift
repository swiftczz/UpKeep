import XCTest
@testable import Upkeep

final class AppStoreUpdateSessionTests: XCTestCase {
  func testIgnoresDownloadEventUntilPurchaseAuthorizationCompletes() {
    var gate = AppStorePurchaseGate()

    XCTAssertFalse(
      gate.matches(expectedAdamID: 595_615_424, itemIdentifier: 595_615_424)
    )
    XCTAssertTrue(gate.completePurchase(downloadCount: 1))
    XCTAssertTrue(
      gate.matches(expectedAdamID: 595_615_424, itemIdentifier: 595_615_424)
    )
    XCTAssertFalse(gate.matches(expectedAdamID: 595_615_424, itemIdentifier: 123))
  }

  func testEmptyPurchaseResponseDoesNotAuthorizeDownloadEvents() {
    var gate = AppStorePurchaseGate()

    XCTAssertFalse(gate.completePurchase(downloadCount: 0))
    XCTAssertFalse(gate.purchaseHasCompleted)
    XCTAssertFalse(gate.matches(expectedAdamID: 123, itemIdentifier: 123))
  }

  func testStartingAnotherPurchaseResetsDownloadAuthorization() {
    var gate = AppStorePurchaseGate()
    XCTAssertTrue(gate.completePurchase(downloadCount: 2))

    gate.reset()

    XCTAssertFalse(gate.purchaseHasCompleted)
    XCTAssertFalse(gate.matches(expectedAdamID: 123, itemIdentifier: 123))
  }

  func testInstallErrorUsesRetainedPackageFallbackWhenArtifactsExist() {
    let error = NSError(domain: "PKInstallErrorDomain", code: 201)

    let disposition = AppStoreUpdateSession.downloadCompletionDisposition(
      error: error,
      failed: true,
      cancelled: false,
      installedPath: nil,
      canFallbackInstall: true
    )

    guard case .fallbackInstall = disposition else {
      return XCTFail("Expected privileged installer fallback")
    }
  }

  func testInstallErrorIsPreservedWhenFallbackArtifactsAreMissing() {
    let expected = NSError(domain: "PKInstallErrorDomain", code: 201)

    let disposition = AppStoreUpdateSession.downloadCompletionDisposition(
      error: expected,
      failed: false,
      cancelled: false,
      installedPath: nil,
      canFallbackInstall: false
    )

    guard case .complete(let path, let error) = disposition else {
      return XCTFail("Expected ordinary completion")
    }
    XCTAssertNil(path)
    XCTAssertTrue(error === expected)
  }

  func testFailedAndCancelledDownloadsProduceActionableErrors() {
    let failed = AppStoreUpdateSession.downloadCompletionDisposition(
      error: nil,
      failed: true,
      cancelled: false,
      installedPath: nil,
      canFallbackInstall: false
    )
    let cancelled = AppStoreUpdateSession.downloadCompletionDisposition(
      error: nil,
      failed: false,
      cancelled: true,
      installedPath: nil,
      canFallbackInstall: false
    )

    guard case .complete(_, let failedError) = failed,
      case .complete(_, let cancelledError) = cancelled
    else {
      return XCTFail("Expected failed completions")
    }
    XCTAssertEqual(failedError?.localizedDescription, "App Store 下载更新失败。")
    XCTAssertEqual(cancelledError?.localizedDescription, "App Store 更新已取消。")
  }

  func testSuccessfulDownloadKeepsInstalledPath() {
    let disposition = AppStoreUpdateSession.downloadCompletionDisposition(
      error: nil,
      failed: false,
      cancelled: false,
      installedPath: "/Applications/QQMusic.app",
      canFallbackInstall: false
    )

    guard case .complete(let path, let error) = disposition else {
      return XCTFail("Expected successful completion")
    }
    XCTAssertEqual(path, "/Applications/QQMusic.app")
    XCTAssertNil(error)
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
