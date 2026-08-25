import Foundation

struct ApplicationLauncher: Sendable {
  var launch: @Sendable (_ applicationURL: URL) async throws -> Void
  var reveal: @Sendable (_ fileURL: URL) async throws -> Void

  static let live = ApplicationLauncher(
    launch: { applicationURL in
      _ = try await ProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/open"),
        arguments: [applicationURL.path]
      )
    },
    reveal: { fileURL in
      _ = try await ProcessRunner.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/open"),
        arguments: ["-R", fileURL.path]
      )
    }
  )
}
