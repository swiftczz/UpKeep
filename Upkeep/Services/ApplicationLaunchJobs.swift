import Darwin
import Foundation
import UpkeepPrivilegedHelperProtocol

enum ApplicationLaunchJobsError: LocalizedError {
    case daemonsNeedHelper(name: String, labels: [String])

    var errorDescription: String? {
        switch self {
        case .daemonsNeedHelper(let name, let labels):
            return
                "\(name) 的系统后台服务（\(labels.joined(separator: "、"))）需要管理员权限才能停止。"
                + "请使用管理员账户，并在“系统设置 › 通用 › 登录项与扩展”中允许 Upkeep 后重试。"
        }
    }
}

/// Stops the launchd jobs an application installed. launchd restarts KeepAlive jobs
/// as soon as their process ends, so they must be unloaded before the app can quit.
enum ApplicationLaunchJobs {
    static func stop(
        _ application: AppRecord,
        agentDirectories: [URL] = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            LaunchJobPolicy.systemAgentsDirectory,
        ],
        daemonDirectory: URL = LaunchJobPolicy.systemDaemonsDirectory,
        bootoutAgent: @Sendable (String) async -> Void = bootoutAgent,
        stopDaemons: @Sendable (URL) async throws -> Bool = PrivilegedApplicationTrash
            .stopLaunchDaemons
    ) async throws {
        let path = application.applicationURL.path
        // Agents run in this user's session, so the user can unload them directly.
        for directory in agentDirectories {
            for job in LaunchJobPolicy.jobs(forApplicationAt: path, in: directory) {
                await bootoutAgent(job.label)
            }
        }

        let daemons = LaunchJobPolicy.jobs(forApplicationAt: path, in: daemonDirectory)
        guard !daemons.isEmpty else { return }
        guard try await stopDaemons(application.applicationURL) else {
            throw ApplicationLaunchJobsError.daemonsNeedHelper(
                name: application.name, labels: daemons.map(\.label))
        }
    }

    private static func bootoutAgent(_ label: String) async {
        // A job that is not loaded fails harmlessly; the process check reports leftovers.
        _ = try? await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["bootout", "gui/\(getuid())/\(label)"]
        )
    }
}
