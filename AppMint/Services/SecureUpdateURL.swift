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
