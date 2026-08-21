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
  static func run(executableURL: URL, arguments: [String]) async throws -> ProcessOutput {
    let output = try await Task.detached(priority: .userInitiated) {
      let process = Process()
      let outputPipe = Pipe()
      let errorPipe = Pipe()

      process.executableURL = executableURL
      process.arguments = arguments
      process.standardOutput = outputPipe
      process.standardError = errorPipe

      try process.run()
      let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
      let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()

      return ProcessOutput(
        data: outputData,
        errorData: errorData,
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
