// The App Store transaction flow in this file is derived from mas-cli/mas.
// Copyright (c) 2015 Andrew Naylor, Ross Goldberg. Licensed under MIT.

import CoreServices
import Darwin
import Foundation
import OSLog
import ObjectiveC
import Security

final class AppStoreUpdateSession: NSObject, @unchecked Sendable {
  static var isAvailable: Bool {
    PrivateFrameworks.load() != nil
  }

  private static let logger = Logger(subsystem: "com.chengzhong.Upkeep", category: "AppStoreUpdate")
  private static let fallbackInstallLock = NSLock()
  nonisolated(unsafe) private static var fallbackInstallAuthorization: AuthorizationRef?

  private var adamID: UInt64 = 0
  private var applicationURL: URL?
  private var progressHandler: (@Sendable (UpdateProgress) -> Void)?
  private var completionHandler: (@Sendable (String?, NSError?) -> Void)?
  private var downloadQueue: AnyObject?
  private var currentDownload: AnyObject?
  private var observerToken: AnyObject?
  private var packageHardLinkURL: URL?
  private var receiptHardLinkURL: URL?
  private var selfRetainer: AppStoreUpdateSession?
  private var isFinished = false
  private var downloadLifecycle = AppStoreDownloadLifecycle()
  private var purchaseGate = AppStorePurchaseGate()
  private let finishLock = NSLock()

