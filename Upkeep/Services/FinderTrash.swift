import AppKit
import Foundation

enum FinderTrashError: LocalizedError {
    case automationDenied
    case authorizationCancelled
    case unsafeTargets([URL])
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .automationDenied:
            return "Upkeep 没有控制 Finder 的权限。请在“系统设置 → 隐私与安全性 → 自动化”中允许 Upkeep 控制 Finder 后重试。"
        case .authorizationCancelled:
            return "系统删除操作已取消，选中的项目未被删除。"
        case .unsafeTargets(let urls):
            let names = urls.prefix(3).map(\.lastPathComponent).joined(separator: "、")
            return "为保护系统安全，Upkeep 拒绝处理这些路径：\(names)"
        case .failed(let message):
            if message.isEmpty {
                return "系统未能将受保护项目移到废纸篓。"
            }
            return "系统未能将受保护项目移到废纸篓：\(message)"
        }
    }
}

enum FinderTrash {
    static func moveToTrash(_ urls: [URL]) async throws {
        let targets = urls.map(\.standardizedFileURL)
        guard !targets.isEmpty else { return }

        let groups = partitionTargets(targets)
        let directTargets = groups.unprotected.filter {
            UserTrashMove.isDarwinVolatileTarget($0)
        }
        if !directTargets.isEmpty {
            try await UserTrashMove.moveToTrash(directTargets)
        }

        let finderTargets = groups.unprotected.filter {
            !directTargets.contains($0)
        }
        if !finderTargets.isEmpty {
            try await FinderBatchTrash.moveToTrash(finderTargets)
        }

        let remaining = targets.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !remaining.isEmpty else { return }

        let protectedTargets = remaining.filter {
            ApplicationContainerAccess.isProtectedContainer($0)
        }
        if !protectedTargets.isEmpty {
            throw ApplicationContainerAccessError.denied(protectedTargets)
        }

        throw FinderTrashError.failed("系统删除操作结束后，仍有 \(remaining.count) 项存在。")
    }

    static func partitionTargets(
        _ urls: [URL],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> (unprotected: [URL], protected: [URL]) {
        let targets = urls.map(\.standardizedFileURL)
        return (
            unprotected: targets.filter {
                !ApplicationContainerAccess.isProtectedContainer($0, homeDirectory: homeDirectory)
            },
            protected: targets.filter {
                ApplicationContainerAccess.isProtectedContainer($0, homeDirectory: homeDirectory)
            }
        )
    }

}

enum UserTrashMove {
    static func moveToTrash(
        _ urls: [URL],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) async throws {
        let targets = urls.map(\.standardizedFileURL)
        let unsafeTargets = targets.filter {
            !isDarwinVolatileTarget($0, temporaryDirectory: temporaryDirectory)
        }
        guard unsafeTargets.isEmpty else {
            throw FinderTrashError.unsafeTargets(unsafeTargets)
        }

        let existingTargets = targets.filter { fileManager.fileExists(atPath: $0.path) }
        guard !existingTargets.isEmpty else { return }

        let trashBundle = try makeTrashBundleDirectory(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        var usedNames: [String: Int] = [:]

        for target in existingTargets {
            let destination = nextDestination(
                for: target,
                in: trashBundle,
                usedNames: &usedNames,
                fileManager: fileManager
            )
            _ = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/mv"),
                arguments: [target.path, destination.path]
            )
        }
    }

    static func isDarwinVolatileTarget(
        _ url: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        let targetPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let temporaryPath =
            temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let darwinCachePath =
            temporaryDirectory
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("C", isDirectory: true)
            .standardizedFileURL
            .path

        return [temporaryPath, darwinCachePath].contains { root in
            targetPath != root && targetPath.hasPrefix(root + "/")
        }
    }

    private static func makeTrashBundleDirectory(
        homeDirectory: URL,
        fileManager: FileManager
    ) throws -> URL {
        let trashDirectory = homeDirectory.appendingPathComponent(".Trash", isDirectory: true)
        try fileManager.createDirectory(
            at: trashDirectory,
            withIntermediateDirectories: true
        )

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let bundleName = "Upkeep_\(formatter.string(from: Date()))_\(UUID().uuidString)"
        let bundle = trashDirectory.appendingPathComponent(bundleName, isDirectory: true)
        try fileManager.createDirectory(
            at: bundle,
            withIntermediateDirectories: false
        )
        return bundle
    }

