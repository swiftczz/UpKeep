import CryptoKit
import Foundation

enum ApplicationPackageInstallerError: LocalizedError {
  case insecureDownload
  case downloadFailed
  case checksumMismatch
  case invalidUpdateSignature
  case unsupportedPackage
  case missingApplication
  case bundleIdentifierMismatch
  case invalidSignature
  case teamIdentifierMismatch

  var errorDescription: String? {
    switch self {
    case .insecureDownload:
      return "更新包必须通过 HTTPS 下载。"
    case .downloadFailed:
      return "更新包下载失败。"
    case .checksumMismatch:
      return "更新包校验失败，已中止安装。"
    case .invalidUpdateSignature:
      return "Sparkle 更新包签名校验失败，已中止安装。"
    case .unsupportedPackage:
      return "不支持此更新包格式。"
    case .missingApplication:
      return "更新包中没有找到可安装的应用。"
    case .bundleIdentifierMismatch:
      return "更新包中的应用与当前安装的应用不一致。"
    case .invalidSignature:
      return "更新包的代码签名无效。"
    case .teamIdentifierMismatch:
      return "更新包的开发者签名与当前应用不一致。"
    }
  }
}

enum ApplicationPackageInstaller {
  static func install(
    from packageURL: URL,
    replacing application: AppRecord,
    expectedSHA512: String?,
    expectedSHA256: String? = nil,
    expectedEd25519Signature: String? = nil,
    ed25519PublicKey: String? = nil,
    requiresValidSignature: Bool = false,
    requiresTeamIdentifier: Bool = false,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    guard SecureUpdateURL.https(packageURL) != nil else {
      throw ApplicationPackageInstallerError.insecureDownload
    }

    let fileManager = FileManager.default
    let workingDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("Upkeep-update-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: workingDirectory) }

    progress(.indeterminate("正在下载…"))
    let downloadedURL = try await download(
      from: packageURL,
      into: workingDirectory,
      progress: progress
    )

    if expectedSHA512 != nil || expectedSHA256 != nil
      || expectedEd25519Signature != nil || ed25519PublicKey != nil
    {
      progress(.indeterminate("正在校验…"))
      try verifyChecksums(
        of: downloadedURL,
        expectedSHA512: expectedSHA512,
        expectedSHA256: expectedSHA256
      )
    }
    let hasVerifiedUpdateSignature: Bool
    if let expectedEd25519Signature, let ed25519PublicKey {
      try verifyEd25519Signature(
        of: downloadedURL,
        signature: expectedEd25519Signature,
        publicKey: ed25519PublicKey
      )
      hasVerifiedUpdateSignature = true
    } else if expectedEd25519Signature != nil || ed25519PublicKey != nil {
      throw ApplicationPackageInstallerError.invalidUpdateSignature
    } else {
      hasVerifiedUpdateSignature = false
    }

    progress(.indeterminate("正在解压…"))
    let extractedApplicationURL = try extractApplication(
      from: downloadedURL,
      into: workingDirectory.appendingPathComponent("extracted", isDirectory: true)
    )

    try verifyIdentity(
      of: extractedApplicationURL,
      matching: application,
      requiresValidSignature: requiresValidSignature,
      requiresTeamIdentifier: requiresTeamIdentifier,
      hasVerifiedUpdateSignature: hasVerifiedUpdateSignature
    )

    try await ApplicationProcess.quit(application)
    progress(.indeterminate("正在安装…"))
    _ = try fileManager.replaceItemAt(
      application.applicationURL,
      withItemAt: extractedApplicationURL,
      backupItemName: nil,
      options: .usingNewMetadataOnly
    )
    _ = try? await ProcessRunner.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/xattr"),
      arguments: ["-dr", "com.apple.quarantine", application.applicationURL.path]
    )
  }

  static func verifySHA512(of fileURL: URL, expected: String) throws {
    let data = try Data(contentsOf: fileURL)
    try verifySHA512(data, expected: expected)
  }

  static func verifySHA256(of fileURL: URL, expected: String) throws {
    let data = try Data(contentsOf: fileURL)
    try verifySHA256(data, expected: expected)
  }

