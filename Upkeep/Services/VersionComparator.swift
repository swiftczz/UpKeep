import Foundation

enum VersionComparator {
  static func isNewer(_ candidate: String, than installed: String) -> Bool {
    isNewer(candidate, than: installed, build: nil)
  }

  static func isNewer(_ candidate: String, than installed: String, build: String?) -> Bool {
    if let build = build?.nonBlankValue {
      if matchesInstalledBuild(candidate, build: build) {
        return false
      }

      if candidate == "\(installed).\(build)"
        || candidate == "\(installed),\(build)"
        || candidate == "\(installed)_\(build)"
      {
        return false
      }
    }

    if let candidateValue = ParsedVersion(candidate),
      let installedValue = ParsedVersion(installed)
    {
      return candidateValue > installedValue
    }

    return candidate.compare(
      installed,
      options: [.numeric, .caseInsensitive],
      range: nil,
      locale: Locale(identifier: "en_US_POSIX")
    ) == .orderedDescending
  }

  static func isPrerelease(_ rawValue: String) -> Bool {
    guard let parsed = ParsedVersion(rawValue) else { return false }
    return parsed.prereleaseRank < 3
  }

  /// Homebrew often publishes `CFBundleVersion` (e.g. ImHex 1.38.1) while the
  /// app's marketing string is shorter (1.38). That is the same installed copy.
  private static func matchesInstalledBuild(_ candidate: String, build: String) -> Bool {
    if candidate == build {
      return true
    }

    guard let candidateValue = ParsedVersion(candidate),
      let buildValue = ParsedVersion(build)
    else {
      return false
    }

    return !(candidateValue > buildValue) && !(buildValue > candidateValue)
  }
}

private struct ParsedVersion: Comparable {
  let components: [Int]
  let prereleaseRank: Int

  init?(_ rawValue: String) {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let expression = try? NSRegularExpression(
        pattern: #"(?i)^v?(\d+(?:[._-]\d+)*)"#
      ),
      let match = expression.firstMatch(
        in: value,
        range: NSRange(value.startIndex..., in: value)
      ),
      let versionRange = Range(match.range(at: 1), in: value)
    else {
      return nil
    }

    components = value[versionRange]
      .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
      .compactMap { Int($0) }

    guard !components.isEmpty else { return nil }

    let suffix = value[versionRange.upperBound...].lowercased()
    if suffix.contains("alpha") {
      prereleaseRank = 0
    } else if suffix.contains("beta") {
      prereleaseRank = 1
    } else if suffix.contains("rc") || suffix.contains("pre") {
      prereleaseRank = 2
    } else {
      prereleaseRank = 3
    }
  }

  static func < (lhs: ParsedVersion, rhs: ParsedVersion) -> Bool {
    let length = max(lhs.components.count, rhs.components.count)

    for index in 0..<length {
      let left = index < lhs.components.count ? lhs.components[index] : 0
      let right = index < rhs.components.count ? rhs.components[index] : 0
      if left != right {
        return left < right
      }
    }

    return lhs.prereleaseRank < rhs.prereleaseRank
  }
}
