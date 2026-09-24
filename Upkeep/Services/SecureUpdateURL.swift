import Foundation

enum SecureUpdateURL {
  static func https(_ url: URL) -> URL? {
    guard url.scheme?.lowercased() == "https", let host = url.host else {
      return nil
    }

    let normalizedHost = host.lowercased()
    if normalizedHost == "localhost"
      || normalizedHost == "127.0.0.1"
      || normalizedHost == "0.0.0.0"
      || normalizedHost == "::1"
      || normalizedHost.hasSuffix(".local")
      || normalizedHost.hasSuffix(".invalid")
    {
      return nil
    }

    return url
  }

  static func https(string: String) -> URL? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed) else {
      return nil
    }
    return https(url)
  }
}

enum UpdateHTTP {
  private static let session = URLSession(configuration: sessionConfiguration())

  static func response(
    from url: URL,
    attempts: Int = NetworkRetryPolicy.metadataAttempts
  ) async throws -> (statusCode: Int, data: Data)? {
    var lastError: (any Error)?
    let totalAttempts = max(attempts, 1)
    for attempt in 0..<totalAttempts {
      do {
        guard let result = try await singleResponse(from: url) else {
          return nil
        }
        if let error = GitHubAPIError.from(response: result.response, data: result.data) {
          throw error
        }
        if NetworkRetryPolicy.isRetryableHTTPStatus(result.response.statusCode),
          attempt < totalAttempts - 1
        {
          try await NetworkRetryPolicy.sleepBeforeRetry(
            afterAttempt: attempt,
            retryAfter: NetworkRetryPolicy.retryAfterDelay(from: result.response)
          )
          continue
        }
        return (result.response.statusCode, result.data)
      } catch let error as CancellationError {
        throw error
      } catch {
        lastError = error
        guard NetworkRetryPolicy.shouldRetry(error), attempt < totalAttempts - 1 else {
          throw NetworkRetryPolicy.presentableError(error, attempts: attempt + 1)
        }
        try await NetworkRetryPolicy.sleepBeforeRetry(afterAttempt: attempt)
      }
    }
    let error = lastError ?? URLError(.cannotLoadFromNetwork)
    throw NetworkRetryPolicy.presentableError(error, attempts: totalAttempts)
  }

  private static func singleResponse(
    from url: URL
  ) async throws -> (response: HTTPURLResponse, data: Data)? {
    let request = request(for: url)
    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      return nil
    }
    return (httpResponse, data)
  }

  static func successfulData(
    from url: URL,
    attempts: Int = NetworkRetryPolicy.metadataAttempts
  ) async throws -> Data? {
    guard let result = try await response(from: url, attempts: attempts),
      (200..<300).contains(result.statusCode),
      result.statusCode != 204
    else {
      return nil
    }
    return result.data
  }

  static func request(for url: URL) -> URLRequest {
    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 20
    )
    request.setValue("Upkeep", forHTTPHeaderField: "User-Agent")
    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    if url.host?.lowercased() == "api.github.com" {
      request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    }
    return request
  }

  static func sessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.waitsForConnectivity = true
    configuration.httpMaximumConnectionsPerHost = 4
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 45
    return configuration
  }
}

struct GitHubAPIError: LocalizedError {
  let message: String
  var errorDescription: String? { message }

  static func from(response: HTTPURLResponse, data: Data, now: Date = .now) -> GitHubAPIError? {
    guard response.url?.host?.lowercased() == "api.github.com",
      !(200..<300).contains(response.statusCode) else { return nil }
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let detail = json?["message"] as? String ?? ""
    let rateLimited = response.statusCode == 429 || (response.statusCode == 403 && (
      response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
        || detail.lowercased().contains("rate limit")))
    guard rateLimited else {
      return nil
    }

    var lines = ["GitHub API 请求已被限流，请稍后重试。"]
    // Only display an IP explicitly reported by GitHub; never infer proxy use.
    if let range = detail.range(of: #"(?i)rate limit exceeded for ([0-9a-f:.]+)"#, options: .regularExpression) {
      let ip = detail[range].split(separator: " ").last.map(String.init)?
        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
      if let ip, !ip.isEmpty { lines.append("当前请求出口 IP：\(ip)。") }
    }
    var retryDate: Date?
    if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
      let raw = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
      let timestamp = TimeInterval(raw), timestamp.isFinite {
      retryDate = Date(timeIntervalSince1970: timestamp)
    }
    if let raw = response.value(forHTTPHeaderField: "Retry-After"),
      let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0 {
      retryDate = max(retryDate ?? now, now.addingTimeInterval(seconds))
    }
    if let retryDate, retryDate > now {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "zh_CN")
      formatter.timeZone = .current
      formatter.dateFormat = "M月d日 HH:mm:ss zzz"
      lines.append("预计可重试时间：\(formatter.string(from: retryDate))。")
    }
    lines.append("同一出口 IP 的请求可能共用额度；如使用代理，同一代理出口也可能共用额度。请避免反复刷新。")
    return GitHubAPIError(message: lines.joined(separator: "\n\n"))
  }
}

