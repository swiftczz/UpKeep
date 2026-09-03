import CryptoKit
import Foundation
import OSLog
import ServiceManagement
import UpkeepPrivilegedHelperProtocol

enum AppStorePrivilegedInstaller {
  private static let registeredHelperFingerprintKey =
    "AppStorePrivilegedInstaller.registeredHelperFingerprint"
  private static let registrationLock = NSLock()
  private static let logger = Logger(
    subsystem: "com.chengzhong.Upkeep",
    category: "PrivilegedInstaller"
  )

  static func prepareIfBundled() {
    guard bundledLaunchDaemonPlistExists else {
      return
    }
    switch registerBundledHelper() {
    case .enabled:
      break
    case .unavailable:
      return
    case .failed(let error):
      logger.error("安装助手注册失败：\(error.localizedDescription, privacy: .public)")
      return
    }
    if helperIsReachable() {
      logger.info("安装助手连接检查成功")
    } else {
      logger.error("安装助手已注册，但连接检查失败")
    }
  }

  static func installDownloadedPackage(
    packageURL: URL,
    receiptURL: URL,
    applicationURL: URL
  ) -> PrivilegedInstallResult {
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
      applicationURL: applicationURL
    )
  }

  private static func registerBundledHelper() -> PrivilegedHelperRegistrationResult {
    registrationLock.lock()
    defer { registrationLock.unlock() }

    guard bundledLaunchDaemonPlistExists,
      let helperFingerprint = bundledHelperFingerprint
    else {
      return .unavailable
    }

    do {
      let service = SMAppService.daemon(
        plistName: UpkeepPrivilegedHelperConstants.launchDaemonPlistName
      )
      let registeredFingerprint = UserDefaults.standard.string(
        forKey: registeredHelperFingerprintKey
      )
      let status = service.status
      if status == .requiresApproval {
        UserDefaults.standard.set(helperFingerprint, forKey: registeredHelperFingerprintKey)
        return .failed(helperApprovalRequiredError)
      }

      var shouldRegister = status != .enabled
      if status == .enabled,
        registeredFingerprint != helperFingerprint
      {
        let semaphore = DispatchSemaphore(value: 0)
        let unregisterResult = LockedBox<Error?>(nil)
        service.unregister { error in
          unregisterResult.value = error
          semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 15) == .success else {
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
        try service.register()
        UserDefaults.standard.set(helperFingerprint, forKey: registeredHelperFingerprintKey)
      }
      guard service.status == .enabled else {
        return .failed(helperApprovalRequiredError)
      }
      UserDefaults.standard.set(helperFingerprint, forKey: registeredHelperFingerprintKey)
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
    let plistURL = resourceURL
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
    let helperURL = executableURL
      .deletingLastPathComponent()
      .appendingPathComponent("UpkeepPrivilegedHelper")
    guard let data = try? Data(contentsOf: helperURL, options: .mappedIfSafe) else {
      return nil
    }
    return SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
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

    let semaphore = DispatchSemaphore(value: 0)
    let reached = LockedBox(false)
    let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
      semaphore.signal()
    } as? UpkeepPrivilegedHelperProtocol
    guard let proxy else {
      return false
    }

    proxy.ping {
      reached.value = true
      semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + 5) == .success else {
      return false
    }
    return reached.value
  }

  private static func invokeHelper(
    packageURL: URL,
    receiptURL: URL,
    applicationURL: URL
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

    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var result = PrivilegedInstallResult.failed(
      NSError(
        domain: "Upkeep.PrivilegedInstaller",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "安装助手没有响应。"]
      )
    )

    let proxy = connection.remoteObjectProxyWithErrorHandler { error in
      lock.lock()
      result = .failed(
        NSError(
          domain: "Upkeep.PrivilegedInstaller",
          code: 3,
          userInfo: [NSLocalizedDescriptionKey: "无法连接安装助手：\(error.localizedDescription)"]
        )
      )
      lock.unlock()
      semaphore.signal()
    } as? UpkeepPrivilegedHelperProtocol

    guard let proxy else {
      return .unavailable
    }

    proxy.installAppStorePackage(
      packagePath: packageURL.path,
      receiptPath: receiptURL.path,
      applicationPath: applicationURL.path
    ) { errorMessage in
      lock.lock()
      if let errorMessage, !errorMessage.isEmpty {
        result = .failed(
          NSError(
            domain: "Upkeep.PrivilegedInstaller",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: errorMessage]
          )
        )
      } else {
        result = .installed
      }
      lock.unlock()
      semaphore.signal()
    }

    if semaphore.wait(timeout: .now() + 300) == .timedOut {
      connection.invalidate()
    }

    lock.lock()
    let finalResult = result
    lock.unlock()
    return finalResult
  }
}

enum PrivilegedInstallResult {
  case installed
  case unavailable
  case failed(NSError)
}

private enum PrivilegedHelperRegistrationResult {
  case enabled
  case unavailable
  case failed(NSError)
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
