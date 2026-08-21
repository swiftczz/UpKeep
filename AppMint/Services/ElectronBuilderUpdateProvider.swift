import Foundation

struct ElectronBuilderUpdateProvider: Sendable {
  func check(_ application: AppRecord) async -> AppRecord {
    var application = application

    guard let feedURL = application.sourceURL,
      SecureUpdateURL.https(feedURL) != nil
    else {
      application.status = .selfManaged
      return application
    }

    do {
      let manifest = try await loadManifest(for: application, feedURL: feedURL)
      application.latestVersion = manifest.version
      application.releaseDate = manifest.releaseDate
      application.releaseNotes = manifest.releaseNotes?.nonBlankYAMLValue
      application.homepageURL = application.homepageURL ?? application.sourceURL

      let package = manifest.selectedPackage(relativeTo: feedURL)
      let updateIsAvailable = VersionComparator.isNewer(
        manifest.version,
        than: application.currentVersion
      )
      application.status = updateIsAvailable ? .updateAvailable : .upToDate
      application.canAutomaticallyUpdate = updateIsAvailable && package != nil
    } catch is CancellationError {
      return application
    } catch {
      application.status = .unavailable("Electron-builder 更新源暂时无法访问。")
    }

    return application
  }

  func upgrade(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    guard let feedURL = application.sourceURL,
      SecureUpdateURL.https(feedURL) != nil
    else {
      throw ProcessRunnerError.failed(status: 1, message: "此应用没有安全的 Electron-builder 更新源。")
    }

    progress(.indeterminate("正在检查更新…"))
    let manifest = try await loadManifest(for: application, feedURL: feedURL)
    guard let package = manifest.selectedPackage(relativeTo: feedURL) else {
      throw ProcessRunnerError.failed(status: 1, message: "更新源中没有兼容此 Mac 的安装包。")
    }

    try await ApplicationPackageInstaller.install(
      from: package.url,
      replacing: application,
      expectedSHA512: package.sha512,
      progress: progress
    )
  }

  private func loadManifest(
    for application: AppRecord,
    feedURL: URL
  ) async throws -> ElectronBuilderManifest {
    if let manifest = try await fetchManifest(from: feedURL) {
      return manifest
    }

    if let repository = application.sourceIdentifier,
      repository.contains("/"),
      let manifest = try await fetchGitHubReleaseManifest(
        repository: repository,
        preferredFileName: feedURL.lastPathComponent
      )
    {
      return manifest
    }

    throw ProcessRunnerError.failed(status: 1, message: "无法读取 Electron-builder 更新清单。")
  }

  private func fetchManifest(from url: URL) async throws -> ElectronBuilderManifest? {
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("AppMint", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode),
      let text = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    return ElectronBuilderYAML.parseManifest(text)
  }

  private func fetchGitHubReleaseManifest(
    repository: String,
    preferredFileName: String
  ) async throws -> ElectronBuilderManifest? {
    guard
      let apiURL = SecureUpdateURL.https(
        string: "https://api.github.com/repos/\(repository)/releases/latest"
      )
    else {
      return nil
    }

    var request = URLRequest(url: apiURL)
    request.timeoutInterval = 15
    request.setValue("AppMint", forHTTPHeaderField: "User-Agent")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      return nil
    }

    let release = try JSONDecoder().decode(GitHubLatestRelease.self, from: data)
    let preferredNames = [preferredFileName, "latest-mac.yml", "latest.yml"]
    guard
      let asset = preferredNames.compactMap({ name in
        release.assets.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
      }).first,
      var manifest = try await fetchManifest(from: asset.browserDownloadURL)
    else {
      return nil
    }

    if manifest.releaseNotes == nil {
      manifest.releaseNotes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return manifest
  }
}

private struct GitHubLatestRelease: Decodable {
  struct Asset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
      case name
      case browserDownloadURL = "browser_download_url"
    }
  }

  let assets: [Asset]
  let body: String?
}
