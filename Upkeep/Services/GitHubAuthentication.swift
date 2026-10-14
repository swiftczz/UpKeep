import Foundation

enum GitHubOAuthConfiguration {
  static var clientID: String? {
    ProcessInfo.processInfo.environment["UPKEEP_GITHUB_CLIENT_ID"]?.nonBlankValue
      ?? (Bundle.main.object(forInfoDictionaryKey: "GitHubOAuthClientID") as? String)?.nonBlankValue
  }
}

struct GitHubDeviceAuthorization: Identifiable, Sendable {
  let id = UUID()
  let clientID: String
  let deviceCode: String
  let userCode: String
  let verificationURL: URL
  let expiresAt: Date
  let interval: TimeInterval
}

struct GitHubAccessToken: Sendable {
  let value: String
  let expiresAt: Date?
}

enum GitHubAuthenticationError: LocalizedError, Equatable {
  case notConfigured
  case invalidResponse
  case expiredCode
  case accessDenied
  case deviceFlowDisabled
  case invalidToken
  case unavailable
  case credentialStorage

  var errorDescription: String? {
    switch self {
    case .notConfigured: "此版本尚未启用浏览器授权，请使用访问令牌连接。"
    case .invalidResponse: "GitHub 返回了无法识别的授权信息，请重试。"
    case .expiredCode: "验证码已过期，请重新获取。"
    case .accessDenied: "你已取消 GitHub 授权，可以重新连接。"
    case .deviceFlowDisabled: "此版本的 GitHub 浏览器授权尚未启用，请使用访问令牌连接。"
    case .invalidToken: "访问令牌无效或已失效，请重新连接。"
    case .unavailable: "暂时无法连接 GitHub，请检查网络后重试。"
    case .credentialStorage: "无法访问钥匙串，连接信息未能保存。请解锁钥匙串后重试。"
    }
  }

  static func presentable(_ error: any Error) -> String {
    // Never display OAuth response bodies, requests, or token values in errors.
    if let error = error as? GitHubAuthenticationError { return error.localizedDescription }
    if let error = error as? GitHubAPIError { return error.localizedDescription }
    return GitHubAuthenticationError.unavailable.localizedDescription
  }
}

struct GitHubAuthenticationClient: Sendable {
  typealias SendRequest = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  var clientID: String?
  var send: SendRequest
  var sleep: @Sendable (TimeInterval) async throws -> Void
  var now: @Sendable () -> Date

