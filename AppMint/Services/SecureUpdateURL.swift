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
  static func successfulData(from url: URL) async throws -> Data? {
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("AppMint", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      return nil
    }
    return data
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
