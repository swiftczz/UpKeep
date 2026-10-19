import Darwin
import Foundation
import UpkeepPrivilegedHelperProtocol

enum PrivilegedPackageOperation {
    private static let lock = NSLock()

    static func install(
        packageURL: URL, receiptURL: URL?, applicationURL: URL,
        bundleIdentifier: String? = nil, version: String? = nil, buildVersion: String? = nil,
        isRoot: Bool,
        validate: (URL, URL, String, String?, String?) throws -> String = {
            try DeveloperPackageValidation.validate(
                packageURL: $0, applicationURL: $1, bundleIdentifier: $2, version: $3,
                buildVersion: $4)
        },
        verifyInstalled: (URL, String, String, String?, String?) throws -> Void = {
            try DeveloperPackageValidation.verifyInstalledApplication(
                at: $0, bundleIdentifier: $1, team: $2, version: $3, buildVersion: $4)
        },
        runCommand: (String, [String]) -> String?
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard isRoot else { return "安装助手没有管理员权限。" }
        let isAppStore = receiptURL != nil
        guard packageURL.pathExtension.lowercased() == "pkg" else {
            return isAppStore ? "App Store 下载包格式不正确。" : "安装包格式不正确。"
        }
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            return isAppStore ? "找不到 App Store 下载包。" : "找不到安装包。"
        }
        if let receiptURL {
            guard receiptURL.lastPathComponent == "receipt",
                FileManager.default.fileExists(atPath: receiptURL.path)
            else {
                return "找不到 App Store 收据文件。"
            }
        }
        guard applicationURL.pathExtension == "app" else { return "应用路径不正确。" }
        guard isAppStore || bundleIdentifier?.isEmpty == false else { return "缺少目标应用标识。" }
        guard isAppStore || version?.isEmpty == false || buildVersion?.isEmpty == false else {
            return "缺少目标应用版本。"
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Upkeep-pkg-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let stagedPackage = directory.appendingPathComponent("update.pkg")
            try stage(packageURL, at: stagedPackage)
            let stagedReceipt = directory.appendingPathComponent("receipt")
            if let receiptURL { try stage(receiptURL, at: stagedReceipt) }
            // Validate the private copy which will actually be passed to installer.
            let team = try bundleIdentifier.map {
                try validate(stagedPackage, applicationURL, $0, version, buildVersion)
            }
            if let error = runCommand(
                "/usr/sbin/installer", ["-dumplog", "-pkg", stagedPackage.path, "-target", "/"])
            {
                return error
            }
            if let bundleIdentifier, let team {
                try verifyInstalled(applicationURL, bundleIdentifier, team, version, buildVersion)
            }
            if receiptURL != nil {
                let destination = applicationURL.appendingPathComponent(
                    "Contents/_MASReceipt/receipt")
                do {
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.copyItem(at: stagedReceipt, to: destination)
                    chmod(destination.path, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
                    chown(destination.path, 0, 0)
                } catch { return "无法写入 App Store 收据：\(error.localizedDescription)" }
            }
            return runCommand("/usr/bin/mdimport", [applicationURL.path])
        } catch { return error.localizedDescription }
    }

    private static func stage(_ source: URL, at destination: URL) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw NSError(
                domain: "Upkeep.PackageInstall", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "安装文件必须是普通文件。"])
        }
        try FileManager.default.copyItem(at: source, to: destination)
        let copied = try destination.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard copied.isRegularFile == true, copied.isSymbolicLink != true else {
            throw NSError(
                domain: "Upkeep.PackageInstall", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "安装文件已发生变化。"])
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600, .ownerAccountID: geteuid()], ofItemAtPath: destination.path)
    }
}
