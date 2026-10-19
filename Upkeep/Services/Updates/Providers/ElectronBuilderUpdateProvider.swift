import Foundation

struct ElectronBuilderUpdateProvider: Sendable {
  func check(_ application: AppRecord) async -> AppRecord {
    var application = application

    guard let feedURL = application.updateConfiguration.feedURL,
      SecureUpdateURL.https(feedURL) != nil
    else {
      application.status = .selfManaged
      return application
    }

    do {
      let manifest = try await loadManifest(from: feedURL)
      let package = manifest.selectedPackage(relativeTo: feedURL)
      application.updateConfiguration.homepageURL =
        application.updateConfiguration.homepageURL ?? application.updateConfiguration.feedURL
      application.applyRemoteRelease(
        version: manifest.version,
        releaseDate: manifest.releaseDate,
        releaseNotes: manifest.releaseNotes?.nonBlankYAMLValue,
        packageByteCount: package?.size,
        canInstall: package != nil
      )
    } catch is CancellationError {
      return application
    } catch {
      application.status = .unavailable("Electron Updater 更新源暂时无法访问。")
    }

    return application
  }

  func upgrade(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    guard let feedURL = application.updateConfiguration.feedURL,
      SecureUpdateURL.https(feedURL) != nil
    else {
      throw ProcessRunnerError.failed(status: 1, message: "此应用没有安全的 Electron Updater 更新源。")
    }

    progress(.indeterminate("正在检查更新…"))
    let manifest = try await loadManifest(from: feedURL)
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

  private func loadManifest(from feedURL: URL) async throws -> ElectronBuilderManifest {
    guard
      let data = try await UpdateHTTP.successfulData(from: feedURL),
      let text = String(data: data, encoding: .utf8),
      let manifest = ElectronBuilderYAML.parseManifest(text)
    else {
      throw ProcessRunnerError.failed(status: 1, message: "无法读取 Electron Updater 更新清单。")
    }
    return manifest
  }
}