  func startUpdate(
    adamID: UInt64,
    applicationURL: URL,
    progress: (@Sendable (UpdateProgress) -> Void)?,
    completion: @escaping @Sendable (String?, NSError?) -> Void
  ) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [self] in
        startUpdate(
          adamID: adamID,
          applicationURL: applicationURL,
          progress: progress,
          completion: completion
        )
      }
      return
    }

    guard PrivateFrameworks.load() != nil else {
      completion(nil, Self.bridgeError(1, "当前系统不支持 Upkeep 的 App Store 更新能力。"))
      return
    }
    guard adamID != 0 else {
      completion(nil, Self.bridgeError(2, "缺少 App Store 应用编号，无法开始更新。"))
      return
    }

    self.adamID = adamID
    self.applicationURL = applicationURL
    progressHandler = progress
    completionHandler = completion
    selfRetainer = self
    isFinished = false
    downloadLifecycle = AppStoreDownloadLifecycle()
    purchaseGate.reset()

    guard let queueClass = NSClassFromString("CKDownloadQueue"),
      let queue = ObjC.call(queueClass, "sharedDownloadQueue")
    else {
      complete(installedPath: nil, error: Self.bridgeError(1, "当前系统不支持 Upkeep 的 App Store 更新能力。"))
      return
    }

    downloadQueue = queue
    observerToken = ObjC.call(queue, "addObserver:", self)

    let buyParameters =
      "productType=C&price=0&pg=default&appExtVrsId=0&pricingParameters=STDRDL&salableAdamId=\(adamID)"
    guard let purchaseClass = NSClassFromString("SSPurchase"),
      let purchase = ObjC.call(
        purchaseClass, "purchaseWithBuyParameters:", buyParameters as NSString)
        as? NSObject,
      let metadataClass = NSClassFromString("SSDownloadMetadata"),
      let allocatedMetadata = ObjC.call(metadataClass, "alloc"),
      let metadata = ObjC.call(allocatedMetadata, "initWithKind:", "software" as NSString)
        as? NSObject,
      let controllerClass = NSClassFromString("CKPurchaseController"),
      let controller = ObjC.call(controllerClass, "sharedPurchaseController")
    else {
      complete(installedPath: nil, error: Self.bridgeError(1, "当前系统不支持 Upkeep 的 App Store 更新能力。"))
      return
    }

    purchase.setValue(true, forKey: "isRedownload")
    purchase.setValue(true, forKey: "isUpdate")
    purchase.setValue(NSNumber(value: adamID), forKey: "itemIdentifier")
    metadata.setValue(NSNumber(value: adamID), forKey: "itemIdentifier")
    purchase.setValue(metadata, forKey: "downloadMetadata")

    let purchaseCompletion: ObjC.PurchaseCompletion = { [weak self] _, _, error, response in
      guard let self else { return }
      let downloads = (response as? NSObject)?.value(forKey: "downloads") as? [Any]
      self.purchaseCompleted(error: error, downloadCount: downloads?.count ?? 0)
    }
    ObjC.performPurchase(controller, purchase: purchase, completion: purchaseCompletion)
  }

  private func purchaseCompleted(error: NSError?, downloadCount: Int) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [self] in
        purchaseCompleted(error: error, downloadCount: downloadCount)
      }
      return
    }
    guard !isFinished else { return }
    if let error {
      complete(installedPath: nil, error: error)
    } else if !purchaseGate.completePurchase(downloadCount: downloadCount) {
      complete(installedPath: nil, error: Self.bridgeError(4, "App Store 没有开始下载此更新。"))
    }
  }

  func cancel() {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [self] in
        cancel()
      }
      return
    }

    if let currentDownload, let downloadQueue {
      ObjC.cancelDownload(downloadQueue, currentDownload)
    }
  }

  @objc(downloadQueue:changedWithAddition:)
  func downloadQueue(_ queue: Any, changedWithAddition download: Any) {}

  @objc(downloadQueue:statusChangedForDownload:)
  func downloadQueue(_ queue: Any, statusChangedForDownload download: Any) {
    guard Thread.isMainThread else {
      let event = AppStoreDownloadEvent(queue: queue, download: download)
      DispatchQueue.main.async { [self, event] in
        downloadQueue(event.queue, statusChangedForDownload: event.download)
      }
      return
    }
    guard downloadLifecycle.acceptsDownloadEvents, downloadMatchesSession(download) else { return }
    currentDownload = download as AnyObject
    refreshArtifactHardLinks()

    let status = (download as AnyObject).value(forKey: "status") as? NSObject
    let rawProgress = status?.value(forKey: "phasePercentComplete") as? NSNumber
    let phase =
      status?.responds(to: NSSelectorFromString("activePhase")) == true
      ? status?.value(forKey: "activePhase") as? String : nil
    if let progress = downloadLifecycle.progress(
      phase: phase, fractionCompleted: rawProgress?.doubleValue
    ) {
      progressHandler?(progress)
    }
  }

  @objc(downloadQueue:changedWithRemoval:)
  func downloadQueue(_ queue: Any, changedWithRemoval download: Any) {
    guard Thread.isMainThread else {
      let event = AppStoreDownloadEvent(queue: queue, download: download)
      DispatchQueue.main.async { [self, event] in
        downloadQueue(event.queue, changedWithRemoval: event.download)
      }
      return
    }
    guard downloadLifecycle.acceptsDownloadEvents, downloadMatchesSession(download) else { return }

    let status = (download as AnyObject).value(forKey: "status") as? NSObject
    let error = status?.value(forKey: "error") as? NSError
    let failed = (status?.value(forKey: "failed") as? NSNumber)?.boolValue ?? false
    let cancelled = (status?.value(forKey: "cancelled") as? NSNumber)?.boolValue ?? false
    let installedPath = (download as AnyObject).value(forKey: "installPath") as? String

    let canFallbackInstall =
      packageHardLinkURL != nil && receiptHardLinkURL != nil && applicationURL != nil
    switch Self.downloadCompletionDisposition(
      error: error,
      failed: failed,
      cancelled: cancelled,
      installedPath: installedPath,
      canFallbackInstall: canFallbackInstall
    ) {
    case .fallbackInstall:
      guard let packageHardLinkURL, let receiptHardLinkURL, let applicationURL else {
        complete(installedPath: nil, error: Self.bridgeError(5, "App Store 下载更新失败。"))
        return
      }
      guard downloadLifecycle.beginFallbackInstall() else { return }
      Self.logger.info("App Store 安装失败，转交安装助手，应用编号：\(self.adamID)")
      progressHandler?(.indeterminate("正在连接安装助手…"))
      DispatchQueue.global(qos: .userInitiated).async {
        let installError = Self.installDownloadedPackage(
          packageURL: packageHardLinkURL,
          receiptURL: receiptHardLinkURL,
          applicationURL: applicationURL,
          progress: { [weak self] progress in
            DispatchQueue.main.async { [weak self] in
              guard let self, !self.isFinished else { return }
              self.progressHandler?(progress)
            }
          }
        )
        DispatchQueue.main.async { [self] in
          complete(
            installedPath: installError == nil ? applicationURL.path : nil,
            error: installError
          )
        }
      }
      return
    case .complete(let installedPath, let error):
      complete(installedPath: installedPath, error: error)
    }
  }

  static func downloadCompletionDisposition(
    error: NSError?,
    failed: Bool,
    cancelled: Bool,
    installedPath: String?,
    canFallbackInstall: Bool
  ) -> AppStoreDownloadCompletionDisposition {
    if error?.domain == "PKInstallErrorDomain",
      error?.code == 201,
      canFallbackInstall
    {
      return .fallbackInstall
    }
    if let error {
      return .complete(installedPath: nil, error: error)
    }
    if failed {
      return .complete(
        installedPath: nil,
        error: bridgeError(5, "App Store 下载更新失败。")
      )
    }
    if cancelled {
      return .complete(
        installedPath: nil,
        error: bridgeError(6, "App Store 更新已取消。")
      )
    }
    return .complete(installedPath: installedPath, error: nil)
  }

  private func downloadMatchesSession(_ download: Any) -> Bool {
    let metadata = (download as AnyObject).value(forKey: "metadata") as? NSObject
    let itemIdentifier = metadata?.value(forKey: "itemIdentifier") as? NSNumber
    return purchaseGate.matches(
      expectedAdamID: adamID,
      itemIdentifier: itemIdentifier?.uint64Value
    )
  }

  static func downloadEventMatchesSession(
    purchaseHasCompleted: Bool,
    expectedAdamID: UInt64,
    itemIdentifier: UInt64?
  ) -> Bool {
    purchaseHasCompleted && itemIdentifier == expectedAdamID
  }

  private func refreshArtifactHardLinks() {
    guard let unmanagedRoot = PrivateFrameworks.load()?.downloadDirectory?(nil) else {
      return
    }
    let downloadRoot = unmanagedRoot.takeUnretainedValue() as String
    guard !downloadRoot.isEmpty else {
      return
    }

    let downloadFolderURL = URL(
      fileURLWithPath: downloadRoot,
      isDirectory: true
    ).appendingPathComponent(String(adamID), isDirectory: true)

    let children =
      (try? FileManager.default.contentsOfDirectory(
        at: downloadFolderURL,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: []
      )) ?? []

    var latestPackageURL: URL?
    var latestPackageDate: Date?
    var receiptURL: URL?

    for childURL in children {
      if childURL.lastPathComponent == "receipt" {
        receiptURL = childURL
      }
      guard childURL.pathExtension.lowercased() == "pkg" else { continue }
      let values = try? childURL.resourceValues(forKeys: [
        URLResourceKey.contentModificationDateKey,
        URLResourceKey.isRegularFileKey,
      ])
      guard values?.isRegularFile == true else { continue }
      let date = values?.contentModificationDate ?? .distantPast
      if latestPackageDate.map({ date > $0 }) ?? true {
        latestPackageDate = date
        latestPackageURL = childURL
      }
    }

    packageHardLinkURL = hardLink(for: latestPackageURL, existing: packageHardLinkURL)
    receiptHardLinkURL = hardLink(for: receiptURL, existing: receiptHardLinkURL)
  }

  private func hardLink(for sourceURL: URL?, existing existingURL: URL?) -> URL? {
    guard let sourceURL else { return existingURL }

    let sourceIdentifier = try? sourceURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
      .fileResourceIdentifier
    let existingIdentifier = try? existingURL?.resourceValues(forKeys: [.fileResourceIdentifierKey])
      .fileResourceIdentifier
    if let existingURL,
      let sourceIdentifier,
      let existingIdentifier,
      (sourceIdentifier as AnyObject).isEqual(existingIdentifier)
    {
      return existingURL
    }

    if let existingURL {
      try? FileManager.default.removeItem(at: existingURL.deletingLastPathComponent())
    }

    guard
      let temporaryDirectory = try? FileManager.default.url(
        for: .itemReplacementDirectory,
        in: .userDomainMask,
        appropriateFor: sourceURL,
        create: true
      )
    else {
      return nil
    }

    let hardLinkURL = temporaryDirectory.appendingPathComponent(
      Self.retainedArtifactFileName(for: sourceURL)
    )
    do {
      try FileManager.default.linkItem(at: sourceURL, to: hardLinkURL)
      return hardLinkURL
    } catch {
      try? FileManager.default.removeItem(at: temporaryDirectory)
      return nil
    }
  }

  static func retainedArtifactFileName(for sourceURL: URL) -> String {
    sourceURL.lastPathComponent
  }

  private func complete(installedPath: String?, error: NSError?) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [self] in
        complete(installedPath: installedPath, error: error)
      }
      return
    }

    finishLock.lock()
    let shouldFinish = !isFinished
    if shouldFinish {
      isFinished = true
    }
    finishLock.unlock()
    guard shouldFinish else { return }
    downloadLifecycle.finish()
    if let error {
      Self.logger.error("App Store 更新失败：\(error.localizedDescription, privacy: .public)")
    }

    if let observerToken, let downloadQueue {
      ObjC.callVoid(downloadQueue, "removeObserver:", observerToken)
    }

    let completion = completionHandler
    completionHandler = nil
    progressHandler = nil
    currentDownload = nil
    downloadQueue = nil
    observerToken = nil

    if let registrationURL = Self.launchServicesRegistrationURL(
      installedPath: installedPath,
      applicationURL: applicationURL,
      error: error
    ) {
      LSRegisterURL(registrationURL as NSURL, true)
    }

    completion?(installedPath, error)
    cleanupHardLinks()
    selfRetainer = nil
  }

  static func launchServicesRegistrationURL(
    installedPath: String?,
    applicationURL: URL?,
    error: NSError?
  ) -> URL? {
    guard error == nil else { return nil }
    if let installedPath, !installedPath.isEmpty {
      return URL(fileURLWithPath: installedPath).standardizedFileURL
    }
    return applicationURL?.standardizedFileURL
  }

  private func cleanupHardLinks() {
    if let packageHardLinkURL {
      try? FileManager.default.removeItem(at: packageHardLinkURL.deletingLastPathComponent())
    }
    if let receiptHardLinkURL {
      try? FileManager.default.removeItem(at: receiptHardLinkURL.deletingLastPathComponent())
    }
    packageHardLinkURL = nil
    receiptHardLinkURL = nil
  }

  private static func installDownloadedPackage(
    packageURL: URL,
    receiptURL: URL,
    applicationURL: URL,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) -> NSError? {
    switch AppStorePrivilegedInstaller.installDownloadedPackage(
      packageURL: packageURL,
      receiptURL: receiptURL,
      applicationURL: applicationURL,
      progress: progress
    ) {
    case .installed:
      return nil
    case .failed(let error):
      return error
    case .unavailable:
      break
    }

    fallbackInstallLock.lock()
    defer { fallbackInstallLock.unlock() }

    progress(.indeterminate("正在等待管理员授权…"))
    let authorizationResult = cachedFallbackInstallAuthorization()
    guard let authorization = authorizationResult.authorization else {
      return authorizationResult.error
    }
    guard let execute = authorizationExecuteWithPrivileges else {
      return bridgeError(1, "当前系统不支持 Upkeep 的 App Store 更新能力。")
    }

    let receiptDirectoryURL = applicationURL.appendingPathComponent(
      "Contents/_MASReceipt",
      isDirectory: true
    )
    let destinationReceiptURL = receiptDirectoryURL.appendingPathComponent("receipt")
    let script = """
      /usr/sbin/installer -dumplog -pkg "$1" -target / && \
      /bin/mkdir -p "$3" && /bin/cp -f "$2" "$4" && \
      /usr/sbin/chown 0:0 "$4" && /bin/chmod 644 "$4" && \
      /usr/bin/mdimport "$5" && /bin/echo UPKEEP_INSTALL_OK
      """
    let arguments = [
      "-c",
      script,
      "Upkeep",
      packageURL.path,
      receiptURL.path,
      receiptDirectoryURL.path,
      destinationReceiptURL.path,
      applicationURL.path,
    ]

    progress(.indeterminate("正在安装…"))
    var output = ""
    let status = withCArgumentVector(arguments) { argv in
      var pipe: UnsafeMutablePointer<FILE>?
      let result = "/bin/sh".withCString { path in
        execute(authorization, path, [], argv, &pipe)
      }
      if let pipe {
        output = readPipe(pipe)
      }
      return result
    }

    if status != errAuthorizationSuccess {
      return bridgeError(Int(status), "管理员安装进程无法启动。")
    }
    if !output.contains("UPKEEP_INSTALL_OK") {
      let message = output.isEmpty ? "系统安装器未能完成更新。" : output
      return bridgeError(3, message)
    }
    return nil
  }

  private static func cachedFallbackInstallAuthorization() -> (
    authorization: AuthorizationRef?, error: NSError?
  ) {
    if let authorization = fallbackInstallAuthorization {
      let status = copyExecuteRight(
        for: authorization,
        flags: [.extendRights]
      )
      if status == errAuthorizationSuccess {
        return (authorization, nil)
      }
      AuthorizationFree(authorization, [])
      fallbackInstallAuthorization = nil
    }

    var authorization: AuthorizationRef?
    var status = AuthorizationCreate(nil, nil, [], &authorization)
    guard status == errAuthorizationSuccess, let authorization else {
      return (nil, bridgeError(Int(status), "无法创建管理员授权请求。"))
    }

    status = copyExecuteRight(
      for: authorization,
      flags: [.interactionAllowed, .preAuthorize, .extendRights]
    )

    if status != errAuthorizationSuccess {
      AuthorizationFree(authorization, [])
      let message =
        status == errAuthorizationCanceled
        ? "已取消管理员授权。"
        : "未获得安装更新所需的管理员权限。"
      return (nil, bridgeError(Int(status), message))
    }

    fallbackInstallAuthorization = authorization
    return (authorization, nil)
  }

  private static func copyExecuteRight(
    for authorization: AuthorizationRef,
    flags: AuthorizationFlags
  ) -> OSStatus {
    kAuthorizationRightExecute.withCString { name in
      var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
      return withUnsafeMutablePointer(to: &item) { itemPointer in
        var rights = AuthorizationRights(count: 1, items: itemPointer)
        return AuthorizationCopyRights(
          authorization,
          &rights,
          nil,
          flags,
          nil
        )
      }
    }
  }

  private static func bridgeError(
    _ code: Int,
    _ description: String,
    underlying: Error? = nil
  ) -> NSError {
    var userInfo: [String: Any] = [NSLocalizedDescriptionKey: description]
    if let underlying {
      userInfo[NSUnderlyingErrorKey] = underlying
    }
    return NSError(domain: "Upkeep.AppStoreBridge", code: code, userInfo: userInfo)
  }
}

