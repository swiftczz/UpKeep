import CryptoKit
import Foundation
import OSLog
import ServiceManagement
import UpkeepPrivilegedHelperProtocol

enum AppStorePrivilegedInstaller {
  private static let registeredHelperFingerprintKey =
    "AppStorePrivilegedInstaller.registeredHelperFingerprint"
  // Registration changes must never terminate an installation already in progress.
  private static let operationLock = NSLock()
  private static let logger = Logger(
    subsystem: "com.chengzhong.Upkeep",
    category: "PrivilegedInstaller"
  )

  static func prepareIfBundled() {
    guard bundledLaunchDaemonPlistExists else {
      return
    }
    guard operationLock.try() else { return }
    defer { operationLock.unlock() }
    switch registerBundledHelper() {
    case .enabled:
      break
    case .unavailable:
      return
    case .failed(let error):
      logger.error("安装助手注册失败：\(error.localizedDescription, privacy: .public)")
      return
    }
    logger.info("安装助手连接检查成功")
  }

  static func installDownloadedPackage(
    packageURL: URL,
    receiptURL: URL,
    applicationURL: URL,
    progress: @escaping @Sendable (UpdateProgress) -> Void = { _ in }
  ) -> PrivilegedInstallResult {
    operationLock.lock()
    defer { operationLock.unlock() }
    switch registerBundledHelper() {
    case .enabled:
      break
    case .unavailable:
      return .unavailable
    case .failed(let error):
      return .failed(error)
    }

    return invokeHelper(
      packageURL: packageURL,
      receiptURL: receiptURL,
      applicationURL: applicationURL,
      progress: progress
    )
  }

  private static func registerBundledHelper() -> PrivilegedHelperRegistrationResult {
    guard ApplicationCodeSigning.signatureIsValid(at: Bundle.main.bundleURL) else {
      return .failed(NSError(
        domain: "Upkeep.PrivilegedInstaller", code: 8,
        userInfo: [NSLocalizedDescriptionKey:
          "Upkeep 的应用签名不完整或已损坏，无法启用安装助手。请重新安装完整的 Upkeep 应用后再试。"]
      ))
    }
    let service = SMAppService.daemon(
      plistName: UpkeepPrivilegedHelperConstants.launchDaemonPlistName
    )
    return registerBundledHelper(
      using: PrivilegedHelperRegistrationDependencies(
        bundledLaunchDaemonPlistExists: bundledLaunchDaemonPlistExists,
        bundledHelperFingerprint: bundledHelperFingerprint,
        registeredFingerprint: {
          UserDefaults.standard.string(forKey: registeredHelperFingerprintKey)
        },
        setRegisteredFingerprint: {
          UserDefaults.standard.set($0, forKey: registeredHelperFingerprintKey)
        },
        serviceStatus: {
          switch service.status {
          case .enabled: .enabled
          case .requiresApproval: .requiresApproval
          default: .disabled
          }
        },
        unregister: { completion in
          service.unregister(completionHandler: completion)
        },
        register: {
          try service.register()
        },
        isReachable: helperIsReachable
      )
    )
  }

