import Foundation

enum ApplicationCodeSigning {
  static func signatureIsValid(at applicationURL: URL) -> Bool {
    (try? ProcessRunner.blockingRun(
      executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
      arguments: ["--verify", "--deep", "--verbose=2", applicationURL.path]
    )) != nil
  }

  static func teamIdentifier(at applicationURL: URL) -> String? {
    guard
      let output = try? ProcessRunner.blockingRun(
        executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
        arguments: ["-dv", "--verbose=2", applicationURL.path]
      )
    else {
      return nil
    }

    let text = output.standardError + output.standardOutput
    guard
      let match = text.range(
        of: #"TeamIdentifier=([A-Z0-9]+)"#,
        options: .regularExpression
      )
    else {
      return nil
    }

    let line = String(text[match])
    let identifier = line.replacingOccurrences(of: "TeamIdentifier=", with: "")
    return identifier == "notset" ? nil : identifier
  }
}
