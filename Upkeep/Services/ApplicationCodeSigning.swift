import Foundation
import Security
import UpkeepPrivilegedHelperProtocol

enum ApplicationCodeSigning {
    static func applicationGroups(at applicationURL: URL) -> Set<String>? {
        guard let information = CodeSignature.information(at: applicationURL) else { return nil }

        guard
            let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else {
            // An unreadable entitlement blob must not be mistaken for an empty declaration.
            return information[kSecCodeInfoEntitlements as String] == nil ? [] : nil
        }
        guard let value = entitlements["com.apple.security.application-groups"] else { return [] }
        guard let groups = value as? [String] else { return nil }
        return Set(groups.filter { !$0.isEmpty })
    }

    static func signatureIsValid(at applicationURL: URL) -> Bool {
        (try? ProcessRunner.blockingRun(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--verbose=2", applicationURL.path]
        )) != nil
    }

    static func teamIdentifier(at applicationURL: URL) -> String? {
        CodeSignature.teamIdentifier(at: applicationURL)
    }

    static func sparklePublicEDKey(at applicationURL: URL) -> String? {
        guard
            let value = Bundle(url: applicationURL)?
                .object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).nonBlankValue
    }

    static func sparkleRequiresVerificationBeforeExtraction(at applicationURL: URL) -> Bool {
        guard let bundle = Bundle(url: applicationURL) else { return true }
        return ["SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"].contains {
            (bundle.object(forInfoDictionaryKey: $0) as? NSNumber)?.boolValue == true
        }
    }

    static func matchesDeveloperID(of installedURL: URL, candidateURL: URL) -> Bool {
        CodeSignature.matchesDeveloperID(of: installedURL, candidateURL: candidateURL)
    }
}
