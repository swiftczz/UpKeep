import AppKit
import Darwin
import Foundation
import LocalAuthentication
import Security
import UpkeepPrivilegedHelperProtocol

enum PrivilegedApplicationTrash {
  static func supports(_ url: URL) -> Bool {
    url.isFileURL && PrivilegedTrashPolicy.isSupportedApplicationPath(url.path)
      && url.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL
  }

  static func moveToTrash(
    _ urls: [URL],
    prepare: @Sendable () async throws -> Bool = prepareHelper,
    authenticate: @Sendable ([URL]) async throws -> Void = authenticateUser,
    move: @Sendable ([URL]) async throws -> Void = moveUsingHelper
  ) async throws -> Bool {
    guard !urls.isEmpty, urls.allSatisfy(supports) else { return false }
    try Task.checkCancellation()
    // Check actual helper availability before asking for Touch ID. Once the user
    // authenticates, failures must be reported, never followed by a Finder prompt.
    guard try await prepare() else { return false }
    try Task.checkCancellation()
    try await authenticate(urls)
    try Task.checkCancellation()
    try await move(urls)
    return true
  }

  private static func prepareHelper() async throws -> Bool {
    try await Task.detached(priority: .userInitiated) {
      guard PrivilegedTrashPolicy.isAdministrator(geteuid()) else { return false }
      return try AppStorePrivilegedInstaller.withRegisteredHelper {
        try request { proxy, reply in
          proxy.canTrashApplications { reply(.success($0)) }
        }
      } ?? false
    }.value
  }

  @MainActor
  private static func authenticateUser(_ urls: [URL]) async throws {
    let context = LAContext()
    defer { context.invalidate() }
    context.localizedCancelTitle = "取消卸载"
    context.touchIDAuthenticationAllowableReuseDuration = 0
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      throw error ?? failure("系统身份验证暂不可用，请稍后重试。")
    }
    let names = urls.prefix(3).map { $0.deletingPathExtension().lastPathComponent }
      .joined(separator: "、")
    NSApp.activate(ignoringOtherApps: true)
    do {
      let authenticated = try await context.evaluatePolicy(
        .deviceOwnerAuthentication,
        localizedReason: "将“\(names)”移到废纸篓"
      )
      guard authenticated else { throw FinderTrashError.authorizationCancelled }
    } catch let error as LAError {
      switch error.code {
      case .userCancel, .appCancel, .systemCancel:
        throw FinderTrashError.authorizationCancelled
      default: throw error
      }
    }
  }

  private static func moveUsingHelper(_ urls: [URL]) async throws {
    try await Task.detached(priority: .userInitiated) {
      try prepareTrashDirectory()
      let moved = try AppStorePrivilegedInstaller.withRegisteredHelper {
        try request { proxy, reply in
          proxy.trashApplications(paths: urls.map(\.path)) { message in
            if let message { reply(.failure(failure(message))) }
            else { reply(.success(true)) }
          }
        }
      }
      guard moved == true else { throw failure("卸载助手不可用，请重新启动 Upkeep 后再试。") }
    }.value
  }

  static func prepareTrashDirectory(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws {
    let trash = homeDirectory.appendingPathComponent(".Trash", isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: trash, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
    } catch let error as CocoaError where error.code == .fileWriteFileExists {
      // An existing Trash is the normal case. Do not replace it or alter its
      // permissions. lstat also rejects symlinks, including dangling ones.
      var info = stat()
      guard lstat(trash.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
        throw error
      }
    }
  }

  private static func request(
    _ send: (UpkeepPrivilegedHelperProtocol, @escaping @Sendable (Result<Bool, NSError>) -> Void) -> Void
  ) throws -> Bool {
    let connection = NSXPCConnection(
      machServiceName: UpkeepPrivilegedHelperConstants.machServiceName, options: .privileged
    )
    connection.remoteObjectInterface = NSXPCInterface(with: UpkeepPrivilegedHelperProtocol.self)
    connection.setCodeSigningRequirement(try helperRequirement())
    let reply = PrivilegedHelperReply<Result<Bool, NSError>>()
    connection.invalidationHandler = {
      reply.resolve(.failure(failure("卸载助手连接已断开，请重新启动 Upkeep 后再试。")))
    }
    connection.interruptionHandler = {
      reply.resolve(.failure(failure("卸载助手连接中断，请检查应用是否仍在原位置。")))
    }
    connection.resume()
    defer { connection.invalidate() }
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
      reply.resolve(.failure(error as NSError))
    }) as? UpkeepPrivilegedHelperProtocol else {
      throw failure("无法连接卸载助手。")
    }
    send(proxy) { reply.resolve($0) }
    return try reply.wait(timeout: 15, otherwise: .failure(failure(
      "卸载助手未及时返回结果，请检查应用是否仍在原位置后再试。"
    ))).get()
  }

  private static func helperRequirement() throws -> String {
    guard let executable = Bundle.main.executableURL else { throw failure("找不到卸载助手。") }
    let url = executable.deletingLastPathComponent().appendingPathComponent("UpkeepPrivilegedHelper")
    var code: SecStaticCode?
    var requirement: SecRequirement?
    var value: CFString?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
      SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
      SecRequirementCopyString(requirement, [], &value) == errSecSuccess, let value
    else { throw failure("无法验证卸载助手的签名，请重新安装完整的 Upkeep 应用。") }
    return value as String
  }

  private static func failure(_ message: String) -> NSError {
    NSError(domain: "Upkeep.PrivilegedTrash", code: 1,
      userInfo: [NSLocalizedDescriptionKey: message])
  }
}
