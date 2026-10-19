import Darwin
import Darwin.membership
import Foundation

public enum PrivilegedTrashPolicy {
    // This helper command deliberately excludes residues, nested bundles and system apps.
    public static func isSupportedApplicationPath(_ path: String) -> Bool {
        guard !path.utf8.contains(0) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 3 && components[0].isEmpty
            && components[1] == "Applications" && components[2].hasSuffix(".app")
            && components[2] != ".app"
    }

    public static func isAdministrator(_ uid: uid_t) -> Bool {
        guard uid >= 500 else { return false }
        var user = UUID().uuid
        var group = UUID().uuid
        var isMember: Int32 = 0
        return mbr_uid_to_uuid(uid, &user) == 0
            && mbr_gid_to_uuid(80, &group) == 0
            && mbr_check_membership(&user, &group, &isMember) == 0
            && isMember == 1
    }
}
