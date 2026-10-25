import Foundation
import UpkeepPrivilegedHelperProtocol
import XCTest

@testable import Upkeep

final class ApplicationLaunchJobsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchJobs-\(UUID().uuidString)", isDirectory: true)
        for name in ["Remote.app/Contents/MacOS", "Agents", "Daemons"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFindsOnlyJobsThatRunTheApplicationsOwnPrograms() throws {
        let daemons = root.appendingPathComponent("Daemons")
        let program = applicationURL.appendingPathComponent("Contents/MacOS/RemoteDaemon").path
        try writeJob("com.example.remote.daemon", ["ProgramArguments": [program, "-daemon"]], in: daemons)
        try writeJob("com.example.remote.helper", ["Program": program], in: daemons)
        try writeJob("com.example.other", ["Program": "/usr/libexec/other"], in: daemons)
        try writeJob("bad label;rm", ["Program": program], in: daemons)
        // A sibling bundle that only shares the name prefix is a different app.
        try writeJob(
            "com.example.remoteplus",
            ["Program": root.appendingPathComponent("Remote.app.old/x").path], in: daemons)

        let jobs = LaunchJobPolicy.jobs(forApplicationAt: applicationURL.path, in: daemons)
        XCTAssertEqual(jobs.map(\.label), ["com.example.remote.daemon", "com.example.remote.helper"])
        XCTAssertFalse(LaunchJobPolicy.isValidLabel("a/b"))
        XCTAssertTrue(LaunchJobPolicy.isValidLabel("com.netease.uuremote.daemon"))
    }

    func testUnloadsAgentsAndAsksTheHelperForDaemons() async throws {
        let program = applicationURL.appendingPathComponent("Contents/MacOS/RemoteService").path
        try writeJob("com.example.remote.agent", ["Program": program], in: agents)
        try writeJob("com.example.remote.daemon", ["Program": program], in: daemons)
        let calls = CallLog()

        try await ApplicationLaunchJobs.stop(
            application, agentDirectories: [agents], daemonDirectory: daemons,
            bootoutAgent: { await calls.append("agent:\($0)") },
            stopDaemons: { url in
                await calls.append("daemons:\(url.lastPathComponent)")
                return true
            })

        let recorded = await calls.entries
        XCTAssertEqual(recorded, ["agent:com.example.remote.agent", "daemons:Remote.app"])
    }

    func testExplainsWhenDaemonsNeedTheHelper() async throws {
        let program = applicationURL.appendingPathComponent("Contents/MacOS/RemoteDaemon").path
        try writeJob("com.example.remote.daemon", ["Program": program], in: daemons)

        do {
            try await ApplicationLaunchJobs.stop(
                application, agentDirectories: [], daemonDirectory: daemons,
                bootoutAgent: { _ in }, stopDaemons: { _ in false })
            XCTFail("Expected the daemon to need the helper")
        } catch let error as ApplicationLaunchJobsError {
            XCTAssertTrue(error.localizedDescription.contains("com.example.remote.daemon"))
        }

        // Without launch jobs nothing is asked of the helper.
        try await ApplicationLaunchJobs.stop(
            application, agentDirectories: [agents], daemonDirectory: agents,
            bootoutAgent: { _ in }, stopDaemons: { _ in
                XCTFail("No daemons to stop")
                return false
            })
    }

    func testUninstallStopsLaunchJobsBeforeQuitting() async throws {
        let calls = CallLog()
        let process = ApplicationProcessClient(
            isRunning: { _ in false },
            quit: { _ in await calls.append("quit") },
            launch: { _ in },
            hasRunningProcesses: { _ in await !calls.entries.contains("quit") }
        )
        let residue = root.appendingPathComponent("Agents/cache")
        try Data().write(to: residue)

        _ = try await ApplicationUninstaller.uninstall(
            application,
            items: [
                ApplicationResidueItem(
                    url: residue, displayName: "cache", category: .caches, byteCount: 0)
            ],
            process: process,
            stopLaunchJobs: { _ in await calls.append("launchJobs") })

        let recorded = await calls.entries
        XCTAssertEqual(recorded.prefix(2), ["launchJobs", "quit"])
    }

    private var applicationURL: URL { root.appendingPathComponent("Remote.app") }
    private var agents: URL { root.appendingPathComponent("Agents") }
    private var daemons: URL { root.appendingPathComponent("Daemons") }

    private var application: AppRecord {
        AppRecord(
            name: "Remote",
            bundleIdentifier: "com.example.remote",
            applicationURL: applicationURL,
            currentVersion: "1.0",
            updateConfiguration: UpdateConfiguration(mechanism: .selfManaged)
        )
    }

    private func writeJob(_ label: String, _ values: [String: Any], in directory: URL) throws {
        var job = values
        job["Label"] = label
        let data = try PropertyListSerialization.data(
            fromPropertyList: job, format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent("\(label).plist"))
    }
}

private actor CallLog {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
}
