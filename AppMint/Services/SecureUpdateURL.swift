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
  static func response(
    from url: URL,
    attempts: Int = 1
  ) async throws -> (statusCode: Int, data: Data)? {
    var lastError: (any Error)?
    let totalAttempts = max(attempts, 1)
    for attempt in 0..<totalAttempts {
      do {
        return try await singleResponse(from: url)
      } catch let error as CancellationError {
        throw error
      } catch {
        lastError = error
        if attempt < totalAttempts - 1 {
          try? await Task.sleep(for: .milliseconds(350 * (attempt + 1)))
        }
      }
    }
    throw lastError ?? URLError(.cannotLoadFromNetwork)
  }

  private static func singleResponse(from url: URL) async throws -> (statusCode: Int, data: Data)? {
    let request = request(for: url)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      return nil
    }
    return (httpResponse.statusCode, data)
  }

  static func successfulData(from url: URL, attempts: Int = 1) async throws -> Data? {
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
      timeoutInterval: 15
    )
    request.setValue("AppMint", forHTTPHeaderField: "User-Agent")
    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    return request
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
