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

  func testSuccessfulInstallRegistersItsReportedPathWithLaunchServices() {
    let registrationURL = AppStoreUpdateSession.launchServicesRegistrationURL(
      installedPath: "/Applications/iQIYI.app",
      applicationURL: URL(fileURLWithPath: "/Applications/Old iQIYI.app"),
      error: nil
    )

    XCTAssertEqual(registrationURL?.path, "/Applications/iQIYI.app")
  }

  func testSuccessfulInstallFallsBackToOriginalApplicationPathForRegistration() {
    let applicationURL = URL(fileURLWithPath: "/Applications/iQIYI.app")

    let registrationURL = AppStoreUpdateSession.launchServicesRegistrationURL(
      installedPath: nil,
      applicationURL: applicationURL,
      error: nil
    )

    XCTAssertEqual(registrationURL, applicationURL)
  }

  func testFailedInstallIsNotRegisteredWithLaunchServices() {
    let registrationURL = AppStoreUpdateSession.launchServicesRegistrationURL(
      installedPath: "/Applications/iQIYI.app",
      applicationURL: URL(fileURLWithPath: "/Applications/iQIYI.app"),
      error: NSError(domain: "test", code: 1)
    )

    XCTAssertNil(registrationURL)
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
  func testDownloadProgressUsesDownloadPhase() {
    var lifecycle = AppStoreDownloadLifecycle()
    XCTAssertEqual(
      lifecycle.progress(phase: "Downloading", fractionCompleted: 0.4),
      UpdateProgress(fractionCompleted: 0.4, status: "正在下载…")
    )
    XCTAssertEqual(
      lifecycle.progress(phase: "Downloading", fractionCompleted: 1),
      .indeterminate("下载完成，等待安装…")
    )
  }

  func testInstallProgressDoesNotRegressToLateDownloadProgress() {
    var lifecycle = AppStoreDownloadLifecycle()
    XCTAssertEqual(
      lifecycle.progress(phase: "Installing", fractionCompleted: 0.2),
      .indeterminate("正在安装…")
    )
    XCTAssertEqual(
      lifecycle.progress(phase: "Downloading", fractionCompleted: 1),
      .indeterminate("正在安装…")
    )
  }

  func testUnknownPhaseDoesNotDisplayMisleadingDownloadPercentage() {
    var lifecycle = AppStoreDownloadLifecycle()
    XCTAssertEqual(
      lifecycle.progress(phase: nil, fractionCompleted: 1),
      .indeterminate("正在处理更新…")
    )
    XCTAssertEqual(
      lifecycle.progress(phase: "Verifying", fractionCompleted: 1),
      .indeterminate("正在验证更新…")
    )
  }

  func testUnknownPhasePreservesAvailableProgress() {
    for phase: String? in [nil, "", "Transfer"] {
      var lifecycle = AppStoreDownloadLifecycle()
      XCTAssertEqual(
        lifecycle.progress(phase: phase, fractionCompleted: 0.42),
        UpdateProgress(fractionCompleted: 0.42, status: "正在处理更新…")
      )
      for unavailable: Double? in [nil, .nan, .infinity, 1] {
        XCTAssertEqual(
          lifecycle.progress(phase: phase, fractionCompleted: unavailable),
          .indeterminate("正在处理更新…")
        )
      }
    }
  }

  func testFallbackInstallIgnoresLateDownloadAndRemovalEvents() {
    var lifecycle = AppStoreDownloadLifecycle()
    XCTAssertTrue(lifecycle.beginFallbackInstall())
    XCTAssertFalse(lifecycle.acceptsDownloadEvents)
    XCTAssertNil(lifecycle.progress(phase: "Downloading", fractionCompleted: 1))
    XCTAssertFalse(lifecycle.beginFallbackInstall())
    lifecycle.finish()
    XCTAssertFalse(lifecycle.acceptsDownloadEvents)
    XCTAssertNil(lifecycle.progress(phase: "Installing", fractionCompleted: 1))
  }

  func testCompletedSessionCannotStartAnotherFallbackInstall() {
    var lifecycle = AppStoreDownloadLifecycle()
    lifecycle.finish()
    XCTAssertFalse(lifecycle.beginFallbackInstall())
    XCTAssertFalse(lifecycle.acceptsDownloadEvents)
  }

}