  static func registerBundledHelper(
    using dependencies: PrivilegedHelperRegistrationDependencies,
    unregisterTimeout: TimeInterval = 15
  ) -> PrivilegedHelperRegistrationResult {
    guard dependencies.bundledLaunchDaemonPlistExists,
      let helperFingerprint = dependencies.bundledHelperFingerprint
    else {
      return .unavailable
    }

    do {
      let registeredFingerprint = dependencies.registeredFingerprint()
      let status = dependencies.serviceStatus()
      if status == .requiresApproval {
        return .failed(helperApprovalRequiredError)
      }

      var shouldRegister = status != .enabled
      if status == .enabled,
        registeredFingerprint != helperFingerprint || !dependencies.isReachable()
      {
        // An enabled service may still hold an obsolete code-signing requirement.
        // Re-register once even when our cached fingerprint has not changed.
        let semaphore = DispatchSemaphore(value: 0)
        let unregisterResult = LockedBox<Error?>(nil)
        dependencies.unregister { error in
          unregisterResult.value = error
          semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + unregisterTimeout) == .success else {
          return .failed(
            NSError(
              domain: "Upkeep.PrivilegedInstaller",
              code: 6,
              userInfo: [NSLocalizedDescriptionKey: "更新安装助手超时，请重新启动 Upkeep 后再试。"]
            )
          )
        }
        if let unregisterError = unregisterResult.value {
          throw unregisterError
        }
        shouldRegister = true
      }

      if shouldRegister {
        try dependencies.register()
      }
      guard dependencies.serviceStatus() == .enabled else {
        return .failed(helperApprovalRequiredError)
      }
      if shouldRegister, !dependencies.isReachable() {
        return .failed(helperUnavailableError)
      }
      // Persist only after the registered executable has answered a request.
      dependencies.setRegisteredFingerprint(helperFingerprint)
      return .enabled
    } catch {
      return .failed(
        NSError(
          domain: "Upkeep.PrivilegedInstaller",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "无法启用安装助手：\(error.localizedDescription)"]
        )
      )
    }
  }

  private static var bundledLaunchDaemonPlistExists: Bool {
    guard let resourceURL = Bundle.main.resourceURL else {
      return false
    }
    let plistURL =
      resourceURL
      .deletingLastPathComponent()
      .appendingPathComponent("Library/LaunchDaemons", isDirectory: true)
      .appendingPathComponent(UpkeepPrivilegedHelperConstants.launchDaemonPlistName)
    return FileManager.default.fileExists(atPath: plistURL.path)
  }

  private static var helperApprovalRequiredError: NSError {
    NSError(
      domain: "Upkeep.PrivilegedInstaller",
      code: 5,
      userInfo: [NSLocalizedDescriptionKey: "安装助手尚未启用，请在系统设置中允许 Upkeep 的后台项目。"]
    )
  }

  private static var bundledHelperFingerprint: String? {
    guard let executableURL = Bundle.main.executableURL else {
      return nil
    }
    let helperURL =
      executableURL
      .deletingLastPathComponent()
      .appendingPathComponent("UpkeepPrivilegedHelper")
    let plistURL = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Library/LaunchDaemons/\(UpkeepPrivilegedHelperConstants.launchDaemonPlistName)"
    )
    guard let data = try? Data(contentsOf: helperURL, options: .mappedIfSafe),
      let plistData = try? Data(contentsOf: plistURL)
    else { return nil }
    return registrationFingerprint(
      helperData: data, launchDaemonData: plistData,
      applicationPath: Bundle.main.bundleURL.standardizedFileURL.path
    )
  }

  static func registrationFingerprint(
    helperData: Data, launchDaemonData: Data, applicationPath: String
  ) -> String {
    // A plist or app-location change also requires updating the service record.
    var hash = SHA256()
    hash.update(data: helperData)
    hash.update(data: launchDaemonData)
    hash.update(data: Data(applicationPath.utf8))
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func helperIsReachable() -> Bool {
    let connection = NSXPCConnection(
      machServiceName: UpkeepPrivilegedHelperConstants.machServiceName,
      options: .privileged
    )
    connection.remoteObjectInterface = NSXPCInterface(
      with: UpkeepPrivilegedHelperProtocol.self
    )
    connection.resume()
    defer { connection.invalidate() }

    let reply = PrivilegedHelperReply<Bool>()
    ping(connection) { reply.resolve($0) }
    return reply.wait(timeout: 5, otherwise: false)
  }

  private static var helperUnavailableError: NSError {
    NSError(
      domain: "Upkeep.PrivilegedInstaller", code: 7,
      userInfo: [
        NSLocalizedDescriptionKey:
          "安装助手无法连接或启动。请在系统设置中检查 Upkeep 的后台项目，或重新安装 Upkeep 后再试。"
      ]
    )
  }

  private static func ping(
    _ connection: NSXPCConnection,
    reply: @escaping @Sendable (Bool) -> Void
  ) {
    guard
      let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in reply(false) })
        as? UpkeepPrivilegedHelperProtocol
    else {
      reply(false)
      return
    }
    proxy.ping { reply(true) }
  }

  private static func invokeHelper(
    packageURL: URL,
    receiptURL: URL,
    applicationURL: URL,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) -> PrivilegedInstallResult {
    let connection = NSXPCConnection(
      machServiceName: UpkeepPrivilegedHelperConstants.machServiceName,
      options: .privileged
    )
    connection.remoteObjectInterface = NSXPCInterface(
      with: UpkeepPrivilegedHelperProtocol.self
    )
    connection.resume()
    defer { connection.invalidate() }

    return sendInstallRequest(
      using: PrivilegedHelperConnectionDependencies(
        ping: { reply in ping(connection, reply: reply) },
        install: { reply in
          progress(.indeterminate("正在安装…"))
          guard
            let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
              reply(
                .failed(
                  NSError(
                    domain: "Upkeep.PrivilegedInstaller", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "安装助手连接中断：\(error.localizedDescription)"]
                  )))
            }) as? UpkeepPrivilegedHelperProtocol
          else {
            reply(.failed(helperUnavailableError))
            return
          }
          proxy.installAppStorePackage(
            packagePath: packageURL.path,
            receiptPath: receiptURL.path,
            applicationPath: applicationURL.path
          ) { errorMessage in
            if let errorMessage, !errorMessage.isEmpty {
              reply(
                .failed(
                  NSError(
                    domain: "Upkeep.PrivilegedInstaller", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: errorMessage]
                  )))
            } else {
              reply(.installed)
            }
          }
        }
      )
    )
  }

  static func sendInstallRequest(
    using dependencies: PrivilegedHelperConnectionDependencies,
    connectionTimeout: TimeInterval = 5,
    installationTimeout: TimeInterval = 300
  ) -> PrivilegedInstallResult {
    // Verify this connection before submitting an installation. A launch failure
    // must not wait for the much longer installation timeout.
    let handshake = PrivilegedHelperReply<Bool>()
    dependencies.ping { handshake.resolve($0) }
    guard handshake.wait(timeout: connectionTimeout, otherwise: false) else {
      return .failed(helperUnavailableError)
    }

    let reply = PrivilegedHelperReply<PrivilegedInstallResult>()
    dependencies.install { reply.resolve($0) }
    return reply.wait(
      timeout: installationTimeout,
      otherwise: .failed(
        NSError(
          domain: "Upkeep.PrivilegedInstaller", code: 2,
          userInfo: [
            NSLocalizedDescriptionKey:
              "安装助手未及时返回结果，安装结果尚未确认。请检查应用版本后再试。"
          ]
        ))
    )
  }

}

