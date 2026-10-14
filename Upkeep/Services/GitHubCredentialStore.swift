import Foundation
import LocalAuthentication
import Security

struct GitHubCredential: Codable, Equatable, Sendable {
  let token: String
  let login: String
  let expiresAt: Date?
  var invalidated = false
}

struct GitHubCredentialStore: Sendable {
  var load: @Sendable () throws -> GitHubCredential?
  var save: @Sendable (GitHubCredential) throws -> Void
  var delete: @Sendable () throws -> Void

  static let keychain = Self(
    load: {
      var query = keychainQuery
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      let context = LAContext()
      context.interactionNotAllowed = true
      query[kSecUseAuthenticationContext as String] = context
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess, let data = item as? Data,
        let credential = try? JSONDecoder().decode(GitHubCredential.self, from: data)
      else { throw GitHubAuthenticationError.credentialStorage }
      return credential
    },
    save: { credential in
      let data = try JSONEncoder().encode(credential)
      let updates = [kSecValueData as String: data] as CFDictionary
      let status = SecItemUpdate(keychainQuery as CFDictionary, updates)
      if status == errSecItemNotFound {
        var item = keychainQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
          throw GitHubAuthenticationError.credentialStorage
        }
      } else if status != errSecSuccess {
        throw GitHubAuthenticationError.credentialStorage
      }
    },
    delete: {
      let status = SecItemDelete(keychainQuery as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw GitHubAuthenticationError.credentialStorage
      }
    }
  )

  static let preview = Self(load: { nil }, save: { _ in }, delete: {})

  private static var keychainQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.chengzhong.Upkeep.github",
      kSecAttrAccount as String: "github.com",
    ]
  }
}