  static func verifyEd25519Signature(
    of fileURL: URL,
    signature: String,
    publicKey: String
  ) throws {
    guard
      let signatureData = Data(base64Encoded: signature.filter { !$0.isWhitespace }),
      let publicKeyData = Data(base64Encoded: publicKey.filter { !$0.isWhitespace }),
      let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    else {
      throw ApplicationPackageInstallerError.invalidUpdateSignature
    }

    let packageData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
    guard verifier.isValidSignature(signatureData, for: packageData) else {
      throw ApplicationPackageInstallerError.invalidUpdateSignature
    }
  }

  private static func verifyChecksums(
    of fileURL: URL,
    expectedSHA512: String?,
    expectedSHA256: String?
  ) throws {
    let data = try Data(contentsOf: fileURL)
    if let expectedSHA512 {
      try verifySHA512(data, expected: expectedSHA512)
    }
    if let expectedSHA256 {
      try verifySHA256(data, expected: expectedSHA256)
    }
  }

  private static func verifySHA512(_ data: Data, expected: String) throws {
    let digest = Data(SHA512.hash(data: data)).base64EncodedString()
    let normalizedExpected = expected.filter { !$0.isWhitespace }
    guard digest == normalizedExpected else {
      throw ApplicationPackageInstallerError.checksumMismatch
    }
  }

  private static func verifySHA256(_ data: Data, expected: String) throws {
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let normalizedExpected = expected.filter { !$0.isWhitespace }.lowercased()
    guard digest == normalizedExpected else {
      throw ApplicationPackageInstallerError.checksumMismatch
    }
  }

  static func architectureScore(of fileName: String, architecture: MacCPUArchitecture) -> Int {
    let name = fileName.lowercased()
    let isArm = name.contains("arm64") || name.contains("aarch64") || name.contains("apple-silicon")
    let isX64 =
      name.contains("x64") || name.contains("x86_64") || name.contains("amd64")
      || name.contains("intel")
    let isUniversal = name.contains("universal")

    switch architecture {
    case .arm64:
      if isArm && !isX64 { return 100 }
      if isUniversal { return 80 }
      if !isArm && !isX64 { return 40 }
      if isX64 { return 20 }
      return 0
    case .x64:
      if isX64 && !isArm { return 100 }
      if isUniversal { return 80 }
      if !isArm && !isX64 { return 40 }
      return 0
    }
  }

