import Foundation

/// A launchd job that runs a program from inside an application bundle.
public struct LaunchJob: Equatable, Sendable {
    public let label: String
    public let plistURL: URL
}

/// Finds the launchd jobs an application installed, such as a background daemon
/// that launchd restarts with KeepAlive. The app and the privileged helper both use
/// it, so the helper only ever stops jobs that run the application's own programs.
public enum LaunchJobPolicy {
    public static let systemDaemonsDirectory = URL(
        fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
    public static let systemAgentsDirectory = URL(
        fileURLWithPath: "/Library/LaunchAgents", isDirectory: true)

    public static func jobs(forApplicationAt applicationPath: String, in directory: URL)
        -> [LaunchJob]
    {
        let root = URL(fileURLWithPath: applicationPath).resolvingSymlinksInPath().path
        guard root.hasSuffix(".app"), root != "/" else { return [] }
        let plists =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey]))?
            .filter { $0.pathExtension == "plist" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        return plists.compactMap { plistURL in
            guard
                (try? plistURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
                    == true,
                let data = try? Data(contentsOf: plistURL), data.count <= 1_000_000,
                let job = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                let label = job["Label"] as? String, isValidLabel(label),
                let program = (job["Program"] as? String)
                    ?? (job["ProgramArguments"] as? [String])?.first
            else { return nil }
            let path = URL(fileURLWithPath: program).resolvingSymlinksInPath().path
            guard path.hasPrefix(root + "/") else { return nil }
            return LaunchJob(label: label, plistURL: plistURL)
        }
    }

    /// Labels become part of `launchctl` service targets such as `system/<label>`.
    public static func isValidLabel(_ label: String) -> Bool {
        !label.isEmpty && label.count <= 255
            && label.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || $0 == 45 || $0 == 46 || $0 == 95
            }
    }
}