  static func live(clientID: String? = GitHubOAuthConfiguration.clientID) -> Self {
    let session = URLSession(
      configuration: UpdateHTTP.sessionConfiguration(),
      delegate: GitHubAuthenticationRedirectDelegate(),
      delegateQueue: nil
    )
    return Self(
      clientID: clientID,
      send: { request in
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
          throw GitHubAuthenticationError.invalidResponse
        }
        return (data, response)
      },
      sleep: { try await Task.sleep(for: .seconds($0)) },
      now: { .now }
    )
  }

  func requestDeviceAuthorization() async throws -> GitHubDeviceAuthorization {
    guard let clientID = clientID?.nonBlankValue else {
      throw GitHubAuthenticationError.notConfigured
    }
    let request = Self.formRequest(
      url: URL(string: "https://github.com/login/device/code")!,
      fields: [("client_id", clientID)]
    )
    // Omitting scope requests only GitHub's public, read-only information.
    let (data, response) = try await send(request)
    try Self.requireSuccess(response, data: data)
    let result = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    if let error = result.error { throw Self.oauthError(error) }
    guard let deviceCode = result.deviceCode?.nonBlankValue,
      let userCode = result.userCode?.nonBlankValue,
      let expiresIn = result.expiresIn, expiresIn > 0, expiresIn <= 86_400,
      let interval = result.interval, interval > 0, interval <= 300,
      let verificationURL = result.verificationURI.flatMap(URL.init(string:)),
      Self.isDeviceVerificationURL(verificationURL)
    else {
      throw GitHubAuthenticationError.invalidResponse
    }
    return GitHubDeviceAuthorization(
      clientID: clientID, deviceCode: deviceCode, userCode: userCode,
      verificationURL: verificationURL,
      expiresAt: now().addingTimeInterval(TimeInterval(expiresIn)),
      interval: TimeInterval(interval)
    )
  }

  func waitForAuthorization(_ authorization: GitHubDeviceAuthorization) async throws -> GitHubAccessToken {
    var interval = authorization.interval
    while now() < authorization.expiresAt {
      try Task.checkCancellation()
      try await sleep(min(interval, authorization.expiresAt.timeIntervalSince(now())))
      try Task.checkCancellation()
      guard now() < authorization.expiresAt else { break }
      let request = Self.formRequest(
        url: URL(string: "https://github.com/login/oauth/access_token")!,
        fields: [
          ("client_id", authorization.clientID),
          ("device_code", authorization.deviceCode),
          ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
        ]
      )
      let (data, response) = try await send(request)
      try Self.requireSuccess(response, data: data)
      let result = try JSONDecoder().decode(TokenResponse.self, from: data)
      switch result.error {
      case "authorization_pending": continue
      case "slow_down":
        interval = max(interval + 5, TimeInterval(result.interval ?? 0))
        continue
      case .some(let error): throw Self.oauthError(error)
      case .none: break
      }
      guard let token = result.accessToken?.nonBlankValue,
        result.tokenType?.lowercased() == "bearer",
        Self.isValidToken(token),
        result.expiresIn.map({ $0 > 0 }) ?? true
      else {
        throw GitHubAuthenticationError.invalidResponse
      }
      // Expiring grants are deliberately reauthorized rather than retaining refresh tokens.
      return GitHubAccessToken(
        value: token,
        expiresAt: result.expiresIn.map { now().addingTimeInterval(TimeInterval($0)) }
      )
    }
    throw GitHubAuthenticationError.expiredCode
  }

  func login(for token: String) async throws -> String {
    guard Self.isValidToken(token) else { throw GitHubAuthenticationError.invalidToken }
    let request = UpdateHTTP.request(
      for: URL(string: "https://api.github.com/user")!, githubToken: token
    )
    let (data, response) = try await send(request)
    if response.statusCode == 401 { throw GitHubAuthenticationError.invalidToken }
    try Self.requireSuccess(response, data: data)
    let user = try JSONDecoder().decode(UserResponse.self, from: data)
    guard let login = user.login.nonBlankValue else { throw GitHubAuthenticationError.invalidResponse }
    return login
  }

  static func isValidToken(_ token: String) -> Bool {
    !token.isEmpty && token.utf8.allSatisfy { (33...126).contains($0) }
  }

  static func isDeviceVerificationURL(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https" && url.host?.lowercased() == "github.com"
      && url.path == "/login/device" && url.user == nil && url.password == nil
      && (url.port == nil || url.port == 443) && url.query == nil && url.fragment == nil
  }

  private static func formRequest(url: URL, fields: [(String, String)]) -> URLRequest {
    var components = URLComponents()
    components.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.httpMethod = "POST"
    request.setValue("Upkeep", forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
    return request
  }

  private static func requireSuccess(_ response: HTTPURLResponse, data: Data) throws {
    if let error = GitHubAPIError.from(response: response, data: data) { throw error }
    guard (200..<300).contains(response.statusCode) else { throw GitHubAuthenticationError.unavailable }
  }

  private static func oauthError(_ code: String) -> GitHubAuthenticationError {
    switch code {
    case "expired_token", "token_expired": .expiredCode
    case "access_denied": .accessDenied
    case "device_flow_disabled", "incorrect_client_credentials": .deviceFlowDisabled
    default: .invalidResponse
    }
  }

  private struct DeviceCodeResponse: Decodable {
    let deviceCode: String?
    let userCode: String?
    let verificationURI: String?
    let expiresIn: Int?
    let interval: Int?
    let error: String?
    enum CodingKeys: String, CodingKey {
      case deviceCode = "device_code", userCode = "user_code", verificationURI = "verification_uri"
      case expiresIn = "expires_in", interval, error
    }
  }

  private struct TokenResponse: Decodable {
    let accessToken: String?
    let tokenType: String?
    let expiresIn: Int?
    let error: String?
    let interval: Int?
    enum CodingKeys: String, CodingKey {
      case accessToken = "access_token", tokenType = "token_type", expiresIn = "expires_in"
      case error, interval
    }
  }

  private struct UserResponse: Decodable { let login: String }
}

private final class GitHubAuthenticationRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    // OAuth requests carry credentials in their body. Never forward them on redirects.
    completionHandler(nil)
  }
}
