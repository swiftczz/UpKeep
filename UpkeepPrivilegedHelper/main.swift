import Darwin
import Foundation
import UpkeepPrivilegedHelperProtocol

final class PrivilegedHelper: NSObject, NSXPCListenerDelegate, UpkeepPrivilegedHelperProtocol {
    private lazy var expectedClientRequirement: String? =
        Self.hostApplicationURL().flatMap { CodeSignature.designatedRequirement(at: $0) }

    func run() {
        let listener = NSXPCListener(
            machServiceName: UpkeepPrivilegedHelperConstants.machServiceName
        )
        listener.delegate = self
        listener.resume()
        RunLoop.main.run()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard let requirementString = expectedClientRequirement else {
            return false
        }

        // Bind trust to the actual XPC peer, rather than a PID that can be reused.
        newConnection.setCodeSigningRequirement(requirementString)

        newConnection.exportedInterface = NSXPCInterface(
            with: UpkeepPrivilegedHelperProtocol.self
        )
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func installAppStorePackage(
        packagePath: String,
        receiptPath: String,
        applicationPath: String,
        withReply reply: @escaping (String?) -> Void
    ) {
        reply(
            Self.installAppStorePackage(
                packagePath: packagePath,
                receiptPath: receiptPath,
                applicationPath: applicationPath
            ))
    }

    func ping(withReply reply: @escaping () -> Void) {
        reply()
    }

    func installDeveloperPackage(
        packagePath: String, applicationPath: String, bundleIdentifier: String,
        version: String?, buildVersion: String?, withReply reply: @escaping (String?) -> Void
    ) {
        guard geteuid() == 0, let connection = NSXPCConnection.current(),
            PrivilegedTrashPolicy.isAdministrator(connection.effectiveUserIdentifier)
        else {
            reply("当前账户没有安装系统更新所需的管理员权限。")
            return
        }
        reply(
            PrivilegedPackageOperation.install(
                packageURL: URL(fileURLWithPath: packagePath), receiptURL: nil,
                applicationURL: URL(fileURLWithPath: applicationPath),
                bundleIdentifier: bundleIdentifier,
                version: version, buildVersion: buildVersion, isRoot: true, runCommand: Self.run))
    }

    func canTrashApplications(withReply reply: @escaping (Bool) -> Void) {
        guard let connection = NSXPCConnection.current() else {
            reply(false)
            return
        }
        reply(
            geteuid() == 0
                && PrivilegedTrashPolicy.isAdministrator(connection.effectiveUserIdentifier))
    }

    func trashApplications(paths: [String], withReply reply: @escaping (String?) -> Void) {
        // The signed client performs LocalAuthentication for every request. The helper
        // independently restricts the caller to administrators; biometrics alone do
        // not give a standard account permission to remove system-wide applications.
        guard geteuid() == 0, let connection = NSXPCConnection.current(),
            PrivilegedTrashPolicy.isAdministrator(connection.effectiveUserIdentifier)
        else {
            reply("当前账户没有卸载受保护应用所需的管理员权限。")
            return
        }
        do {
            let uid = connection.effectiveUserIdentifier
            let home = try PrivilegedApplicationTrashOperation.homeDirectory(for: uid)
            try PrivilegedApplicationTrashOperation.moveApplications(
                paths, callerUID: uid, homeDirectory: home,
                hostApplicationURL: Self.hostApplicationURL()
            )
            reply(nil)
        } catch {
            reply(error.localizedDescription)
        }
    }

    private static func hostApplicationURL() -> URL? {
        hostApplicationURL(from: executableURL())
    }

    static func hostApplicationURL(from executableURL: URL?) -> URL? {
        guard var url = executableURL else {
            return nil
        }

        while url.path != "/" {
            if url.pathExtension == "app" {
                return url
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private static func executableURL() -> URL? {
        var requiredSize: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &requiredSize)
        guard requiredSize > 0 else {
            return nil
        }

        var path = [CChar](repeating: 0, count: Int(requiredSize))
        guard _NSGetExecutablePath(&path, &requiredSize) == 0 else {
            return nil
        }

        return path.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return nil
            }
            return URL(fileURLWithPath: String(cString: baseAddress))
                .resolvingSymlinksInPath()
                .standardizedFileURL
        }
    }

    private static func installAppStorePackage(
        packagePath: String,
        receiptPath: String,
        applicationPath: String
    ) -> String? {
        installAppStorePackage(
            packagePath: packagePath,
            receiptPath: receiptPath,
            applicationPath: applicationPath,
            isRoot: getuid() == 0,
            runCommand: run
        )
    }

    static func installAppStorePackage(
        packagePath: String,
        receiptPath: String,
        applicationPath: String,
        isRoot: Bool,
        runCommand: (_ launchPath: String, _ arguments: [String]) -> String?
    ) -> String? {
        PrivilegedPackageOperation.install(
            packageURL: URL(fileURLWithPath: packagePath),
            receiptURL: URL(fileURLWithPath: receiptPath),
            applicationURL: URL(fileURLWithPath: applicationPath),
            isRoot: isRoot, runCommand: runCommand)
    }

    static func run(_ launchPath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        let output = HelperDataBuffer()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                output.append(data)
            }
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return
                "\(URL(fileURLWithPath: launchPath).lastPathComponent) 无法启动：\(error.localizedDescription)"
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        if let remaining = try? pipe.fileHandleForReading.readToEnd(), !remaining.isEmpty {
            output.append(remaining)
        }

        guard process.terminationStatus == 0 else {
            let message = String(data: output.data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return message?.isEmpty == false
                ? message
                : "\(URL(fileURLWithPath: launchPath).lastPathComponent) 执行失败。"
        }

        return nil
    }
}

private final class HelperDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.withLock { storage }
    }

    func append(_ data: Data) {
        lock.withLock {
            storage.append(data)
        }
    }
}

let helper = PrivilegedHelper()
helper.run()
