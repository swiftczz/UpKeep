import XCTest

@testable import AppMint

final class ProcessRunnerTests: XCTestCase {
  func testCaptureTTYMakesStdoutATerminal() async throws {
    let output = try await ProcessRunner.run(
      executableURL: URL(fileURLWithPath: "/bin/zsh"),
      arguments: ["-c", #"if [[ -t 1 ]]; then printf '42.0%%'; else printf 'notty'; fi"#],
      captureTTY: true
    )
    XCTAssertTrue(
      output.standardOutput.contains("42.0%"),
      "expected TTY progress output, got: \(output.standardOutput)"
    )
  }

  func testPipesDoNotLookLikeATerminal() async throws {
    let output = try await ProcessRunner.run(
      executableURL: URL(fileURLWithPath: "/bin/zsh"),
      arguments: ["-c", #"if [[ -t 1 ]]; then printf '42.0%%'; else printf 'notty'; fi"#]
    )
    XCTAssertTrue(output.standardOutput.contains("notty"))
  }
}