enum PrivilegedInstallResult: Sendable {
  case installed
  case unavailable
  case failed(NSError)
}

enum PrivilegedHelperRegistrationResult {
  case enabled
  case unavailable
  case failed(NSError)
}

enum PrivilegedHelperServiceStatus: Equatable {
  case enabled
  case requiresApproval
  case disabled
}

struct PrivilegedHelperRegistrationDependencies {
  let bundledLaunchDaemonPlistExists: Bool
  let bundledHelperFingerprint: String?
  let registeredFingerprint: () -> String?
  let setRegisteredFingerprint: (String) -> Void
  let serviceStatus: () -> PrivilegedHelperServiceStatus
  let unregister: (@escaping @Sendable (Error?) -> Void) -> Void
  let register: () throws -> Void
  let isReachable: () -> Bool
}

struct PrivilegedHelperConnectionDependencies {
  let ping: (@escaping @Sendable (Bool) -> Void) -> Void
  let install: (@escaping @Sendable (PrivilegedInstallResult) -> Void) -> Void
}

// XPC may report an error or a reply after the caller has timed out. Only the
// first terminal result is accepted, including when that result is a timeout.
final class PrivilegedHelperReply<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var value: Value?

  func resolve(_ result: Value) {
    lock.withLock {
      guard value == nil else { return }
      value = result
      semaphore.signal()
    }
  }

  func wait(timeout: TimeInterval, otherwise fallback: Value) -> Value {
    _ = semaphore.wait(timeout: .now() + timeout)
    return lock.withLock {
      if let value { return value }
      value = fallback
      return fallback
    }
  }
}

private final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue: Value

  init(_ value: Value) {
    storedValue = value
  }

  var value: Value {
    get {
      lock.withLock { storedValue }
    }
    set {
      lock.withLock {
        storedValue = newValue
      }
    }
  }
}