  static func packageKindScore(of fileName: String) -> Int {
    let name = fileName.lowercased()
    if name.hasSuffix(".blockmap") || name.hasSuffix(".exe") || name.hasSuffix(".msi")
      || name.hasSuffix(".deb") || name.hasSuffix(".rpm") || name.hasSuffix(".appimage")
    {
      return 0
    }
    if name.hasSuffix(".zip") { return 30 }
    if name.hasSuffix(".dmg") { return 20 }
    if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return 10 }
    return 0
  }

  static func isPotentiallyInstallablePackageURL(_ url: URL) -> Bool {
    packageKindScore(of: url.lastPathComponent) > 0 || isGitHubReleaseAssetAPIURL(url)
  }

  static func isGitHubReleaseAssetAPIURL(_ url: URL) -> Bool {
    guard url.host?.lowercased() == "api.github.com" else {
      return false
    }
    let components = url.pathComponents.filter { $0 != "/" }
    guard components.count == 6,
      components[0].lowercased() == "repos",
      components[3].lowercased() == "releases",
      components[4].lowercased() == "assets"
    else {
      return false
    }
    return Int(components[5]) != nil
  }

  static func downloadRequest(for url: URL) -> URLRequest {
    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 60
    )
    request.setValue("Upkeep", forHTTPHeaderField: "User-Agent")
    request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
    request.setValue("no-cache", forHTTPHeaderField: "Pragma")
    if isGitHubReleaseAssetAPIURL(url) {
      request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
      request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    }
    return request
  }

  static func downloadSessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.waitsForConnectivity = true
    configuration.httpMaximumConnectionsPerHost = 4
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 30 * 60
    return configuration
  }

  private static func download(
    from url: URL,
    into directory: URL,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws -> URL {
    let downloader = FileDownloadTask(progress: progress)
    defer { downloader.invalidate() }

    var lastError: (any Error)?
    let totalAttempts = NetworkRetryPolicy.downloadAttempts
    for attempt in 0..<totalAttempts {
      do {
        let download = try await downloader.download(from: url)
        guard let fileName = supportedPackageFileName(
          suggestedFilename: download.suggestedFilename,
          sourceURL: url
        ) else {
          try? FileManager.default.removeItem(at: download.url)
          throw ApplicationPackageInstallerError.unsupportedPackage
        }
        let destinationURL = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
          try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: download.url, to: destinationURL)
        return destinationURL
      } catch let error as CancellationError {
        throw error
      } catch {
        lastError = error
        guard NetworkRetryPolicy.shouldRetry(error), attempt < totalAttempts - 1 else {
          throw NetworkRetryPolicy.presentableError(error, attempts: attempt + 1)
        }
        progress(.indeterminate("连接中断，正在重试（\(attempt + 2)/\(totalAttempts)）…"))
        try await NetworkRetryPolicy.sleepBeforeRetry(
          afterAttempt: attempt,
          retryAfter: NetworkRetryPolicy.retryAfterDelay(from: error)
        )
      }
    }
    let error = lastError ?? ApplicationPackageInstallerError.downloadFailed
    throw NetworkRetryPolicy.presentableError(error, attempts: totalAttempts)
  }

  static func supportedPackageFileName(
    suggestedFilename: String?,
    sourceURL: URL
  ) -> String? {
    for candidate in [suggestedFilename, sourceURL.lastPathComponent] {
      guard let candidate else { continue }
      let fileName = (candidate as NSString).lastPathComponent
      guard fileName != ".", fileName != "..",
        packageKindScore(of: fileName) > 0
      else {
        continue
      }
      return fileName
    }
    return nil
  }

  private static func extractApplication(from packageURL: URL, into directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileName = packageURL.lastPathComponent.lowercased()

    if fileName.hasSuffix(".zip") {
      try run("/usr/bin/ditto", ["-xk", packageURL.path, directory.path])
    } else if fileName.hasSuffix(".tar.gz") || fileName.hasSuffix(".tgz") {
      try run("/usr/bin/tar", ["-xzf", packageURL.path, "-C", directory.path])
    } else if fileName.hasSuffix(".dmg") {
      return try applicationFromDiskImage(packageURL, stagingDirectory: directory)
    } else {
      throw ApplicationPackageInstallerError.unsupportedPackage
    }

    guard let applicationURL = findApplication(in: directory) else {
      throw ApplicationPackageInstallerError.missingApplication
    }
    return applicationURL
  }

  private static func applicationFromDiskImage(
    _ diskImageURL: URL,
    stagingDirectory: URL
  ) throws -> URL {
    let mountPoint = stagingDirectory.appendingPathComponent("volume", isDirectory: true)
    try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

    try run(
      "/usr/bin/hdiutil",
      [
        "attach", diskImageURL.path, "-nobrowse", "-readonly", "-noverify",
        "-mountpoint", mountPoint.path,
      ]
    )
    defer {
      try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet", "-force"])
    }

    guard let mountedApplicationURL = findApplication(in: mountPoint) else {
      throw ApplicationPackageInstallerError.missingApplication
    }

    let stagedURL = stagingDirectory.appendingPathComponent(
      mountedApplicationURL.lastPathComponent,
      isDirectory: true
    )
    try run("/usr/bin/ditto", [mountedApplicationURL.path, stagedURL.path])
    return stagedURL
  }

  private static func findApplication(in directory: URL) -> URL? {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isPackageKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else {
      return nil
    }

    for case let itemURL as URL in enumerator {
      guard itemURL.pathExtension.lowercased() == "app" else {
        continue
      }
      let values = try? itemURL.resourceValues(forKeys: [.isSymbolicLinkKey])
      if values?.isSymbolicLink == true {
        continue
      }
      return itemURL
    }
    return nil
  }

  private static func verifyIdentity(
    of candidateURL: URL,
    matching application: AppRecord,
    requiresValidSignature: Bool,
    requiresTeamIdentifier: Bool,
    hasVerifiedUpdateSignature: Bool
  ) throws {
    guard let bundle = Bundle(url: candidateURL),
      let bundleIdentifier = bundle.bundleIdentifier,
      bundleIdentifier == application.bundleIdentifier
    else {
      throw ApplicationPackageInstallerError.bundleIdentifierMismatch
    }

    let installedTeam = ApplicationCodeSigning.teamIdentifier(at: application.applicationURL)
    let candidateTeam = ApplicationCodeSigning.teamIdentifier(at: candidateURL)
    if (requiresValidSignature || requiresTeamIdentifier)
      && !ApplicationCodeSigning.signatureIsValid(at: candidateURL)
    {
      throw ApplicationPackageInstallerError.invalidSignature
    }
    if !teamIdentifiersMatch(
      installed: installedTeam,
      candidate: candidateTeam,
      requiresTeamIdentifier: requiresTeamIdentifier,
      hasVerifiedUpdateSignature: hasVerifiedUpdateSignature
    ) {
      throw ApplicationPackageInstallerError.teamIdentifierMismatch
    }
  }

  static func teamIdentifiersMatch(
    installed: String?,
    candidate: String?,
    requiresTeamIdentifier: Bool,
    hasVerifiedUpdateSignature: Bool
  ) -> Bool {
    if let installed, let candidate {
      return installed == candidate
    }
    if requiresTeamIdentifier {
      return installed == nil && hasVerifiedUpdateSignature
    }
    return true
  }

  private static func run(_ executable: String, _ arguments: [String]) throws {
    try ProcessRunner.blockingRun(
      executableURL: URL(fileURLWithPath: executable),
      arguments: arguments
    )
  }
}

