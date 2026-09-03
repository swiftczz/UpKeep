import Foundation
import XCTest

@testable import Upkeep

final class AppStorePrivilegedInstallerTests: XCTestCase {
  func testRegistrationIsUnavailableWithoutBundledHelper() {
    let state = RegistrationState(status: .disabled)

    let result = AppStorePrivilegedInstaller.registerBundledHelper(
      using: state.dependencies(helperExists: false)
    )

    guard case .unavailable = result else {
      return XCTFail("Expected unavailable registration result")
    }
    XCTAssertEqual(state.registerCallCount, 0)
  }

  func testRegistersBundledHelperAndPersistsFingerprint() {
    let state = RegistrationState(status: .disabled)

    let result = AppStorePrivilegedInstaller.registerBundledHelper(
      using: state.dependencies()
    )

    guard case .enabled = result else {
      return XCTFail("Expected enabled registration result")
    }
    XCTAssertEqual(state.registerCallCount, 1)
    XCTAssertEqual(state.unregisterCallCount, 0)
    XCTAssertEqual(state.registeredFingerprint, "new-fingerprint")
  }

  func testKeepsEnabledHelperWhenFingerprintIsUnchanged() {
    let state = RegistrationState(
      status: .enabled,
      registeredFingerprint: "new-fingerprint"
    )

    let result = AppStorePrivilegedInstaller.registerBundledHelper(
      using: state.dependencies()
    )

    guard case .enabled = result else {
      return XCTFail("Expected enabled registration result")
    }
    XCTAssertEqual(state.registerCallCount, 0)
    XCTAssertEqual(state.unregisterCallCount, 0)
  }

  func testReRegistersEnabledHelperWhenFingerprintChanges() {
    let state = RegistrationState(
      status: .enabled,
      registeredFingerprint: "old-fingerprint"
    )

    let result = AppStorePrivilegedInstaller.registerBundledHelper(
      using: state.dependencies()
    )

    guard case .enabled = result else {
      return XCTFail("Expected enabled registration result")
    }
    XCTAssertEqual(state.unregisterCallCount, 1)
    XCTAssertEqual(state.registerCallCount, 1)
    XCTAssertEqual(state.registeredFingerprint, "new-fingerprint")
  }

  func testReportsSystemApprovalRequirement() {
    let state = RegistrationState(status: .requiresApproval)

    let result = AppStorePrivilegedInstaller.registerBundledHelper(
      using: state.dependencies()
    )

    let error = try? XCTUnwrap(result.error)
    XCTAssertEqual(error?.code, 5)
    XCTAssertTrue(error?.localizedDescription.contains("后台项目") == true)
    XCTAssertEqual(state.registeredFingerprint, "new-fingerprint")
    XCTAssertEqual(state.registerCallCount, 0)
  }

  func testReportsUnregisterFailureDuringHelperReplacement() {
    let expected = NSError(
      domain: "test",
      code: 91,
      userInfo: [NSLocalizedDescriptionKey: "unregister failed"]
    )
    let state = RegistrationState(
      status: .enabled,
      registeredFingerprint: "old-fingerprint",
      unregisterError: expected
    )

    let result = AppStorePrivilegedInstaller.registerBundledHelper(
      using: state.dependencies()
    )

    let error = try? XCTUnwrap(result.error)
    XCTAssertEqual(error?.code, 1)
    XCTAssertTrue(error?.localizedDescription.contains("unregister failed") == true)
    XCTAssertEqual(state.registerCallCount, 0)
  }

  func testReportsTimeoutWhenHelperUnregisterNeverReplies() {
    let state = RegistrationState(
      status: .enabled,
      registeredFingerprint: "old-fingerprint",
      shouldReplyToUnregister: false
    )

    let result = AppStorePrivilegedInstaller.registerBundledHelper(
      using: state.dependencies(),
      unregisterTimeout: 0
    )

    let error = try? XCTUnwrap(result.error)
    XCTAssertEqual(error?.code, 6)
    XCTAssertTrue(error?.localizedDescription.contains("超时") == true)
    XCTAssertEqual(state.registerCallCount, 0)
  }

  func testReportsRegisterFailure() {
    let expected = NSError(
      domain: "test",
      code: 92,
      userInfo: [NSLocalizedDescriptionKey: "register failed"]
    )
    let state = RegistrationState(status: .disabled, registerError: expected)

    let result = AppStorePrivilegedInstaller.registerBundledHelper(
      using: state.dependencies()
    )

    let error = try? XCTUnwrap(result.error)
    XCTAssertEqual(error?.code, 1)
    XCTAssertTrue(error?.localizedDescription.contains("register failed") == true)
  }
}

private extension PrivilegedHelperRegistrationResult {
  var error: NSError? {
    guard case .failed(let error) = self else { return nil }
    return error
  }
}

private final class RegistrationState {
  var status: PrivilegedHelperServiceStatus
  var registeredFingerprint: String?
  var registerCallCount = 0
  var unregisterCallCount = 0
  let unregisterError: Error?
  let shouldReplyToUnregister: Bool
  let registerError: Error?

  init(
    status: PrivilegedHelperServiceStatus,
    registeredFingerprint: String? = nil,
    unregisterError: Error? = nil,
    shouldReplyToUnregister: Bool = true,
    registerError: Error? = nil
  ) {
    self.status = status
    self.registeredFingerprint = registeredFingerprint
    self.unregisterError = unregisterError
    self.shouldReplyToUnregister = shouldReplyToUnregister
    self.registerError = registerError
  }

  func dependencies(
    helperExists: Bool = true
  ) -> PrivilegedHelperRegistrationDependencies {
    PrivilegedHelperRegistrationDependencies(
      bundledLaunchDaemonPlistExists: helperExists,
      bundledHelperFingerprint: helperExists ? "new-fingerprint" : nil,
      registeredFingerprint: { self.registeredFingerprint },
      setRegisteredFingerprint: { self.registeredFingerprint = $0 },
      serviceStatus: { self.status },
      unregister: { completion in
        self.unregisterCallCount += 1
        guard self.shouldReplyToUnregister else { return }
        if self.unregisterError == nil {
          self.status = .disabled
        }
        completion(self.unregisterError)
      },
      register: {
        self.registerCallCount += 1
        if let registerError = self.registerError {
          throw registerError
        }
        self.status = .enabled
      }
    )
  }
}
