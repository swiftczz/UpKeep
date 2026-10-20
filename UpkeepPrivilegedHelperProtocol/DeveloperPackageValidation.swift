import Foundation

public enum DeveloperPackageValidation {
    public typealias Command = (String, [String]) throws -> Data

    public static func validate(
        packageURL: URL, applicationURL: URL, bundleIdentifier: String,
        version: String?, buildVersion: String?,
        command: Command = commandOutput
    ) throws -> String {
        let team = try applicationTeam(at: applicationURL, bundleIdentifier: bundleIdentifier)
        let signature = try command("/usr/sbin/pkgutil", ["--check-signature", packageURL.path])
        guard packageTeam(in: String(decoding: signature, as: UTF8.self)) == team else {
            throw failure("安装包的开发者签名与当前应用不一致。")
        }
        let assessment = try command(
            "/usr/sbin/spctl",
            [
                "--assess", "--type", "install", "--enforce-assessment", "--ignore-cache",
                "--no-cache",
                "--raw", packageURL.path,
            ])
        guard acceptedAssessment(assessment) else { throw failure("安装包未通过系统签名验证。") }
        try validateContents(
            packageURL: packageURL, bundleIdentifier: bundleIdentifier,
            version: version, buildVersion: buildVersion, command: command)
        return team
    }

    public static func applicationTeam(at url: URL, bundleIdentifier: String) throws -> String {
        guard let info = applicationInfo(at: url), info["CFBundleIdentifier"] == bundleIdentifier
        else {
            throw failure("安装包的目标应用标识不匹配。")
        }
        guard let team = CodeSignature.developerIDTeam(at: url) else {
            throw failure("目标应用没有有效的 Developer ID 签名。")
        }
        return team
    }

    public static func verifyInstalledApplication(
        at url: URL, bundleIdentifier: String, team: String, version: String?, buildVersion: String?
    ) throws {
        guard try applicationTeam(at: url, bundleIdentifier: bundleIdentifier) == team,
            let info = applicationInfo(at: url),
            version == nil || info["CFBundleShortVersionString"] == version,
            buildVersion == nil || info["CFBundleVersion"] == buildVersion
        else { throw failure("安装后的应用版本或开发者签名不匹配，请重新检查更新。") }
    }

    public static func packageTeam(in output: String) -> String? {
        let pattern = #"(?m)^\s*1\.\s+Developer ID Installer: [^\r\n]+\(([A-Z0-9]{10})\)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: output, range: NSRange(output.startIndex..., in: output)),
            let range = Range(match.range(at: 1), in: output)
        else { return nil }
        return String(output[range])
    }

    public static func acceptedAssessment(_ data: Data) -> Bool {
        guard
            let result = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            result["assessment:verdict"] as? Bool == true,
            let authority = result["assessment:authority"] as? [String: Any],
            authority["assessment:authority:override"] == nil,
            let source = authority["assessment:authority:source"] as? String
        else { return false }
        return ["Developer ID", "Notarized Developer ID"].contains(source)
    }

    static func validateContents(
        packageURL: URL, bundleIdentifier: String, version: String?, buildVersion: String?,
        command: Command
    ) throws {
        let listing = try command("/usr/bin/xar", ["-tf", packageURL.path])
        let entries = String(decoding: listing, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map(String.init)
        let metadata = entries.filter {
            $0 == "Distribution" || ($0 as NSString).lastPathComponent == "PackageInfo"
        }
        guard !metadata.isEmpty, metadata.count <= 32,
            metadata.allSatisfy({
                !$0.hasPrefix("/") && !$0.hasPrefix("-") && !$0.contains("\\") && !$0.contains("\0")
                    && !$0.split(separator: "/").contains("..")
            })
        else { throw failure("安装包没有可验证的应用信息。") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Upkeep-pkg-info-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try command("/usr/bin/xar", ["-xf", packageURL.path, "-C", directory.path] + metadata)
        for entry in metadata {
            let url = directory.appendingPathComponent(entry).resolvingSymlinksInPath()
            guard url.path.hasPrefix(directory.resolvingSymlinksInPath().path + "/"),
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                values.isRegularFile == true, (values.fileSize ?? Int.max) <= 2 * 1024 * 1024,
                let data = try? Data(contentsOf: url),
                let xml = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
                let bundles = try? xml.nodes(forXPath: "//bundle")
            else { continue }
            if bundles.contains(where: { node in
                guard let bundle = node as? XMLElement else { return false }
                return bundle.attribute(forName: "id")?.stringValue == bundleIdentifier
                    && (version == nil
                        || bundle.attribute(forName: "CFBundleShortVersionString")?.stringValue
                            == version)
                    && (buildVersion == nil
                        || bundle.attribute(forName: "CFBundleVersion")?.stringValue == buildVersion)
            }) {
                return
            }
        }
        throw failure("安装包内的应用标识或版本与更新清单不一致。")
    }

    public static func commandOutput(_ path: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) {
            _, value in value
        }
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw failure(
                String(decoding: output, as: UTF8.self).trimmingCharacters(
                    in: .whitespacesAndNewlines))
        }
        return output
    }

    private static func applicationInfo(at url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { return nil }
        return info.compactMapValues { $0 as? String }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(
            domain: "Upkeep.PackageValidation", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
    }
}