// Framework observer callbacks may arrive on a background queue. Transfer the
// event to the main queue before reading it or mutating the session state.
private struct AppStoreDownloadEvent: @unchecked Sendable {
  let queue: Any
  let download: Any
}

struct AppStoreDownloadLifecycle {
  private enum Stage { case receiving, fallbackInstall, finished }
  private var stage = Stage.receiving
  private var hasEnteredInstallation = false

  var acceptsDownloadEvents: Bool { stage == .receiving }

  mutating func beginFallbackInstall() -> Bool {
    guard acceptsDownloadEvents else { return false }
    stage = .fallbackInstall
    return true
  }

  mutating func finish() { stage = .finished }

  mutating func progress(phase: String?, fractionCompleted: Double?) -> UpdateProgress? {
    guard acceptsDownloadEvents else { return nil }
    let phase = phase?.lowercased() ?? ""
    if phase.contains("install") {
      hasEnteredInstallation = true
    }
    if hasEnteredInstallation { return .indeterminate("正在安装…") }
    if phase.contains("verif") { return .indeterminate("正在验证更新…") }
    if phase.contains("extract") { return .indeterminate("正在解压更新…") }
    let fraction = fractionCompleted.flatMap { $0.isFinite ? UpdateProgress.clamp($0) : nil }
    guard phase.contains("download") else {
      // Private framework phase names are not stable. Preserve reported progress
      // without claiming an unknown phase is necessarily a download.
      return UpdateProgress(
        fractionCompleted: fraction.flatMap { $0 < 1 ? $0 : nil },
        status: "正在处理更新…"
      )
    }
    if let fraction, fraction >= 1 {
      return .indeterminate("下载完成，等待安装…")
    }
    return UpdateProgress(fractionCompleted: fraction, status: "正在下载…")
  }
}