    private static func nextDestination(
        for target: URL,
        in trashBundle: URL,
        usedNames: inout [String: Int],
        fileManager: FileManager
    ) -> URL {
        let baseName = target.lastPathComponent
        var index = usedNames[baseName] ?? 0
        var name = baseName

        while fileManager.fileExists(atPath: trashBundle.appendingPathComponent(name).path) {
            index += 1
            name = "\(baseName)-\(index)"
        }

        usedNames[baseName] = index
        return trashBundle.appendingPathComponent(name)
    }

}

enum FinderBatchTrash {
    typealias Recycle = @Sendable ([URL]) async throws -> [URL: URL]
    typealias AuthorizedRecycle = @Sendable ([URL]) async throws -> Void

    static func moveToTrash(
        _ urls: [URL],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        recycle: Recycle = recycleUsingWorkspace,
        authorizedRecycle: AuthorizedRecycle = { try await recycleWithAuthorization($0) },
        exists: @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) async throws {
        let targets = urls.map(\.standardizedFileURL)
        guard !targets.isEmpty else { return }
        try Task.checkCancellation()
        let unsafeTargets = targets.filter {
            !isAllowedTarget($0, homeDirectory: homeDirectory)
        }
        guard unsafeTargets.isEmpty else {
            throw FinderTrashError.unsafeTargets(unsafeTargets)
        }

        do {
            let moved = try await recycle(targets)
            let missing = targets.filter { moved[$0] == nil }
            guard missing.isEmpty else {
                throw FinderTrashError.failed("系统未确认 \(missing.count) 项已移到废纸篓。")
            }
        } catch {
            let nsError = error as NSError
            if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError)
                || (nsError.domain == NSOSStatusErrorDomain && nsError.code == -128)
            {
                throw FinderTrashError.authorizationCancelled
            }
            guard isPermissionError(nsError) else { throw error }
            try Task.checkCancellation()
            // The native API cannot elevate privileges for some root-owned app bundles.
            // Retry only files that remain after any partial native move.
            let remaining = targets.filter(exists)
            if !remaining.isEmpty { try await authorizedRecycle(remaining) }
            return
        }
    }

    private static func isPermissionError(_ error: NSError, depth: Int = 0) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code) {
            return true
        }
        guard depth < 8, let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return false
        }
        return isPermissionError(underlying, depth: depth + 1)
    }

    static func isAllowedTarget(
        _ url: URL,
        homeDirectory: URL
    ) -> Bool {
        if ApplicationContainerAccess.isProtectedContainer(url, homeDirectory: homeDirectory) {
            return false
        }

        let targetPath = url.standardizedFileURL.path
        let homePath = homeDirectory.standardizedFileURL.path
        let allowedRoots = [
            "/Applications",
            homePath + "/Applications",
            homePath + "/Library",
            "/Library",
            "/var/db/receipts",
            "/opt/homebrew/Caskroom",
            "/usr/local/Caskroom",
        ]
        return allowedRoots.contains { root in
            targetPath != root && targetPath.hasPrefix(root + "/")
        }
    }

    @MainActor
    private static func recycleUsingWorkspace(_ urls: [URL]) async throws -> [URL: URL] {
        try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { moved, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: moved)
                }
            }
        }
    }

    static func recycleWithAuthorization(
        _ urls: [URL],
        privilegedRecycle: @Sendable ([URL]) async throws -> Bool = {
            try await PrivilegedApplicationTrash.moveToTrash($0)
        },
        finderRecycle: AuthorizedRecycle = recycleUsingFinder
    ) async throws {
        let applications = urls.filter(PrivilegedApplicationTrash.supports)
        let handled = applications.isEmpty ? false : try await privilegedRecycle(applications)
        let remaining = handled ? urls.filter { !applications.contains($0) } : urls
        if !remaining.isEmpty { try await finderRecycle(remaining) }
    }

    private static func recycleUsingFinder(_ urls: [URL]) async throws {
        do {
            _ = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", scriptSource, "--"] + urls.map(\.path)
            )
        } catch let error as ProcessRunnerError {
            let message = error.localizedDescription
            if message.contains("(-128)") { throw FinderTrashError.authorizationCancelled }
            if message.contains("(-1743)") { throw FinderTrashError.automationDenied }
            throw FinderTrashError.failed(message)
        }
    }

    static let scriptSource = """
        on run argv
          set targetItems to {}
          repeat with targetPath in argv
            set end of targetItems to (POSIX file (targetPath as text))
          end repeat
          tell application "Finder"
            delete targetItems
          end tell
        end run
        """
}
