import Foundation

struct ApplicationLauncher: Sendable {
  var launch: @Sendable (_ applicationURL: URL) async throws -> Void

  static let live = ApplicationLauncher { applicationURL in
    _ = try await ProcessRunner.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/open"),
      arguments: [applicationURL.path]
    )
  }
}