private struct DownloadedFile: Sendable {
  let url: URL
  let suggestedFilename: String?
}

private final class FileDownloadTask: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let progress: @Sendable (UpdateProgress) -> Void
  private let lock = NSLock()
  private var continuation: CheckedContinuation<DownloadedFile, any Error>?
  private var activeTask: URLSessionDownloadTask?
  private var stagedURL: URL?
  private var isCancelled = false

  private lazy var session = URLSession(
    configuration: ApplicationPackageInstaller.downloadSessionConfiguration(),
    delegate: self,
    delegateQueue: nil
  )

  init(
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) {
    self.progress = progress
  }

  func download(from url: URL) async throws -> DownloadedFile {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        start(url, continuation: continuation)
      }
    } onCancel: {
      cancel()
    }
  }

  func invalidate() {
    cancel()
    session.finishTasksAndInvalidate()
  }

  private func start(
    _ url: URL,
    continuation: CheckedContinuation<DownloadedFile, any Error>
  ) {
    lock.lock()
    guard !isCancelled else {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }

    self.continuation = continuation
    stagedURL = nil
    let task = session.downloadTask(
      with: ApplicationPackageInstaller.downloadRequest(for: url)
    )
    activeTask = task
    lock.unlock()
    task.resume()
  }

  private func cancel() {
    lock.lock()
    isCancelled = true
    let task = activeTask
    lock.unlock()
    task?.cancel()
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard totalBytesExpectedToWrite > 0 else { return }
    progress(
      UpdateProgress(
        fractionCompleted: UpdateProgress.clamp(
          Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        ),
        status: "正在下载…"
      )
    )
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("Upkeep-download-\(UUID().uuidString)")
    do {
      try FileManager.default.copyItem(at: location, to: destination)
      lock.lock()
      stagedURL = destination
      lock.unlock()
    } catch {
      finish(.failure(error))
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    if let error {
      if (error as? URLError)?.code == .cancelled {
        finish(.failure(CancellationError()))
      } else {
        finish(.failure(error))
      }
      return
    }

    if let response = task.response as? HTTPURLResponse,
      !(200..<300).contains(response.statusCode)
    {
      finish(
        .failure(
          UpdateHTTPError.statusCode(
            response.statusCode,
            retryAfter: NetworkRetryPolicy.retryAfterDelay(from: response)
          )
        )
      )
      return
    }

    lock.lock()
    let stagedURL = stagedURL
    lock.unlock()
    if let stagedURL {
      finish(
        .success(
          DownloadedFile(
            url: stagedURL,
            suggestedFilename: task.response?.suggestedFilename
          )
        )
      )
    } else {
      finish(.failure(ApplicationPackageInstallerError.downloadFailed))
    }
  }

  private func finish(_ result: Result<DownloadedFile, any Error>) {
    lock.lock()
    guard let continuation else {
      lock.unlock()
      return
    }
    let discardedURL: URL?
    if case .failure = result {
      discardedURL = stagedURL
    } else {
      discardedURL = nil
    }
    self.continuation = nil
    activeTask = nil
    stagedURL = nil
    lock.unlock()

    if let discardedURL {
      try? FileManager.default.removeItem(at: discardedURL)
    }
    continuation.resume(with: result)
  }
}
