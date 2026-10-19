import Foundation
import XCTest

@testable import Upkeep

final class GitHubAuthenticationTests: XCTestCase {
    func testDeviceFlowRequestsOnlyPublicInformationAndValidatesVerificationURL() async throws {
        let transport = AuthenticationTransport(responses: [deviceCode()])
        let challenge = try await transport.client.requestDeviceAuthorization()
        XCTAssertEqual(challenge.userCode, "ABCD-EFGH")
        XCTAssertEqual(challenge.verificationURL.absoluteString, "https://github.com/login/device")
        XCTAssertEqual(challenge.expiresAt, Date(timeIntervalSince1970: 1_900))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://github.com/login/device/code")
        XCTAssertEqual(
            String(data: try XCTUnwrap(request.httpBody), encoding: .utf8), "client_id=test-client")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testRejectsUnexpectedVerificationDestinations() async throws {
        for url in [
            "https://example.com/login/device", "http://github.com/login/device",
            "https://github.com:8443/login/device", "https://someone@github.com/login/device",
            "https://github.com/login/device?redirect=elsewhere",
        ] {
            let transport = AuthenticationTransport(responses: [deviceCode(verificationURL: url)])
            do {
                _ = try await transport.client.requestDeviceAuthorization()
                XCTFail("Untrusted verification URL was accepted")
            } catch {
                XCTAssertEqual(error as? GitHubAuthenticationError, .invalidResponse)
            }
        }
    }

    func testPendingAndSlowDownRespectTheServerPollingInterval() async throws {
        let transport = AuthenticationTransport(responses: [
            deviceCode(), ["error": "authorization_pending"],
            ["error": "slow_down", "interval": 10],
            ["error": "authorization_pending"],
            ["access_token": "test-token", "token_type": "bearer", "expires_in": 3600],
        ])
        let challenge = try await transport.client.requestDeviceAuthorization()
        let token = try await transport.client.waitForAuthorization(challenge)
        XCTAssertEqual(token.value, "test-token")
        XCTAssertEqual(transport.delays, [5, 5, 10, 10])
        XCTAssertEqual(token.expiresAt, Date(timeIntervalSince1970: 4_630))
        let requests = transport.requests.dropFirst()
        XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/login/oauth/access_token" })
        XCTAssertTrue(
            requests.allSatisfy {
                let body = String(decoding: $0.httpBody ?? Data(), as: UTF8.self)
                return body.contains("device_code=device-test") && !body.contains("client_secret")
            })
    }

    func testCancellationStopsPolling() async throws {
        let transport = AuthenticationTransport(responses: [deviceCode()])
        var client = transport.client
        let challenge = try await client.requestDeviceAuthorization()
        client.sleep = { _ in throw CancellationError() }
        do {
            _ = try await client.waitForAuthorization(challenge)
            XCTFail("Cancellation was ignored")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testCodeExpiresWithoutSendingAnotherPoll() async throws {
        let transport = AuthenticationTransport(responses: [deviceCode(expiresIn: 5)])
        let challenge = try await transport.client.requestDeviceAuthorization()
        do {
            _ = try await transport.client.waitForAuthorization(challenge)
            XCTFail("Expired code was accepted")
        } catch {
            XCTAssertEqual(error as? GitHubAuthenticationError, .expiredCode)
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testDeniedAndDisabledAuthorizationsAreActionable() async throws {
        for (code, expected) in [
            ("access_denied", GitHubAuthenticationError.accessDenied),
            ("device_flow_disabled", .deviceFlowDisabled), ("expired_token", .expiredCode),
        ] {
            let transport = AuthenticationTransport(responses: [deviceCode(), ["error": code]])
            let challenge = try await transport.client.requestDeviceAuthorization()
            do {
                _ = try await transport.client.waitForAuthorization(challenge)
                XCTFail("OAuth error was ignored")
            } catch {
                XCTAssertEqual(error as? GitHubAuthenticationError, expected)
            }
        }
    }

    func testMissingClientIDDoesNotSendARequest() async {
        let transport = AuthenticationTransport(responses: [])
        var client = transport.client
        client.clientID = nil
        do {
            _ = try await client.requestDeviceAuthorization()
            XCTFail("Unconfigured OAuth app was used")
        } catch {
            XCTAssertEqual(error as? GitHubAuthenticationError, .notConfigured)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testProfileValidationAuthenticatesOnlyGitHubAPI() async throws {
        let transport = AuthenticationTransport(responses: [["login": "octocat"]])
        let login = try await transport.client.login(for: "test-token")
        XCTAssertEqual(login, "octocat")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/user")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    }

    func testInvalidTokenDoesNotSendHeaderInjection() async {
        let transport = AuthenticationTransport(responses: [])
        for token in ["", "token\nInjected: value", "Bearer token", "token\r\n"] {
            do {
                _ = try await transport.client.login(for: token)
                XCTFail("Invalid token was sent")
            } catch {
                XCTAssertEqual(error as? GitHubAuthenticationError, .invalidToken)
            }
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testUnauthorizedProfileDoesNotAcceptLogin() async {
        let transport = AuthenticationTransport(
            responses: [["message": "Bad credentials"]], statusCode: 401)
        do {
            _ = try await transport.client.login(for: "test-token")
            XCTFail("Unauthorized token was accepted")
        } catch {
            XCTAssertEqual(error as? GitHubAuthenticationError, .invalidToken)
        }
    }

    private func deviceCode(
        verificationURL: String = "https://github.com/login/device", expiresIn: Int = 900
    ) -> [String: Any] {
        [
            "device_code": "device-test", "user_code": "ABCD-EFGH",
            "verification_uri": verificationURL,
            "expires_in": expiresIn, "interval": 5,
        ]
    }
}

@MainActor
final class GitHubAccountTests: XCTestCase {
    func testSuccessfulConnectionPersistsAndSurvivesRelaunchThenDisconnectDeletesIt() async throws {
        let storage = CredentialStorage()
        let transport = AuthenticationTransport(responses: [["login": "octocat"]])
        let account = GitHubAccount(credentialStore: storage.store, client: transport.client)
        try await account.connect(with: GitHubAccessToken(value: "test-token", expiresAt: nil))
        XCTAssertTrue(account.isConnected)
        XCTAssertEqual(account.authorizationToken(), "test-token")
        XCTAssertEqual(storage.credential?.login, "octocat")
        let restored = GitHubAccount(credentialStore: storage.store, client: transport.client)
        XCTAssertEqual(restored.login, "octocat")
        XCTAssertEqual(restored.authorizationToken(), "test-token")
        try restored.disconnect()
        XCTAssertFalse(restored.isConnected)
        XCTAssertNil(restored.authorizationToken())
        XCTAssertNil(storage.credential)
    }

    func testKeychainSaveFailureDoesNotPublishAConnectedAccount() async {
        let store = GitHubCredentialStore(
            load: { nil }, save: { _ in throw GitHubAuthenticationError.credentialStorage },
            delete: {})
        let transport = AuthenticationTransport(responses: [["login": "octocat"]])
        let account = GitHubAccount(credentialStore: store, client: transport.client)
        do {
            try await account.connect(with: GitHubAccessToken(value: "test-token", expiresAt: nil))
            XCTFail("Failed persistence was accepted")
        } catch {
            XCTAssertEqual(error as? GitHubAuthenticationError, .credentialStorage)
        }
        XCTAssertFalse(account.isConnected)
        XCTAssertNil(account.authorizationToken())
    }

    func testCancelledConnectionDoesNotPersistCredential() async {
        let storage = CredentialStorage()
        let transport = AuthenticationTransport(responses: [["login": "octocat"]])
        let account = GitHubAccount(credentialStore: storage.store, client: transport.client)
        let task = Task {
            try await account.connect(with: GitHubAccessToken(value: "test-token", expiresAt: nil))
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled connection succeeded")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(storage.credential)
        XCTAssertFalse(account.isConnected)
    }

    func testExpiredTokenIsNeverUsedAndPromptsReconnection() {
        let credential = GitHubCredential(
            token: "expired-token", login: "octocat", expiresAt: Date(timeIntervalSince1970: 999))
        let storage = CredentialStorage(credential: credential)
        let transport = AuthenticationTransport(responses: [])
        let account = GitHubAccount(credentialStore: storage.store, client: transport.client)
        XCTAssertEqual(account.login, "octocat")
        XCTAssertFalse(account.isConnected)
        XCTAssertTrue(account.requiresReconnection)
        XCTAssertNil(account.authorizationToken())
    }

    func testTokenExpiresWhileAppIsRunning() {
        let storage = CredentialStorage(
            credential: GitHubCredential(
                token: "test-token", login: "octocat", expiresAt: Date(timeIntervalSince1970: 1_005)
            ))
        let transport = AuthenticationTransport(responses: [])
        let account = GitHubAccount(credentialStore: storage.store, client: transport.client)
        XCTAssertTrue(account.isConnected)
        transport.advance(by: 6)
        XCTAssertNil(account.authorizationToken())
        XCTAssertTrue(account.requiresReconnection)
    }

    func testOldUnauthorizedResponseCannotInvalidateNewCredential() async throws {
        let storage = CredentialStorage(
            credential: GitHubCredential(token: "old-token", login: "previous-user", expiresAt: nil)
        )
        let transport = AuthenticationTransport(responses: [["login": "octocat"]])
        let account = GitHubAccount(credentialStore: storage.store, client: transport.client)
        try await account.connect(with: GitHubAccessToken(value: "new-token", expiresAt: nil))
        account.reject(token: "old-token")
        XCTAssertEqual(account.authorizationToken(), "new-token")
        account.reject(token: "new-token")
        XCTAssertTrue(account.requiresReconnection)
        XCTAssertNil(account.authorizationToken())
        let restored = GitHubAccount(credentialStore: storage.store, client: transport.client)
        XCTAssertTrue(restored.requiresReconnection)
        XCTAssertNil(restored.authorizationToken())
    }

    func testDisconnectFailureKeepsExistingCredentialVisible() {
        let credential = GitHubCredential(token: "test-token", login: "octocat", expiresAt: nil)
        let store = GitHubCredentialStore(
            load: { credential }, save: { _ in },
            delete: { throw GitHubAuthenticationError.credentialStorage })
        let account = GitHubAccount(credentialStore: store)
        XCTAssertThrowsError(try account.disconnect())
        XCTAssertTrue(account.isConnected)
        XCTAssertEqual(account.authorizationToken(), "test-token")
    }
}

private final class AuthenticationTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var queuedData: [Data]
    private let statusCode: Int
    private var recordedRequests: [URLRequest] = []
    private var recordedDelays: [TimeInterval] = []
    private var currentDate = Date(timeIntervalSince1970: 1_000)

    init(responses: [[String: Any]], statusCode: Int = 200) {
        queuedData = responses.map { try! JSONSerialization.data(withJSONObject: $0) }
        self.statusCode = statusCode
    }

    var requests: [URLRequest] { lock.withLock { recordedRequests } }
    var delays: [TimeInterval] { lock.withLock { recordedDelays } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { currentDate.addTimeInterval(seconds) }
    }

    var client: GitHubAuthenticationClient {
        GitHubAuthenticationClient(
            clientID: "test-client",
            send: { [self] request in
                try lock.withLock {
                    recordedRequests.append(request)
                    guard !queuedData.isEmpty else {
                        throw GitHubAuthenticationError.invalidResponse
                    }
                    let response = HTTPURLResponse(
                        url: request.url!, statusCode: statusCode, httpVersion: nil,
                        headerFields: nil)!
                    return (queuedData.removeFirst(), response)
                }
            },
            sleep: { [self] seconds in
                lock.withLock {
                    recordedDelays.append(seconds)
                    currentDate.addTimeInterval(seconds)
                }
            },
            now: { [self] in lock.withLock { currentDate } }
        )
    }
}

private final class CredentialStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var value: GitHubCredential?
    init(credential: GitHubCredential? = nil) { value = credential }
    var credential: GitHubCredential? { lock.withLock { value } }
    var store: GitHubCredentialStore {
        GitHubCredentialStore(
            load: { [self] in lock.withLock { value } },
            save: { [self] credential in lock.withLock { value = credential } },
            delete: { [self] in lock.withLock { value = nil } }
        )
    }
}