struct AppStorePurchaseGate {
  private(set) var purchaseHasCompleted = false

  mutating func reset() {
    purchaseHasCompleted = false
  }

  @discardableResult
  mutating func completePurchase(downloadCount: Int) -> Bool {
    guard downloadCount > 0 else {
      return false
    }
    purchaseHasCompleted = true
    return true
  }

  func matches(expectedAdamID: UInt64, itemIdentifier: UInt64?) -> Bool {
    AppStoreUpdateSession.downloadEventMatchesSession(
      purchaseHasCompleted: purchaseHasCompleted,
      expectedAdamID: expectedAdamID,
      itemIdentifier: itemIdentifier
    )
  }
}

enum AppStoreDownloadCompletionDisposition {
  case fallbackInstall
  case complete(installedPath: String?, error: NSError?)
}

private struct PrivateFrameworks: @unchecked Sendable {
  typealias DownloadDirectory = @convention(c) (UnsafeRawPointer?) -> Unmanaged<NSString>?

  let downloadDirectory: DownloadDirectory?

  static func load() -> PrivateFrameworks? {
    loaded
  }

  private static let loaded: PrivateFrameworks? = {
    let storeHandle = dlopen(
      "/System/Library/PrivateFrameworks/StoreFoundation.framework/StoreFoundation",
      RTLD_NOW | RTLD_LOCAL
    )
    let commerceHandle = dlopen(
      "/System/Library/PrivateFrameworks/CommerceKit.framework/CommerceKit",
      RTLD_NOW | RTLD_LOCAL
    )
    guard storeHandle != nil, commerceHandle != nil else { return nil }

    var downloadDirectory: DownloadDirectory?
    if let commerceHandle, let symbol = dlsym(commerceHandle, "CKDownloadDirectory") {
      downloadDirectory = unsafeBitCast(symbol, to: DownloadDirectory.self)
    }

    if let observerProtocol = NSProtocolFromString("CKDownloadQueueObserver") {
      class_addProtocol(AppStoreUpdateSession.self, observerProtocol)
    }

    guard NSClassFromString("SSPurchase") != nil,
      NSClassFromString("SSDownloadMetadata") != nil,
      NSClassFromString("CKPurchaseController") != nil,
      NSClassFromString("CKDownloadQueue") != nil
    else {
      return nil
    }

    return PrivateFrameworks(downloadDirectory: downloadDirectory)
  }()
}