enum UpdateNetworkError: LocalizedError {
  case interruptedTLS(attempts: Int)

  var errorDescription: String? {
    switch self {
    case .interruptedTLS(let attempts):
      return "TLS 连接被更新服务器或网络代理中断，已尝试 \(attempts) 次。"
    }
  }
}

enum UpdateHTTPError: LocalizedError {
  case statusCode(Int, retryAfter: TimeInterval?)

  var errorDescription: String? {
    switch self {
    case .statusCode(let statusCode, _):
      return "更新服务器返回 HTTP \(statusCode)。"
    }
  }
}

enum NetworkRetryPolicy {
  static let metadataAttempts = 2
  static let downloadAttempts = 4

  private static let retryableURLErrorCodes: Set<URLError.Code> = [
    .timedOut,
    .cannotFindHost,
    .cannotConnectToHost,
    .networkConnectionLost,
    .dnsLookupFailed,
    .notConnectedToInternet,
    .secureConnectionFailed,
    .cannotLoadFromNetwork,
    .internationalRoamingOff,
    .callIsActive,
    .dataNotAllowed,
  ]

  static func shouldRetry(_ error: any Error) -> Bool {
    if let httpError = error as? UpdateHTTPError,
      case .statusCode(let statusCode, _) = httpError
    {
      return isRetryableHTTPStatus(statusCode)
    }

    return errorChain(error).contains { error in
      error.domain == NSURLErrorDomain
        && retryableURLErrorCodes.contains(URLError.Code(rawValue: error.code))
    }
  }

  static func isRetryableHTTPStatus(_ statusCode: Int) -> Bool {
    statusCode == 408 || statusCode == 425 || statusCode == 429
      || statusCode == 500 || statusCode == 502 || statusCode == 503 || statusCode == 504
  }

  static func retryDelay(
    afterAttempt attempt: Int,
    jitter: Double
  ) -> TimeInterval {
    let baseDelays: [TimeInterval] = [0.8, 2, 5]
    let base = baseDelays[min(max(attempt, 0), baseDelays.count - 1)]
    return base * (1 + min(max(jitter, -0.2), 0.2))
  }

  static func retryAfterDelay(
    from response: HTTPURLResponse,
    now: Date = .now
  ) -> TimeInterval? {
    guard let value = response.value(forHTTPHeaderField: "Retry-After")?.nonBlankValue else {
      return nil
    }
    if let seconds = TimeInterval(value), seconds >= 0 {
      return min(seconds, 30)
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    guard let date = formatter.date(from: value) else {
      return nil
    }
    return min(max(date.timeIntervalSince(now), 0), 30)
  }

  static func retryAfterDelay(from error: any Error) -> TimeInterval? {
    guard let httpError = error as? UpdateHTTPError,
      case .statusCode(_, let retryAfter) = httpError
    else {
      return nil
    }
    return retryAfter
  }

  static func sleepBeforeRetry(
    afterAttempt attempt: Int,
    retryAfter: TimeInterval? = nil
  ) async throws {
    let delay = retryAfter
      ?? retryDelay(afterAttempt: attempt, jitter: Double.random(in: -0.2...0.2))
    try await Task.sleep(for: .milliseconds(Int64((delay * 1_000).rounded())))
  }

  static func presentableError(
    _ error: any Error,
    attempts: Int
  ) -> any Error {
    if containsURLErrorCode(.secureConnectionFailed, in: error) {
      return UpdateNetworkError.interruptedTLS(attempts: attempts)
    }
    return error
  }

  private static func containsURLErrorCode(
    _ code: URLError.Code,
    in error: any Error
  ) -> Bool {
    errorChain(error).contains {
      $0.domain == NSURLErrorDomain && $0.code == code.rawValue
    }
  }

  private static func errorChain(_ error: any Error) -> [NSError] {
    var chain: [NSError] = []
    var current: NSError? = error as NSError
    var visited = Set<ObjectIdentifier>()

    while let error = current, visited.insert(ObjectIdentifier(error)).inserted {
      chain.append(error)
      current = error.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return chain
  }
}

enum ISO8601Parsing {
  static func date(from value: String) -> Date? {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: value) {
      return date
    }
    iso.formatOptions = [.withInternetDateTime]
    return iso.date(from: value)
  }
}

enum HomebrewCLI {
  static var executableURL: URL? {
    ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
      .first(where: FileManager.default.isExecutableFile(atPath:))
      .map(URL.init(fileURLWithPath:))
  }
}

enum MacCPUArchitecture: Equatable, Sendable {
  case arm64
  case x64

  static var current: MacCPUArchitecture {
    #if arch(arm64)
      .arm64
    #else
      .x64
    #endif
  }
}

extension String {
  var nonBlankValue: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
