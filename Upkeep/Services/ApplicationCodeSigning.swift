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
    guard
      let output = try? ProcessRunner.blockingRun(
        executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
        arguments: ["-dv", "--verbose=2", applicationURL.path]
      )
    else {
      return nil
    }

    let text = output.standardError + output.standardOutput
    guard
      let match = text.range(
        of: #"TeamIdentifier=([A-Z0-9]+)"#,
        options: .regularExpression
      )
    else {
      return nil
    }

    let line = String(text[match])
    let identifier = line.replacingOccurrences(of: "TeamIdentifier=", with: "")
    return identifier == "notset" ? nil : identifier
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
}
