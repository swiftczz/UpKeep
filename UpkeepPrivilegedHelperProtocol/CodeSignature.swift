import Foundation
import Security

/// Signing primitives shared by the app and helper. Reading a team identifier
/// alone does not validate trust; package validation requires Developer ID.
public enum CodeSignature {
    public static func information(at url: URL) -> [String: Any]? {
        guard let code = staticCode(at: url) else { return nil }
        return information(for: code)
    }

    public static func teamIdentifier(at url: URL) -> String? {
        information(at: url)?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    public static func developerIDTeam(at url: URL) -> String? {
        guard let code = validatedDeveloperID(at: url) else { return nil }
        return information(for: code)?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    public static func designatedRequirement(at url: URL) -> String? {
        guard let code = staticCode(at: url) else { return nil }
        var requirement: SecRequirement?
        var value: CFString?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
            let requirement,
            SecRequirementCopyString(requirement, [], &value) == errSecSuccess
        else { return nil }
        return value as String?
    }

    public static func matchesDeveloperID(of installedURL: URL, candidateURL: URL) -> Bool {
        guard let installed = validatedDeveloperID(at: installedURL),
            let candidate = validatedDeveloperID(at: candidateURL),
            let team = information(for: installed)?[kSecCodeInfoTeamIdentifier as String]
                as? String,
            team == information(for: candidate)?[kSecCodeInfoTeamIdentifier as String] as? String
        else { return false }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(installed, [], &requirement) == errSecSuccess,
            let requirement
        else { return false }
        return SecStaticCodeCheckValidity(candidate, validationFlags, requirement) == errSecSuccess
    }

    private static var validationFlags: SecCSFlags {
        SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
    }

    private static func validatedDeveloperID(at url: URL) -> SecStaticCode? {
        let expression = """
            anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
            and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
            """
        var requirement: SecRequirement?
        guard let code = staticCode(at: url),
            SecRequirementCreateWithString(expression as CFString, [], &requirement)
                == errSecSuccess,
            let requirement,
            SecStaticCodeCheckValidity(code, validationFlags, requirement) == errSecSuccess
        else { return nil }
        return code
    }

    private static func staticCode(at url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else {
            return nil
        }
        return code
    }

    private static func information(for code: SecStaticCode) -> [String: Any]? {
        var value: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation), &value)
                == errSecSuccess
        else { return nil }
        return value as? [String: Any]
    }
}
