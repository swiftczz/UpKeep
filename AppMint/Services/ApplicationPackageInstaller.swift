import CryptoKit
import Foundation

enum ApplicationPackageInstallerError: LocalizedError {
  case insecureDownload
  case downloadFailed
  case checksumMismatch
  case unsupportedPackage
  case missingApplication
  case bundleIdentifierMismatch
  case teamIdentifierMismatch
  case applicationStillRunning(String)

  var errorDescription: String? {
    switch self {
    case .insecureDownload:
      return "更新包必须通过 HTTPS 下载。"
    case .downloadFailed:
      return "更新包下载失败。"
    case .checksumMismatch:
      return "更新包校验失败，已中止安装。"
    case .unsupportedPackage:
      return "不支持此更新包格式。"
    case .missingApplication:
      return "更新包中没有找到可安装的应用。"
    case .bundleIdentifierMismatch:
      return "更新包中的应用与当前安装的应用不一致。"
    case .teamIdentifierMismatch:
      return "更新包的开发者签名与当前应用不一致。"
    case .applicationStillRunning(let name):
      return "请先退出 \(name) 后再更新。"
    }
  }
}

enum ApplicationPackageInstaller {
  static func install(
    from packageURL: URL,
    replacing application: AppRecord,
    expectedSHA512: String?,
    expectedSHA256: String? = nil,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    guard SecureUpdateURL.https(packageURL) != nil else {
      throw ApplicationPackageInstallerError.insecureDownload
    }

    let fileManager = FileManager.default
    let workingDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("AppMint-update-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: workingDirectory) }

    progress(.indeterminate("正在下载…"))
    let downloadedURL = try await download(
      from: packageURL,
      to: workingDirectory.appendingPathComponent(packageURL.lastPathComponent),
      progress: progress
    )

    if expectedSHA512 != nil || expectedSHA256 != nil {
      progress(.indeterminate("正在校验…"))
      if let expectedSHA512 {
        try verifySHA512(of: downloadedURL, expected: expectedSHA512)
      }
      if let expectedSHA256 {
        try verifySHA256(of: downloadedURL, expected: expectedSHA256)
      }
    }

    progress(.indeterminate("正在解压…"))
    let extractedApplicationURL = try extractApplication(
      from: downloadedURL,
      into: workingDirectory.appendingPathComponent("extracted", isDirectory: true)
    )

    try verifyIdentity(
      of: extractedApplicationURL,
      matching: application
    )

    try await ApplicationProcess.quit(application)
    progress(.indeterminate("正在安装…"))
    _ = try fileManager.replaceItemAt(
      application.applicationURL,
      withItemAt: extractedApplicationURL,
      backupItemName: nil,
      options: .usingNewMetadataOnly
    )
    try? await ProcessRunner.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/xattr"),
      arguments: ["-dr", "com.apple.quarantine", application.applicationURL.path]
    )
  }

  static func verifySHA512(of fileURL: URL, expected: String) throws {
    let data = try Data(contentsOf: fileURL)
    let digest = Data(SHA512.hash(data: data)).base64EncodedString()
    let normalizedExpected = expected.filter { !$0.isWhitespace }
    guard digest == normalizedExpected else {
      throw ApplicationPackageInstallerError.checksumMismatch
    }
  }

  static func verifySHA256(of fileURL: URL, expected: String) throws {
    let data = try Data(contentsOf: fileURL)
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

  private static func download(
    from url: URL,
    to destinationURL: URL,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws -> URL {
    let downloadedURL = try await FileDownloadTask.download(from: url, progress: progress)
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      try FileManager.default.removeItem(at: destinationURL)
    }
    try FileManager.default.moveItem(at: downloadedURL, to: destinationURL)
    return destinationURL
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

  private static func verifyIdentity(of candidateURL: URL, matching application: AppRecord) throws {
    guard let bundle = Bundle(url: candidateURL),
      let bundleIdentifier = bundle.bundleIdentifier,
      bundleIdentifier == application.bundleIdentifier
    else {
      throw ApplicationPackageInstallerError.bundleIdentifierMismatch
    }

    let installedTeam = ApplicationCodeSigning.teamIdentifier(at: application.applicationURL)
    let candidateTeam = ApplicationCodeSigning.teamIdentifier(at: candidateURL)
    if let installedTeam, let candidateTeam, installedTeam != candidateTeam {
      throw ApplicationPackageInstallerError.teamIdentifierMismatch
    }
  }

  private static func run(_ executable: String, _ arguments: [String]) throws {
    try ProcessRunner.blockingRun(
      executableURL: URL(fileURLWithPath: executable),
      arguments: arguments
    )
  }
}

extension ProcessRunner {
  @discardableResult
  static func blockingRun(
    executableURL: URL,
    arguments: [String]
  ) throws -> ProcessOutput {
    let process = Process()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()

    let output = ProcessOutput(
      data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
      errorData: errorPipe.fileHandleForReading.readDataToEndOfFile(),
      terminationStatus: process.terminationStatus
    )
    guard output.terminationStatus == 0 else {
      let message = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
      throw ProcessRunnerError.failed(status: output.terminationStatus, message: message)
    }
    return output
  }
}

private final class FileDownloadTask: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let progress: @Sendable (UpdateProgress) -> Void
  private var continuation: CheckedContinuation<URL, any Error>?
  private var session: URLSession?
  private var stagedURL: URL?

  static func download(
    from url: URL,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      let task = FileDownloadTask(progress: progress, continuation: continuation)
      task.start(url)
    }
  }

  private init(
    progress: @escaping @Sendable (UpdateProgress) -> Void,
    continuation: CheckedContinuation<URL, any Error>
  ) {
    self.progress = progress
    self.continuation = continuation
  }

  private func start(_ url: URL) {
    let session = URLSession(
      configuration: .ephemeral,
      delegate: self,
      delegateQueue: nil
    )
    self.session = session
    session.downloadTask(with: url).resume()
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
      .appendingPathComponent("AppMint-download-\(UUID().uuidString)")
    do {
      try FileManager.default.copyItem(at: location, to: destination)
      stagedURL = destination
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
      finish(.failure(error))
      return
    }
    if let stagedURL {
      finish(.success(stagedURL))
    } else {
      finish(.failure(ApplicationPackageInstallerError.downloadFailed))
    }
  }

  private func finish(_ result: Result<URL, any Error>) {
    session?.finishTasksAndInvalidate()
    session = nil
    continuation?.resume(with: result)
    continuation = nil
  }
}
