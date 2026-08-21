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
    onOutput: (@Sendable (String) -> Void)? = nil
  ) async throws -> ProcessOutput {
    let output = try await Task.detached(priority: .userInitiated) {
      let process = Process()
      let outputPipe = Pipe()
      let errorPipe = Pipe()
      let collectedOutput = DataBuffer()
      let collectedError = DataBuffer()

      process.executableURL = executableURL
      process.arguments = arguments
      process.standardOutput = outputPipe
      process.standardError = errorPipe

      if onOutput != nil {
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
          let data = handle.availableData
          guard !data.isEmpty else { return }
          collectedOutput.append(data)
          onOutput?(String(decoding: data, as: UTF8.self))
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
          let data = handle.availableData
          guard !data.isEmpty else { return }
          collectedError.append(data)
          onOutput?(String(decoding: data, as: UTF8.self))
        }
      }

      try process.run()

      if onOutput == nil {
        collectedOutput.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
        collectedError.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
      }

      process.waitUntilExit()
      outputPipe.fileHandleForReading.readabilityHandler = nil
      errorPipe.fileHandleForReading.readabilityHandler = nil

      if let remainingOutput = try outputPipe.fileHandleForReading.readToEnd(),
        !remainingOutput.isEmpty
      {
        collectedOutput.append(remainingOutput)
        onOutput?(String(decoding: remainingOutput, as: UTF8.self))
      }
      if let remainingError = try errorPipe.fileHandleForReading.readToEnd(),
        !remainingError.isEmpty
      {
        collectedError.append(remainingError)
        onOutput?(String(decoding: remainingError, as: UTF8.self))
      }

      return ProcessOutput(
        data: collectedOutput.data,
        errorData: collectedError.data,
        terminationStatus: process.terminationStatus
      )
    }.value

    guard output.terminationStatus == 0 else {
      let message = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
      throw ProcessRunnerError.failed(status: output.terminationStatus, message: message)
    }

    return output
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
