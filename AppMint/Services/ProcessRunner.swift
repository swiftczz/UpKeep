import Darwin
import Foundation

struct ProcessOutput: Sendable {
  let data: Data
  let errorData: Data
  let terminationStatus: Int32

  var standardOutput: String {
    String(decoding: data, as: UTF8.self)
  }

  var standardError: String {
    String(decoding: errorData, as: UTF8.self)
  }

  var combinedText: String {
    let error = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
    if !error.isEmpty {
      return error
    }
    return standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

enum ProcessRunnerError: LocalizedError {
  case failed(status: Int32, message: String)

  var errorDescription: String? {
    switch self {
    case .failed(let status, let message):
      if message.isEmpty {
        return "命令执行失败（状态码 \(status)）。"
      }
      return message
    }
  }
}

enum ProcessRunner {
  static func run(
    executableURL: URL,
    arguments: [String],
    captureTTY: Bool = false,
    onOutput: (@Sendable (String) -> Void)? = nil
  ) async throws -> ProcessOutput {
    let output = try await Task.detached(priority: .userInitiated) {
      try runSynchronously(
        executableURL: executableURL,
        arguments: arguments,
        captureTTY: captureTTY,
        onOutput: onOutput
      )
    }.value

    guard output.terminationStatus == 0 else {
      throw ProcessRunnerError.failed(status: output.terminationStatus, message: output.combinedText)
    }

    return output
  }

  private static func runSynchronously(
    executableURL: URL,
    arguments: [String],
    captureTTY: Bool,
    onOutput: (@Sendable (String) -> Void)?
  ) throws -> ProcessOutput {
    if captureTTY, let tty = PseudoTerminal.make() {
      return try runOnTTY(
        executableURL: executableURL,
        arguments: arguments,
        terminal: tty,
        onOutput: onOutput
      )
    }

    return try runOnPipes(
      executableURL: executableURL,
      arguments: arguments,
      onOutput: onOutput
    )
  }

  private static func runOnPipes(
    executableURL: URL,
    arguments: [String],
    onOutput: (@Sendable (String) -> Void)?
  ) throws -> ProcessOutput {
    let process = Process()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let collectedOutput = DataBuffer()
    let collectedError = DataBuffer()

    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    attachOutputHandler(
      outputPipe.fileHandleForReading,
      buffer: collectedOutput,
      onOutput: onOutput
    )
    attachOutputHandler(
      errorPipe.fileHandleForReading,
      buffer: collectedError,
      onOutput: onOutput
    )

    try process.run()

    if onOutput == nil {
      collectedOutput.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
      collectedError.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
    }

    process.waitUntilExit()
    outputPipe.fileHandleForReading.readabilityHandler = nil
    errorPipe.fileHandleForReading.readabilityHandler = nil
    drain(outputPipe.fileHandleForReading, into: collectedOutput, onOutput: onOutput)
    drain(errorPipe.fileHandleForReading, into: collectedError, onOutput: onOutput)

    return ProcessOutput(
      data: collectedOutput.data,
      errorData: collectedError.data,
      terminationStatus: process.terminationStatus
    )
  }

  private static func runOnTTY(
    executableURL: URL,
    arguments: [String],
    terminal: PseudoTerminal,
    onOutput: (@Sendable (String) -> Void)?
  ) throws -> ProcessOutput {
    let process = Process()
    let collectedOutput = DataBuffer()
    let slaveOutput = terminal.makeSlaveHandle()
    let slaveError = terminal.makeSlaveHandle()
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = "xterm-256color"
    environment["COLUMNS"] = "120"
    environment["LINES"] = "24"
    environment["HOMEBREW_DOWNLOAD_CONCURRENCY"] = "1"
    environment.removeValue(forKey: "CI")

    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = slaveOutput
    process.standardError = slaveError

    attachOutputHandler(terminal.master, buffer: collectedOutput, onOutput: onOutput)

    try process.run()
    try? slaveOutput.close()
    try? slaveError.close()
    terminal.closeSlave()

    if onOutput == nil {
      collectedOutput.append(terminal.master.readDataToEndOfFile())
    }

    process.waitUntilExit()
    terminal.master.readabilityHandler = nil
    drain(terminal.master, into: collectedOutput, onOutput: onOutput)

    let data = collectedOutput.data
    return ProcessOutput(
      data: data,
      errorData: Data(),
      terminationStatus: process.terminationStatus
    )
  }

  private static func attachOutputHandler(
    _ handle: FileHandle,
    buffer: DataBuffer,
    onOutput: (@Sendable (String) -> Void)?
  ) {
    guard onOutput != nil else { return }
    handle.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      buffer.append(data)
      onOutput?(String(decoding: data, as: UTF8.self))
    }
  }

  private static func drain(
    _ handle: FileHandle,
    into buffer: DataBuffer,
    onOutput: (@Sendable (String) -> Void)?
  ) {
    let remaining = (try? handle.readToEnd()) ?? Data()
    guard !remaining.isEmpty else { return }
    buffer.append(remaining)
    onOutput?(String(decoding: remaining, as: UTF8.self))
  }
}

private final class DataBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Data()

  var data: Data {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func append(_ data: Data) {
    lock.lock()
    storage.append(data)
    lock.unlock()
  }
}

private final class PseudoTerminal {
  let master: FileHandle
  private let slaveFD: Int32
  private let lock = NSLock()
  private var slaveClosed = false

  static func make(columns: UInt16 = 120, rows: UInt16 = 24) -> PseudoTerminal? {
    let masterFD = posix_openpt(O_RDWR | O_NOCTTY)
    guard masterFD >= 0 else { return nil }
    guard grantpt(masterFD) == 0, unlockpt(masterFD) == 0, let slavePath = ptsname(masterFD) else {
      Darwin.close(masterFD)
      return nil
    }

    let slaveFD = Darwin.open(slavePath, O_RDWR | O_NOCTTY)
    guard slaveFD >= 0 else {
      Darwin.close(masterFD)
      return nil
    }

    _ = fcntl(masterFD, F_SETFD, FD_CLOEXEC)
    var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
    _ = ioctl(slaveFD, TIOCSWINSZ, &size)

    return PseudoTerminal(
      master: FileHandle(fileDescriptor: masterFD, closeOnDealloc: true),
      slaveFD: slaveFD
    )
  }

  private init(master: FileHandle, slaveFD: Int32) {
    self.master = master
    self.slaveFD = slaveFD
  }

  func makeSlaveHandle() -> FileHandle {
    FileHandle(fileDescriptor: dup(slaveFD), closeOnDealloc: true)
  }

  func closeSlave() {
    lock.lock()
    defer { lock.unlock() }
    guard !slaveClosed else { return }
    slaveClosed = true
    Darwin.close(slaveFD)
  }

  deinit {
    closeSlave()
  }
}