private enum ObjC {
  typealias PurchaseCompletion =
    @convention(block) (
      AnyObject?, Bool, NSError?, AnyObject?
    ) -> Void

  nonisolated(unsafe) private static let msgSend: UnsafeMutableRawPointer = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else {
      preconditionFailure("objc_msgSend is unavailable")
    }
    return symbol
  }()

  static func call(_ type: AnyClass, _ selectorName: String) -> AnyObject? {
    typealias Fn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
    return unsafeBitCast(msgSend, to: Fn.self)(type, NSSelectorFromString(selectorName))?
      .takeUnretainedValue()
  }

  static func call(_ type: AnyClass, _ selectorName: String, _ object: AnyObject?) -> AnyObject? {
    typealias Fn = @convention(c) (AnyClass, Selector, AnyObject?) -> Unmanaged<AnyObject>?
    return unsafeBitCast(msgSend, to: Fn.self)(type, NSSelectorFromString(selectorName), object)?
      .takeUnretainedValue()
  }

  static func call(_ target: AnyObject, _ selectorName: String) -> AnyObject? {
    typealias Fn = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    return unsafeBitCast(msgSend, to: Fn.self)(target, NSSelectorFromString(selectorName))?
      .takeUnretainedValue()
  }

  static func call(_ target: AnyObject, _ selectorName: String, _ object: AnyObject?) -> AnyObject?
  {
    typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> Unmanaged<AnyObject>?
    return unsafeBitCast(msgSend, to: Fn.self)(
      target,
      NSSelectorFromString(selectorName),
      object
    )?.takeUnretainedValue()
  }

  static func callVoid(_ target: AnyObject, _ selectorName: String, _ object: AnyObject?) {
    typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
    unsafeBitCast(msgSend, to: Fn.self)(target, NSSelectorFromString(selectorName), object)
  }

  static func performPurchase(
    _ controller: AnyObject,
    purchase: AnyObject,
    completion: PurchaseCompletion
  ) {
    typealias Fn =
      @convention(c) (AnyObject, Selector, AnyObject, UInt64, PurchaseCompletion) ->
      Void
    unsafeBitCast(msgSend, to: Fn.self)(
      controller,
      NSSelectorFromString("performPurchase:withOptions:completionHandler:"),
      purchase,
      0,
      completion
    )
  }

  static func cancelDownload(_ queue: AnyObject, _ download: AnyObject) {
    typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, ObjCBool, ObjCBool) -> Void
    unsafeBitCast(msgSend, to: Fn.self)(
      queue,
      NSSelectorFromString("cancelDownload:promptToConfirm:askToDelete:"),
      download,
      ObjCBool(false),
      ObjCBool(false)
    )
  }
}

