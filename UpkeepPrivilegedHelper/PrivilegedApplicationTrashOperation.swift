import Darwin
import Foundation
import UpkeepPrivilegedHelperProtocol

enum PrivilegedApplicationTrashOperation {
    static func homeDirectory(for uid: uid_t) throws -> URL {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        return try buffer.withUnsafeMutableBufferPointer { storage in
            guard getpwuid_r(uid, &entry, storage.baseAddress, storage.count, &result) == 0,
                result != nil, let directory = entry.pw_dir
            else { throw failure("无法确定当前用户的废纸篓位置。") }
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
    }

    static func moveApplications(
        _ paths: [String], callerUID: uid_t, homeDirectory: URL,
        hostApplicationURL: URL?,
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    ) throws {
        guard callerUID >= 500, !paths.isEmpty, paths.count <= 32,
            Set(paths).count == paths.count,
            paths.allSatisfy(PrivilegedTrashPolicy.isSupportedApplicationPath),
            !paths.contains(hostApplicationURL?.standardizedFileURL.path ?? "")
        else { throw failure("卸载助手只能处理“应用程序”目录中的应用，且不能移除 Upkeep 自身。") }

        let sourceFD = try openDirectoryWithoutSymlinks(applicationsDirectory)
        defer { close(sourceFD) }
        let homeFD = try openDirectoryWithoutSymlinks(homeDirectory)
        defer { close(homeFD) }
        try verifyUserDirectory(homeFD, uid: callerUID)

        // The client creates its own Trash. Root never creates/chowns a user-supplied
        // destination, follows symlinks or overwrites an existing trashed item.
        let trashFD = openat(homeFD, ".Trash", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard trashFD >= 0 else { throw posixFailure() }
        defer { close(trashFD) }
        try verifyUserDirectory(trashFD, uid: callerUID)

        let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
        for name in names {
            var info = stat()
            guard fstatat(sourceFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw posixFailure()
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw failure("拒绝移除符号链接或非应用目录：\(name)")
            }
        }

        for name in names {
            if renameatx_np(sourceFD, name, trashFD, name, UInt32(RENAME_EXCL)) == 0 { continue }
            guard errno == EEXIST else { throw posixFailure() }
            let stem = String(name.dropLast(4))
            let destination = "\(stem)-\(UUID().uuidString).app"
            guard renameatx_np(sourceFD, name, trashFD, destination, UInt32(RENAME_EXCL)) == 0
            else {
                throw posixFailure()
            }
        }
    }

    private static func openDirectoryWithoutSymlinks(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path != "/", !url.path.utf8.contains(0) else {
            throw failure("无效的卸载路径。")
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixFailure() }
        do {
            for component in url.path.split(separator: "/") {
                guard component != ".", component != ".." else { throw failure("无效的卸载路径。") }
                let next = openat(
                    descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw posixFailure() }
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func verifyUserDirectory(_ descriptor: Int32, uid: uid_t) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixFailure() }
        guard info.st_uid == uid, (info.st_mode & S_IFMT) == S_IFDIR,
            (info.st_mode & (S_IWGRP | S_IWOTH)) == 0
        else { throw failure("当前用户的个人目录或废纸篓权限不安全，无法执行卸载。") }
    }

    private static func posixFailure() -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: code == EXDEV
                    ? "应用与个人废纸篓不在同一磁盘，请通过访达移除该应用。"
                    : "无法将应用移到废纸篓：\(String(cString: strerror(code)))"
            ])
    }

    private static func failure(_ message: String) -> NSError {
        NSError(
            domain: "Upkeep.PrivilegedTrash", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
    }
}
