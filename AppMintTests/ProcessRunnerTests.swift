import XCTest

@testable import AppMint

final class ProcessRunnerTests: XCTestCase {
  func testBlockingRunDrainsLargeOutput() throws {
    let output = try ProcessRunner.blockingRun(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: [
        "-c",
        "(yes o | head -c 200000) & (yes e | head -c 200000 >&2) & wait",
      ]
    )

    XCTAssertEqual(output.data.count, 200_000)
    XCTAssertEqual(output.errorData.count, 200_000)
  }

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