private typealias AuthorizationExecuteWithPrivilegesFn =
  @convention(c) (
    AuthorizationRef,
    UnsafePointer<CChar>,
    AuthorizationFlags,
    UnsafePointer<UnsafeMutablePointer<CChar>?>,
    UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
  ) -> OSStatus

private let authorizationExecuteWithPrivileges: AuthorizationExecuteWithPrivilegesFn? = {
  let handle =
    dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW | RTLD_LOCAL)
    ?? dlopen("/usr/lib/libSystem.B.dylib", RTLD_NOW | RTLD_LOCAL)
  guard let handle, let symbol = dlsym(handle, "AuthorizationExecuteWithPrivileges") else {
    return nil
  }
  return unsafeBitCast(symbol, to: AuthorizationExecuteWithPrivilegesFn.self)
}()

private func withCArgumentVector<T>(
  _ arguments: [String],
  _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> T
) -> T {
  var pointers: [UnsafeMutablePointer<CChar>?] = arguments.map { argument in
    argument.withCString { strdup($0) }
  }
  pointers.append(nil)
  defer {
    for pointer in pointers {
      free(pointer)
    }
  }
  return pointers.withUnsafeBufferPointer { buffer in
    body(buffer.baseAddress!)
  }
}

private func readPipe(_ pipe: UnsafeMutablePointer<FILE>) -> String {
  var output = Data()
  var buffer = [UInt8](repeating: 0, count: 4096)
  while true {
    let count = buffer.withUnsafeMutableBytes { rawBuffer in
      fread(rawBuffer.baseAddress, 1, rawBuffer.count, pipe)
    }
    if count == 0 {
      break
    }
    output.append(contentsOf: buffer.prefix(count))
  }
  fclose(pipe)
  return String(data: output, encoding: .utf8) ?? ""
}
