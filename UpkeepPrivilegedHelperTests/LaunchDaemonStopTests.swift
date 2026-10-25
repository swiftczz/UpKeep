import Foundation
import UpkeepPrivilegedHelperProtocol
import XCTest

@testable import UpkeepPrivilegedHelper

final class LaunchDaemonStopTests: XCTestCase {
    func testBootsOutOnlyTheApplicationsDaemonsAndReportsLeftovers() throws {
        let daemons = FileManager.default.temporaryDirectory
            .appendingPathComponent("Daemons-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: daemons, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: daemons) }
        for (label, program) in [
            ("com.example.remote.daemon", "/Applications/Remote.app/Contents/MacOS/RemoteDaemon"),
            ("com.example.other", "/usr/libexec/other"),
        ] {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["Label": label, "ProgramArguments": [program, "-daemon"]],
                format: .xml, options: 0)
            try data.write(to: daemons.appendingPathComponent("\(label).plist"))
        }

        var commands: [[String]] = []
        let stopped = PrivilegedHelper.stopLaunchDaemons(
            applicationPath: "/Applications/Remote.app", in: daemons
        ) { _, arguments in
            commands.append(arguments)
            // `print` fails once the job is no longer loaded.
            return arguments.first == "print" ? "Could not find service" : nil
        }
        XCTAssertNil(stopped)
        XCTAssertEqual(
            commands,
            [["bootout", "system/com.example.remote.daemon"], ["print", "system/com.example.remote.daemon"]])

        let stillLoaded = PrivilegedHelper.stopLaunchDaemons(
            applicationPath: "/Applications/Remote.app", in: daemons
        ) { _, _ in nil }
        XCTAssertEqual(stillLoaded?.contains("com.example.remote.daemon"), true)

        XCTAssertNotNil(
            PrivilegedHelper.stopLaunchDaemons(
                applicationPath: "/Library/Remote.app", in: daemons
            ) { _, _ in
                XCTFail("No command outside /Applications")
                return nil
            })
    }
}
