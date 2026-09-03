import Darwin
import Foundation
import Security
import UpkeepPrivilegedHelperProtocol

final class PrivilegedHelper: NSObject, NSXPCListenerDelegate, UpkeepPrivilegedHelperProtocol {
  private lazy var expectedClientRequirement: SecRequirement? = Self.clientRequirementFromHostApp()

  func run() {
    let listener = NSXPCListener(
      machServiceName: UpkeepPrivilegedHelperConstants.machServiceName
    )
    listener.delegate = self
    listener.resume()
    RunLoop.main.run()
  }

  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    guard isAllowedClient(newConnection) else {
      return false
    }

    newConnection.exportedInterface = NSXPCInterface(
      with: UpkeepPrivilegedHelperProtocol.self
    )
    newConnection.exportedObject = self
    newConnection.resume()
    return true
  }

  func installAppStorePackage(
    packagePath: String,
    receiptPath: String,
    applicationPath: String,
    withReply reply: @escaping (String?) -> Void
  ) {
    reply(Self.installAppStorePackage(
      packagePath: packagePath,
      receiptPath: receiptPath,
      applicationPath: applicationPath
    ))
  }

  func ping(withReply reply: @escaping () -> Void) {
    reply()
  }

  private func isAllowedClient(_ connection: NSXPCConnection) -> Bool {
    guard let requirement = expectedClientRequirement else {
      return false
    }

    let attributes = [
      kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier)
    ] as CFDictionary
    var guestCode: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guestCode) == errSecSuccess,
      let guestCode
    else {
      return false
    }

    return SecCodeCheckValidity(guestCode, [], requirement) == errSecSuccess
  }

  private static func clientRequirementFromHostApp() -> SecRequirement? {
    guard let appURL = hostApplicationURL() else {
      return nil
    }

    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
      let staticCode
    else {
      return nil
    }

    var requirement: SecRequirement?
    guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else {
      return nil
    }
    return requirement
  }

  private static func hostApplicationURL() -> URL? {
    hostApplicationURL(from: executableURL())
  }

  static func hostApplicationURL(from executableURL: URL?) -> URL? {
    guard var url = executableURL else {
      return nil
    }

    while url.path != "/" {
      if url.pathExtension == "app" {
        return url
      }
      url.deleteLastPathComponent()
    }
    return nil
  }

  private static func executableURL() -> URL? {
    var requiredSize: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &requiredSize)
    guard requiredSize > 0 else {
      return nil
    }

    var path = [CChar](repeating: 0, count: Int(requiredSize))
    guard _NSGetExecutablePath(&path, &requiredSize) == 0 else {
      return nil
    }

    return path.withUnsafeBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else {
        return nil
      }
      return URL(fileURLWithPath: String(cString: baseAddress))
        .resolvingSymlinksInPath()
        .standardizedFileURL
    }
  }

  private static func installAppStorePackage(
    packagePath: String,
    receiptPath: String,
    applicationPath: String
  ) -> String? {
    installAppStorePackage(
      packagePath: packagePath,
      receiptPath: receiptPath,
      applicationPath: applicationPath,
      isRoot: getuid() == 0,
      runCommand: run
    )
  }

  static func installAppStorePackage(
    packagePath: String,
    receiptPath: String,
    applicationPath: String,
    isRoot: Bool,
    runCommand: (_ launchPath: String, _ arguments: [String]) -> String?
  ) -> String? {
    guard isRoot else {
      return "安装助手没有管理员权限。"
    }

    let packageURL = URL(fileURLWithPath: packagePath).standardizedFileURL
    let receiptURL = URL(fileURLWithPath: receiptPath).standardizedFileURL
    let applicationURL = URL(fileURLWithPath: applicationPath).standardizedFileURL

    guard packageURL.pathExtension.lowercased() == "pkg" else {
      return "App Store 下载包格式不正确。"
    }
    guard FileManager.default.fileExists(atPath: packageURL.path) else {
      return "找不到 App Store 下载包。"
    }
    guard receiptURL.lastPathComponent == "receipt",
      FileManager.default.fileExists(atPath: receiptURL.path)
    else {
      return "找不到 App Store 收据文件。"
    }
    guard applicationURL.pathExtension == "app" else {
      return "应用路径不正确。"
    }

    let installError = runCommand(
      "/usr/sbin/installer",
      ["-dumplog", "-pkg", packageURL.path, "-target", "/"]
    )
    if let installError {
      return installError
    }

    let receiptDirectoryURL = applicationURL.appendingPathComponent(
      "Contents/_MASReceipt",
      isDirectory: true
    )
    let destinationReceiptURL = receiptDirectoryURL.appendingPathComponent("receipt")

    do {
      try FileManager.default.createDirectory(
        at: receiptDirectoryURL,
        withIntermediateDirectories: true
      )
      try? FileManager.default.removeItem(at: destinationReceiptURL)
      try FileManager.default.copyItem(at: receiptURL, to: destinationReceiptURL)
      chmod(destinationReceiptURL.path, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
      chown(destinationReceiptURL.path, 0, 0)
    } catch {
      return "无法写入 App Store 收据：\(error.localizedDescription)"
    }

    return runCommand("/usr/bin/mdimport", [applicationURL.path])
  }

  static func run(_ launchPath: String, arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments

    let pipe = Pipe()
    let output = HelperDataBuffer()
    process.standardOutput = pipe
    process.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if !data.isEmpty {
        output.append(data)
      }
    }

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      pipe.fileHandleForReading.readabilityHandler = nil
      return "\(URL(fileURLWithPath: launchPath).lastPathComponent) 无法启动：\(error.localizedDescription)"
    }

    pipe.fileHandleForReading.readabilityHandler = nil
    if let remaining = try? pipe.fileHandleForReading.readToEnd(), !remaining.isEmpty {
      output.append(remaining)
    }

    guard process.terminationStatus == 0 else {
      let message = String(data: output.data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return message?.isEmpty == false
        ? message
        : "\(URL(fileURLWithPath: launchPath).lastPathComponent) 执行失败。"
    }

    return nil
  }
}

private final class HelperDataBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Data()

  var data: Data {
    lock.withLock { storage }
  }

  func append(_ data: Data) {
    lock.withLock {
      storage.append(data)
    }
  }
}

let helper = PrivilegedHelper()
helper.run()
