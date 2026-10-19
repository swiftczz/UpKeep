import Foundation
import Security

enum ApplicationCodeSigning {
  static func applicationGroups(at applicationURL: URL) -> Set<String>? {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(applicationURL as CFURL, [], &code) == errSecSuccess,
      let code
    else { return nil }

    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        code, SecCSFlags(rawValue: kSecCSSigningInformation), &information
      ) == errSecSuccess, let information = information as? [String: Any]
    else { return nil }

    guard let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
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
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(applicationURL as CFURL, [], &code) == errSecSuccess,
      let code
    else { return nil }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        code, SecCSFlags(rawValue: kSecCSSigningInformation), &information
      ) == errSecSuccess, let information = information as? [String: Any]
    else { return nil }
    return information[kSecCodeInfoTeamIdentifier as String] as? String
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
    var installed: SecStaticCode?
    var candidate: SecStaticCode?
    var developerID: SecRequirement?
    var installedRequirement: SecRequirement?
    let requirement = """
      anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
      and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
      """
    let flags = SecCSFlags(
      rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
    guard
      let installedTeam = teamIdentifier(at: installedURL),
      installedTeam == teamIdentifier(at: candidateURL),
      SecStaticCodeCreateWithPath(installedURL as CFURL, [], &installed) == errSecSuccess,
      let installed,
      SecStaticCodeCreateWithPath(candidateURL as CFURL, [], &candidate) == errSecSuccess,
      let candidate,
      SecRequirementCreateWithString(requirement as CFString, [], &developerID) == errSecSuccess,
      let developerID,
      SecStaticCodeCheckValidity(installed, flags, developerID) == errSecSuccess,
      SecCodeCopyDesignatedRequirement(installed, [], &installedRequirement) == errSecSuccess,
      let installedRequirement,
      SecStaticCodeCheckValidity(candidate, flags, developerID) == errSecSuccess,
      SecStaticCodeCheckValidity(candidate, flags, installedRequirement) == errSecSuccess
    else { return false }
    return true
  }
}
