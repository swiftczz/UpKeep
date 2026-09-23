import Foundation

struct VSCodeUpdatePayload: Equatable, Sendable {
  var productVersion: String
  var commit: String?
  var downloadURL: URL?
  var sha256: String?
  var timestamp: Date?
  var notes: String?

  static func parse(_ data: Data) -> VSCodeUpdatePayload? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }

    let productVersion =
      (json["productVersion"] as? String)?.nonBlankValue
      ?? versionLikeValue(json["name"] as? String)
    guard let productVersion else {
      return nil
    }

    let commit = (json["version"] as? String)?.nonBlankValue
    let notes = (json["notes"] as? String)?.nonBlankValue
    return VSCodeUpdatePayload(
      productVersion: productVersion,
      commit: commit,
      downloadURL: (json["url"] as? String).flatMap(SecureUpdateURL.https(string:)),
      sha256: (json["sha256hash"] as? String)?.nonBlankValue,
      timestamp: timestamp(from: json["timestamp"]),
      notes: isCommitHash(notes) || notes == commit ? nil : notes
    )
  }

  var packageURL: URL? {
    guard let downloadURL,
      ApplicationPackageInstaller.packageKindScore(of: downloadURL.lastPathComponent) > 0
    else {
      return nil
    }
    return downloadURL
  }

  func shouldOfferUpdate(
    against currentVersion: String,
    currentCommit: String?,
    currentBuildVersion: String?
  ) -> Bool {
    if VersionComparator.isNewer(productVersion, than: currentVersion) {
      return true
    }
    guard productVersion.localizedCaseInsensitiveCompare(currentVersion) == .orderedSame,
      let remoteCommit = commit?.nonBlankValue,
      let currentCommit = currentCommit?.nonBlankValue
    else {
      return false
    }
    if Self.commitsMatch(remoteCommit, currentCommit) {
      return false
    }
    if let currentBuildVersion,
      Self.commitsMatch(remoteCommit, currentBuildVersion)
    {
      return false
    }
    return true
  }

  private static func commitsMatch(_ first: String, _ second: String) -> Bool {
    let first = first.lowercased()
    let second = second.lowercased()
    guard (7...40).contains(first.count), (7...40).contains(second.count),
      first.allSatisfy(\.isHexDigit), second.allSatisfy(\.isHexDigit)
    else {
      return false
    }
    return first.hasPrefix(second) || second.hasPrefix(first)
  }

  private static func versionLikeValue(_ value: String?) -> String? {
    guard let value = value?.nonBlankValue, value.first?.isNumber == true else {
      return nil
    }
    return value
  }

  private static func isCommitHash(_ value: String?) -> Bool {
    guard let value, value.count == 40 else {
      return false
    }
    return value.allSatisfy(\.isHexDigit)
  }

  private static func timestamp(from value: Any?) -> Date? {
    let milliseconds: Double
    if let number = value as? Double {
      milliseconds = number
    } else if let number = value as? Int {
      milliseconds = Double(number)
    } else if let text = value as? String, let number = Double(text) {
      milliseconds = number
    } else {
      return nil
    }

    if milliseconds >= 1_000_000_000_000 {
      return Date(timeIntervalSince1970: milliseconds / 1000)
    }
    if milliseconds >= 1_000_000_000 {
      return Date(timeIntervalSince1970: milliseconds)
    }
    return nil
  }
}

struct VSCodeUpdateProvider: Sendable {
  func check(_ application: AppRecord) async -> AppRecord {
    var application = application

    guard let request = Self.updateRequest(for: application) else {
      application.status = .selfManaged
      return application
    }

    do {
      switch try await fetchPayload(
        request,
        currentVersion: application.currentVersion,
        currentBuildVersion: application.buildVersion
      ) {
      case .upToDate:
        application.latestVersion = application.currentVersion
        application.latestBuildVersion = application.buildVersion
        application.status = .upToDate
        application.canAutomaticallyUpdate = false
      case .update(let payload):
        application.applyRemoteRelease(
          version: payload.productVersion,
          releaseDate: payload.timestamp,
          releaseNotes: payload.notes,
          canInstall: payload.packageURL != nil
        )
        application.latestBuildVersion = payload.commit.map { String($0.prefix(7)) }
        if payload.productVersion.localizedCaseInsensitiveCompare(application.currentVersion)
          == .orderedSame
        {
          application.latestBuildVersion = payload.commit.map { String($0.prefix(7)) }
          application.status = .updateAvailable
          application.canAutomaticallyUpdate = payload.packageURL != nil
        }
      case .notThisProtocol:
        application.source = .selfManaged
        application.status = .selfManaged
        application.canAutomaticallyUpdate = false
      }
    } catch is CancellationError {
      return application
    } catch {
      application.status = .unavailable("VS Code updater 更新源暂时无法访问。")
    }

    return application
  }

  func upgrade(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    guard let request = Self.updateRequest(for: application) else {
      throw ProcessRunnerError.failed(status: 1, message: "此应用没有安全的 VS Code updater 更新源。")
    }

    progress(.indeterminate("正在检查更新…"))
    guard
      case .update(let payload) = try await fetchPayload(
        request,
        currentVersion: application.currentVersion,
        currentBuildVersion: application.buildVersion
      ),
      let packageURL = payload.packageURL
    else {
      throw ProcessRunnerError.failed(status: 1, message: "更新源中没有兼容此 Mac 的安装包。")
    }

    try await ApplicationPackageInstaller.install(
      from: packageURL,
      replacing: application,
      expectedSHA512: nil,
      expectedSHA256: payload.sha256,
      progress: progress
    )
  }

  private enum FetchResult {
    case upToDate
    case update(VSCodeUpdatePayload)
    case notThisProtocol
  }

  private struct UpdateRequest {
    let updateURL: URL
    let quality: String
    let commit: String
  }

  private static func updateRequest(for application: AppRecord) -> UpdateRequest? {
    guard let updateURL = application.sourceURL.flatMap(SecureUpdateURL.https),
      let identifier = application.sourceIdentifier,
      let parsed = VSCodeUpdaterDetector.parseSourceIdentifier(identifier)
    else {
      return nil
    }
    return UpdateRequest(updateURL: updateURL, quality: parsed.quality, commit: parsed.commit)
  }

  private func fetchPayload(
    _ request: UpdateRequest,
    currentVersion: String,
    currentBuildVersion: String?
  ) async throws -> FetchResult {
    var sawNotFound = false
    var sawOtherFailure = false

    for platform in VSCodeUpdaterDetector.platforms() {
      guard
        let url = VSCodeUpdaterDetector.checkURL(
          updateURL: request.updateURL,
          platform: platform,
          quality: request.quality,
          commit: request.commit
        )
      else {
        continue
      }

      guard let response = try await UpdateHTTP.response(from: url) else {
        sawOtherFailure = true
        continue
      }

      if response.statusCode == 204 {
        return .upToDate
      }
      if response.statusCode == 200, let payload = VSCodeUpdatePayload.parse(response.data) {
        return payload.shouldOfferUpdate(
          against: currentVersion,
          currentCommit: request.commit,
          currentBuildVersion: currentBuildVersion
        ) ? .update(payload) : .upToDate
      }
      if response.statusCode == 404 {
        sawNotFound = true
        continue
      }
      sawOtherFailure = true
    }

    if sawNotFound && !sawOtherFailure {
      return .notThisProtocol
    }
    throw ProcessRunnerError.failed(status: 1, message: "无法读取 VS Code updater 更新清单。")
  }
}
