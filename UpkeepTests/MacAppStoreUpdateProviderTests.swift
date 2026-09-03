import Foundation
import XCTest

@testable import Upkeep

final class MacAppStoreUpdateProviderTests: XCTestCase {
  func testRejectsInstalledIPhoneApplication() async {
    let provider = MacAppStoreUpdateProvider(
      availability: { true },
      startUpdate: { _, _, _, _ in XCTFail("Update session must not start") }
    )
    let application = makeApplication(platform: .iPhone)

    await XCTAssertThrowsErrorAsync(try await provider.upgrade(application) { _ in }) {
      XCTAssertTrue($0.localizedDescription.contains("iPhone 或 iPad"))
    }
  }

  func testRejectsApplicationWithoutStoreIdentifier() async {
    let provider = MacAppStoreUpdateProvider(
      availability: { true },
      startUpdate: { _, _, _, _ in XCTFail("Update session must not start") }
    )
    var application = makeApplication()
    application.sourceIdentifier = nil
    application.sourceURL = nil

    await XCTAssertThrowsErrorAsync(try await provider.upgrade(application) { _ in }) {
      XCTAssertTrue($0.localizedDescription.contains("缺少 App Store 应用编号"))
    }
  }

  func testRejectsUpdateWhenPrivateFrameworksAreUnavailable() async {
    let provider = MacAppStoreUpdateProvider(
      availability: { false },
      startUpdate: { _, _, _, _ in XCTFail("Update session must not start") }
    )

    await XCTAssertThrowsErrorAsync(try await provider.upgrade(makeApplication()) { _ in }) {
      XCTAssertTrue($0.localizedDescription.contains("当前系统不支持"))
    }
  }

  func testSuccessfulUpdatePassesIdentityAndReportsProgress() async throws {
    let recorder = UpdateRecorder()
    let provider = MacAppStoreUpdateProvider(
      availability: { true },
      startUpdate: { adamID, applicationURL, progress, completion in
        recorder.adamID = adamID
        recorder.applicationURL = applicationURL
        progress?(UpdateProgress(fractionCompleted: 0.5, status: "正在下载…"))
        completion(applicationURL.path, nil)
      }
    )

    try await provider.upgrade(makeApplication()) { recorder.progress.append($0) }

    XCTAssertEqual(recorder.adamID, 595_615_424)
    XCTAssertEqual(recorder.applicationURL?.path, "/Applications/QQMusic.app")
    XCTAssertEqual(
      recorder.progress,
      [
        .indeterminate("正在准备更新…"),
        UpdateProgress(fractionCompleted: 0.5, status: "正在下载…"),
        UpdateProgress(fractionCompleted: 1, status: "正在完成…"),
      ]
    )
  }

  func testSessionErrorIsPropagatedWithoutCompletionProgress() async {
    let expected = NSError(
      domain: "test",
      code: 77,
      userInfo: [NSLocalizedDescriptionKey: "purchase failed"]
    )
    let recorder = UpdateRecorder()
    let provider = MacAppStoreUpdateProvider(
      availability: { true },
      startUpdate: { _, _, _, completion in completion(nil, expected) }
    )

    await XCTAssertThrowsErrorAsync(
      try await provider.upgrade(makeApplication()) { recorder.progress.append($0) }
    ) {
      let error = $0 as NSError
      XCTAssertEqual(error.domain, expected.domain)
      XCTAssertEqual(error.code, expected.code)
      XCTAssertEqual(error.localizedDescription, expected.localizedDescription)
    }
    XCTAssertEqual(recorder.progress, [.indeterminate("正在准备更新…")])
  }

  private func makeApplication(
    platform: AppStorePlatform = .mac
  ) -> AppRecord {
    AppRecord(
      name: "QQ音乐",
      bundleIdentifier: "com.tencent.QQMusicMac",
      applicationURL: URL(fileURLWithPath: "/Applications/QQMusic.app"),
      currentVersion: "11.8.1",
      source: .appStore,
      appStorePlatform: platform,
      status: .updateAvailable,
      latestVersion: "11.9.0",
      sourceIdentifier: "595615424"
    )
  }
}

private final class UpdateRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedAdamID: UInt64?
  private var storedApplicationURL: URL?
  private var storedProgress: [UpdateProgress] = []

  var adamID: UInt64? {
    get { lock.withLock { storedAdamID } }
    set { lock.withLock { storedAdamID = newValue } }
  }

  var applicationURL: URL? {
    get { lock.withLock { storedApplicationURL } }
    set { lock.withLock { storedApplicationURL = newValue } }
  }

  var progress: [UpdateProgress] {
    get { lock.withLock { storedProgress } }
    set { lock.withLock { storedProgress = newValue } }
  }
}

private func XCTAssertThrowsErrorAsync(
  _ expression: @autoclosure () async throws -> Void,
  _ errorHandler: (Error) -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    try await expression()
    XCTFail("Expected expression to throw", file: file, line: line)
  } catch {
    errorHandler(error)
  }
}
