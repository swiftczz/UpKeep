import Foundation
import Observation

@MainActor
@Observable
final class GitHubAccount {
    static let shared = GitHubAccount()

    private(set) var login: String?
    private(set) var requiresReconnection = false
    private(set) var connectionRevision = UUID()
    private(set) var storageError: String?

    @ObservationIgnored private var credential: GitHubCredential?
    @ObservationIgnored private let credentialStore: GitHubCredentialStore
    @ObservationIgnored let client: GitHubAuthenticationClient

    var isConnected: Bool { login != nil && !requiresReconnection }
    var canUseBrowserAuthorization: Bool { client.clientID?.nonBlankValue != nil }

    init(
        credentialStore: GitHubCredentialStore = .keychain,
        client: GitHubAuthenticationClient = .live()
    ) {
        self.credentialStore = credentialStore
        self.client = client
        do {
            credential = try credentialStore.load()
            login = credential?.login
            requiresReconnection =
                credential.map {
                    $0.invalidated || $0.expiresAt.map { $0 <= client.now() } == true
                } ?? false
        } catch {
            storageError = GitHubAuthenticationError.credentialStorage.localizedDescription
        }
    }

    func connect(with token: GitHubAccessToken) async throws {
        let login = try await client.login(for: token.value)
        try Task.checkCancellation()
        guard token.expiresAt.map({ $0 > client.now() }) ?? true else {
            throw GitHubAuthenticationError.invalidToken
        }
        let newCredential = GitHubCredential(
            token: token.value, login: login, expiresAt: token.expiresAt)
        // Publish the connected state only after the credential is safely persisted.
        try credentialStore.save(newCredential)
        credential = newCredential
        self.login = login
        requiresReconnection = false
        storageError = nil
        connectionRevision = UUID()
    }

    func disconnect() throws {
        try credentialStore.delete()
        credential = nil
        login = nil
        requiresReconnection = false
        storageError = nil
        connectionRevision = UUID()
    }

    func authorizationToken() -> String? {
        guard let credential, !requiresReconnection else { return nil }
        if let expiry = credential.expiresAt, expiry <= client.now() {
            requiresReconnection = true
            connectionRevision = UUID()
            return nil
        }
        return credential.token
    }

    func reject(token: String) {
        // A delayed 401 from a previous connection must not invalidate a new login.
        guard var credential, !requiresReconnection, credential.token == token else { return }
        credential.invalidated = true
        self.credential = credential
        requiresReconnection = true
        connectionRevision = UUID()
        do { try credentialStore.save(credential) } catch {
            storageError = GitHubAuthenticationError.credentialStorage.localizedDescription
        }
    }

    static func preview(login: String? = nil, expired: Bool = false) -> GitHubAccount {
        let account = GitHubAccount(credentialStore: .preview)
        account.login = login
        account.requiresReconnection = expired
        return account
    }
}
