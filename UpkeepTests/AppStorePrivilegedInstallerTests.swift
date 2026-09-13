import Foundation
import XCTest

@testable import Upkeep

final class AppStorePrivilegedInstallerTests: XCTestCase {
  func testRegistrationFingerprintIncludesLaunchConfigurationAndApplicationLocation() {
    let helper = Data("signed helper".utf8)
    let original = AppStorePrivilegedInstaller.registrationFingerprint(
      helperData: helper, launchDaemonData: Data("old plist".utf8),
      applicationPath: "/Applications/Upkeep.app"
    )
    let changedPlist = AppStorePrivilegedInstaller.registrationFingerprint(
      helperData: helper, launchDaemonData: Data("new plist".utf8),
      applicationPath: "/Applications/Upkeep.app"
    )
    let movedApp = AppStorePrivilegedInstaller.registrationFingerprint(
      helperData: helper, launchDaemonData: Data("old plist".utf8),
      applicationPath: "/Users/example/Applications/Upkeep.app"
    )
    XCTAssertNotEqual(original, changedPlist)
    XCTAssertNotEqual(original, movedApp)
  }

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
    XCTAssertNil(state.registeredFingerprint)
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
  func testRepairsUnreachableHelperEvenWhenFingerprintIsUnchanged() {
    let state = RegistrationState(
      status: .enabled, registeredFingerprint: "new-fingerprint", reachability: [false, true]
    )
    let result = AppStorePrivilegedInstaller.registerBundledHelper(using: state.dependencies())
    guard case .enabled = result else { return XCTFail("Expected repaired registration") }
    XCTAssertEqual(state.unregisterCallCount, 1)
    XCTAssertEqual(state.registerCallCount, 1)
    XCTAssertEqual(state.probeCallCount, 2)
  }

  func testFailedRepairStopsAfterOneAttempt() {
    let state = RegistrationState(
      status: .enabled, registeredFingerprint: "new-fingerprint", reachability: [false]
    )
    let result = AppStorePrivilegedInstaller.registerBundledHelper(using: state.dependencies())
    XCTAssertEqual(result.error?.code, 7)
    XCTAssertEqual(state.unregisterCallCount, 1)
    XCTAssertEqual(state.registerCallCount, 1)
    XCTAssertEqual(state.probeCallCount, 2)
  }

  func testUnreachableReplacementDoesNotPersistNewFingerprint() {
    let state = RegistrationState(
      status: .enabled, registeredFingerprint: "old-fingerprint", reachability: [false]
    )
    let result = AppStorePrivilegedInstaller.registerBundledHelper(using: state.dependencies())
    XCTAssertEqual(result.error?.code, 7)
    XCTAssertEqual(state.registeredFingerprint, "old-fingerprint")
    XCTAssertEqual(state.probeCallCount, 1)
  }

  func testFreshRegistrationMustAnswerBeforeItIsMarkedReady() {
    let state = RegistrationState(status: .disabled, reachability: [false])
    let result = AppStorePrivilegedInstaller.registerBundledHelper(using: state.dependencies())
    XCTAssertEqual(result.error?.code, 7)
    XCTAssertNil(state.registeredFingerprint)
  }

  func testUnresponsiveConnectionDoesNotSubmitAnInstallation() {
    var installed = false
    let result = AppStorePrivilegedInstaller.sendInstallRequest(
      using: PrivilegedHelperConnectionDependencies(
        ping: { _ in }, install: { _ in installed = true }
      ),
      connectionTimeout: 0
    )
    guard case .failed(let error) = result else { return XCTFail("Expected connection failure") }
    XCTAssertEqual(error.code, 7)
    XCTAssertFalse(installed)
  }

  func testRejectedConnectionDoesNotSubmitAnInstallation() {
    let result = AppStorePrivilegedInstaller.sendInstallRequest(
      using: PrivilegedHelperConnectionDependencies(
        ping: { $0(false) }, install: { _ in XCTFail("Must not install") }
      )
    )
    guard case .failed(let error) = result else { return XCTFail("Expected connection failure") }
    XCTAssertEqual(error.code, 7)
  }

  func testConnectedHelperInstallsExactlyOnce() {
    var installs = 0
    let result = AppStorePrivilegedInstaller.sendInstallRequest(
      using: PrivilegedHelperConnectionDependencies(
        ping: { $0(true) },
        install: { reply in
          installs += 1
          reply(.installed)
        }
      )
    )
    guard case .installed = result else { return XCTFail("Expected installation") }
    XCTAssertEqual(installs, 1)
  }

  func testInstallationTimeoutReportsUncertainOutcomeWithoutRetrying() {
    var installs = 0
    let result = AppStorePrivilegedInstaller.sendInstallRequest(
      using: PrivilegedHelperConnectionDependencies(
        ping: { $0(true) }, install: { _ in installs += 1 }
      ),
      installationTimeout: 0
    )
    guard case .failed(let error) = result else { return XCTFail("Expected timeout") }
    XCTAssertEqual(error.code, 2)
    XCTAssertTrue(error.localizedDescription.contains("尚未确认"))
    XCTAssertEqual(installs, 1)
  }

  func testLateReplyCannotReplaceTimeout() {
    let reply = PrivilegedHelperReply<Bool>()
    XCTAssertFalse(reply.wait(timeout: 0, otherwise: false))
    reply.resolve(true)
    XCTAssertFalse(reply.wait(timeout: 0, otherwise: true))
  }

  func testDuplicateReplyCannotReplaceOriginalResult() {
    let reply = PrivilegedHelperReply<Bool>()
    reply.resolve(true)
    reply.resolve(false)
    XCTAssertTrue(reply.wait(timeout: 0, otherwise: false))
  }

}

extension PrivilegedHelperRegistrationResult {
  fileprivate var error: NSError? {
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
  var reachability: [Bool]
  var probeCallCount = 0

  init(
    status: PrivilegedHelperServiceStatus,
    registeredFingerprint: String? = nil,
    unregisterError: Error? = nil,
    shouldReplyToUnregister: Bool = true,
    registerError: Error? = nil,
    reachability: [Bool] = [true]
  ) {
    self.status = status
    self.registeredFingerprint = registeredFingerprint
    self.unregisterError = unregisterError
    self.shouldReplyToUnregister = shouldReplyToUnregister
    self.registerError = registerError
    self.reachability = reachability
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
      },
      isReachable: {
        self.probeCallCount += 1
        if self.reachability.count > 1 { return self.reachability.removeFirst() }
        return self.reachability.first ?? false
      }
    )
  }
}
