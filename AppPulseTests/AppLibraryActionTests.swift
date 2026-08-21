import Foundation
import XCTest

@testable import AppPulse

@MainActor
final class AppLibraryActionTests: XCTestCase {
  func testSelfManagedPrimaryActionReturnsApplicationURL() async throws {
    let application = makeApplication(source: .selfManaged, status: .selfManaged)
    let library = try makeLibrary(application: application)

    let destination = await library.performPrimaryAction(for: application.id)

    XCTAssertEqual(destination, application.applicationURL)
  }

  func testAppStoreUpdateWithoutDirectSupportOpensApplication() async throws {
    let storeURL = try XCTUnwrap(URL(string: "https://apps.apple.com/app/id123456789"))
    let application = makeApplication(
      source: .appStore,
      status: .updateAvailable,
      sourceURL: storeURL
    )
    let library = try makeLibrary(application: application)

    let destination = await library.performPrimaryAction(for: application.id)

    XCTAssertEqual(destination, application.applicationURL)
  }

  func testAppStoreMenuActionReturnsNativeStoreURL() throws {
    let storeURL = try XCTUnwrap(URL(string: "https://apps.apple.com/app/id123456789"))
    let application = makeApplication(
      source: .appStore,
      status: .upToDate,
      sourceURL: storeURL
    )
    let library = try makeLibrary(application: application)

    let destination = library.appStoreURL(for: application.id)

    XCTAssertEqual(destination?.scheme, "macappstore")
    XCTAssertEqual(destination?.host, storeURL.host)
    XCTAssertEqual(destination?.path, storeURL.path)
  }

  func testAppStoreAutomaticUpdateUsesCoordinator() async throws {
    let application = makeApplication(
      source: .appStore,
      status: .updateAvailable,
      sourceURL: URL(string: "https://apps.apple.com/app/id1518036000"),
      sourceIdentifier: "1518036000",
      canAutomaticallyUpdate: true
    )
    let coordinator = RecordingActionUpdateCoordinator()
    let library = try makeLibrary(
      application: application,
      scanner: StaticActionScanner(applications: [application]),
      coordinator: coordinator
    )

    let destination = await library.performPrimaryAction(for: application.id)
    let updatedApplicationIDs = await coordinator.updatedApplicationIDs()

    XCTAssertNil(destination)
    XCTAssertEqual(updatedApplicationIDs, [application.id])
  }

  func testHomebrewAutomaticUpdateUsesCoordinator() async throws {
    let application = makeApplication(
      source: .homebrew,
      status: .updateAvailable,
      canAutomaticallyUpdate: true
    )
    let coordinator = RecordingActionUpdateCoordinator()
    let library = try makeLibrary(
      application: application,
      scanner: StaticActionScanner(applications: [application]),
      coordinator: coordinator
    )

    let destination = await library.performPrimaryAction(for: application.id)
    let updatedApplicationIDs = await coordinator.updatedApplicationIDs()

    XCTAssertNil(destination)
    XCTAssertEqual(updatedApplicationIDs, [application.id])
  }

  func testSparkleAutomaticUpdateUsesCoordinator() async throws {
    let application = makeApplication(
      source: .sparkle,
      status: .updateAvailable,
      sourceURL: URL(string: "https://example.com/appcast.xml"),
      canAutomaticallyUpdate: true
    )
    let coordinator = RecordingActionUpdateCoordinator()
    let library = try makeLibrary(
      application: application,
      scanner: StaticActionScanner(applications: [application]),
      coordinator: coordinator
    )

    let destination = await library.performPrimaryAction(for: application.id)
    let updatedApplicationIDs = await coordinator.updatedApplicationIDs()

    XCTAssertNil(destination)
    XCTAssertEqual(updatedApplicationIDs, [application.id])
  }

  func testOpeningFailureIsPublishedAsAnAlert() throws {
    let application = makeApplication(source: .selfManaged, status: .selfManaged)
    let library = try makeLibrary(application: application)

    library.reportOpeningFailure(for: application.applicationURL)

    XCTAssertEqual(library.alertMessage, "无法打开 Example.app。")
  }

  func testUpdateProgressIsPublishedWhileUpdating() async throws {
    let application = makeApplication(
      source: .homebrew,
      status: .updateAvailable,
      canAutomaticallyUpdate: true
    )
    let coordinator = GatedProgressUpdateCoordinator()
    let library = try makeLibrary(
      application: application,
      scanner: StaticActionScanner(applications: [application]),
      coordinator: coordinator
    )

    let updateTask = Task {
      _ = await library.performPrimaryAction(for: application.id)
    }
    await coordinator.waitUntilProgressReported()

    var observed = library.updateProgressByID[application.id]
    for _ in 0..<10_000 where observed?.fractionCompleted != 0.42 {
      await Task.yield()
      observed = library.updateProgressByID[application.id]
    }

    XCTAssertEqual(observed?.fractionCompleted, 0.42)
    XCTAssertEqual(observed?.status, "正在下载…")

    await coordinator.releaseUpdate()
    _ = await updateTask.value
    XCTAssertNil(library.updateProgressByID[application.id])
  }

  func testHomebrewOutputParserExtractsDownloadPercent() {
    let parser = HomebrewOutputProgressParser()
    let progress = parser.consuming("######################################################################## 64.0%")

    XCTAssertEqual(progress.fractionCompleted, 0.64)
    XCTAssertEqual(progress.status, "正在下载…")
  }

  func testHomebrewOutputParserCapsDownloadPercentBeforeInstall() {
    let parser = HomebrewOutputProgressParser()
    _ = parser.consuming("100.0%")
    let progress = parser.consuming("==> Installing foo")

    XCTAssertEqual(progress.fractionCompleted, 0.92)
    XCTAssertEqual(progress.status, "正在安装…")
  }

  func testSuccessfulUpdateShowsInstalledVersionWithoutManualRefresh() async throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("AppPulseTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "Settled.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let infoURL = contentsURL.appendingPathComponent("Info.plist")
    addTeardownBlock {
      try? fileManager.removeItem(at: temporaryDirectory)
    }

    try fileManager.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    try writeSettledInfo(version: "1.0", to: infoURL)

    let application = AppRecord(
      name: "Settled",
      bundleIdentifier: "com.example.settled",
      applicationURL: applicationURL,
      currentVersion: "1.0",
      source: .homebrew,
      status: .updateAvailable,
      latestVersion: "2.0",
      sourceIdentifier: "settled",
      canAutomaticallyUpdate: true
    )
    let coordinator = DiskWritingUpdateCoordinator(infoURL: infoURL, version: "2.0")
    let scanner = DiskBackedUpdateScanner(applicationURL: applicationURL, latestVersion: "2.0")
    let library = try makeLibrary(
      application: application,
      scanner: scanner,
      coordinator: coordinator
    )

    let destination = await library.performPrimaryAction(for: application.id)

    XCTAssertNil(destination)
    XCTAssertEqual(library.applications.first?.currentVersion, "2.0")
    XCTAssertEqual(library.applications.first?.status, .upToDate)
    XCTAssertFalse(library.applications.first?.needsUpdate ?? true)
    XCTAssertTrue(library.updatingApplicationIDs.isEmpty)
  }

  func testInstalledStatusWaitsUntilUpdateProgressFinishes() async throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("AppPulseTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "Pending.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let infoURL = contentsURL.appendingPathComponent("Info.plist")
    addTeardownBlock {
      try? fileManager.removeItem(at: temporaryDirectory)
    }

    try fileManager.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    try writeSettledInfo(version: "1.0", to: infoURL)

    let application = AppRecord(
      name: "Pending",
      bundleIdentifier: "com.example.settled",
      applicationURL: applicationURL,
      currentVersion: "1.0",
      source: .homebrew,
      status: .updateAvailable,
      latestVersion: "2.0",
      sourceIdentifier: "pending",
      canAutomaticallyUpdate: true
    )
    let coordinator = GatedDiskWritingUpdateCoordinator(infoURL: infoURL, version: "2.0")
    let scanner = DiskBackedUpdateScanner(applicationURL: applicationURL, latestVersion: "2.0")
    let library = try makeLibrary(
      application: application,
      scanner: scanner,
      coordinator: coordinator
    )

    let updateTask = Task {
      await library.performPrimaryAction(for: application.id)
    }
    await coordinator.waitUntilWritten()

    XCTAssertEqual(library.applications.first?.currentVersion, "1.0")
    XCTAssertEqual(library.applications.first?.status, .updateAvailable)
    XCTAssertTrue(library.updatingApplicationIDs.contains(application.id))

    await coordinator.releaseUpdate()
    _ = await updateTask.value

    XCTAssertEqual(library.applications.first?.currentVersion, "2.0")
    XCTAssertEqual(library.applications.first?.status, .upToDate)
    XCTAssertTrue(library.updatingApplicationIDs.isEmpty)
  }

  func testConcurrentUpdatesRefreshOnceAfterAllFinish() async throws {
    let first = makeApplication(
      name: "First",
      bundleIdentifier: "com.example.first",
      applicationURL: URL(fileURLWithPath: "/Applications/First.app"),
      source: .homebrew,
      status: .updateAvailable,
      canAutomaticallyUpdate: true
    )
    let second = makeApplication(
      name: "Second",
      bundleIdentifier: "com.example.second",
      applicationURL: URL(fileURLWithPath: "/Applications/Second.app"),
      source: .homebrew,
      status: .updateAvailable,
      canAutomaticallyUpdate: true
    )
    let coordinator = RecordingActionUpdateCoordinator()
    let library = try makeLibrary(
      applications: [first, second],
      scanner: StaticActionScanner(applications: [first, second]),
      coordinator: coordinator
    )

    async let firstDestination = library.performPrimaryAction(for: first.id)
    async let secondDestination = library.performPrimaryAction(for: second.id)
    let destinations = await (firstDestination, secondDestination)
    let checkCount = await coordinator.checkCount()
    let updatedApplicationIDs = await coordinator.updatedApplicationIDs()

    XCTAssertNil(destinations.0)
    XCTAssertNil(destinations.1)
    XCTAssertEqual(Set(updatedApplicationIDs), [first.id, second.id])
    XCTAssertEqual(checkCount, 1)
    XCTAssertTrue(library.updatingApplicationIDs.isEmpty)
  }

  func testHomebrewTreatsMatchingLocalVersionAsUpToDateEvenIfBrewIsStale() {
    let status = HomebrewUpdateProvider.resolvedStatus(
      currentVersion: "2.0",
      remoteVersion: "2.0",
      brewReportsOutdated: true,
      autoUpdates: nil
    )
    XCTAssertEqual(status, .upToDate)
  }

  func testHomebrewStillReportsUpdateWhenRemoteVersionIsNewer() {
    let status = HomebrewUpdateProvider.resolvedStatus(
      currentVersion: "1.0",
      remoteVersion: "2.0",
      brewReportsOutdated: true,
      autoUpdates: nil
    )
    XCTAssertEqual(status, .updateAvailable)
  }

  private func writeSettledInfo(version: String, to url: URL) throws {
    let values: [String: Any] = [
      "CFBundleIdentifier": "com.example.settled",
      "CFBundleName": "Settled",
      "CFBundleShortVersionString": version,
      "CFBundleVersion": version,
      "CFBundlePackageType": "APPL",
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: values,
      format: .xml,
      options: 0
    )
    try data.write(to: url)
  }

  private func makeLibrary(
    application: AppRecord,
    scanner: any ApplicationScanning = EmptyActionScanner(),
    coordinator: any UpdateCoordinating = UpdateCoordinator()
  ) throws -> AppLibrary {
    try makeLibrary(
      applications: [application],
      scanner: scanner,
      coordinator: coordinator
    )
  }

  private func makeLibrary(
    applications: [AppRecord],
    scanner: any ApplicationScanning = EmptyActionScanner(),
    coordinator: any UpdateCoordinating = UpdateCoordinator()
  ) throws -> AppLibrary {
    let suiteName = "AppPulseTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    addTeardownBlock {
      defaults.removePersistentDomain(forName: suiteName)
    }
    return AppLibrary(
      applications: applications,
      scanner: scanner,
      coordinator: coordinator,
      userDefaults: defaults
    )
  }

  private func makeApplication(
    name: String = "Example",
    bundleIdentifier: String = "com.example.application",
    applicationURL: URL = URL(fileURLWithPath: "/Applications/Example.app"),
    source: UpdateSource,
    status: UpdateStatus,
    sourceURL: URL? = nil,
    sourceIdentifier: String? = nil,
    canAutomaticallyUpdate: Bool = false
  ) -> AppRecord {
    AppRecord(
      name: name,
      bundleIdentifier: bundleIdentifier,
      applicationURL: applicationURL,
      currentVersion: "1.0",
      source: source,
      status: status,
      latestVersion: status == .updateAvailable ? "2.0" : nil,
      sourceURL: sourceURL,
      sourceIdentifier: sourceIdentifier,
      canAutomaticallyUpdate: canAutomaticallyUpdate
    )
  }
}

private actor DiskWritingUpdateCoordinator: UpdateCoordinating {
  private let infoURL: URL
  private let version: String

  init(infoURL: URL, version: String) {
    self.infoURL = infoURL
    self.version = version
  }

  func check(_ applications: [AppRecord]) async -> [AppRecord] {
    applications
  }

  func update(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    let values: [String: Any] = [
      "CFBundleIdentifier": "com.example.settled",
      "CFBundleName": "Settled",
      "CFBundleShortVersionString": version,
      "CFBundleVersion": version,
      "CFBundlePackageType": "APPL",
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: values,
      format: .xml,
      options: 0
    )
    try data.write(to: infoURL)
    progress(UpdateProgress(fractionCompleted: 1, status: "正在完成…"))
  }
}

private actor GatedDiskWritingUpdateCoordinator: UpdateCoordinating {
  private let infoURL: URL
  private let version: String
  private var written = false
  private var released = false

  init(infoURL: URL, version: String) {
    self.infoURL = infoURL
    self.version = version
  }

  func check(_ applications: [AppRecord]) async -> [AppRecord] {
    applications
  }

  func update(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    let values: [String: Any] = [
      "CFBundleIdentifier": "com.example.settled",
      "CFBundleName": "Settled",
      "CFBundleShortVersionString": version,
      "CFBundleVersion": version,
      "CFBundlePackageType": "APPL",
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: values,
      format: .xml,
      options: 0
    )
    try data.write(to: infoURL)
    progress(UpdateProgress(fractionCompleted: 1, status: "正在完成…"))
    written = true
    while !released {
      await Task.yield()
    }
  }

  func waitUntilWritten() async {
    while !written {
      await Task.yield()
    }
  }

  func releaseUpdate() {
    released = true
  }
}

private struct DiskBackedUpdateScanner: ApplicationScanning {
  let applicationURL: URL
  let latestVersion: String

  func scan() async -> [AppRecord] {
    guard var record = ApplicationScanner.makeRecord(from: applicationURL) else {
      return []
    }

    record.source = .homebrew
    record.latestVersion = latestVersion
    record.canAutomaticallyUpdate = true
    if VersionComparator.isNewer(latestVersion, than: record.currentVersion) {
      record.status = .updateAvailable
    } else {
      record.status = .upToDate
    }
    return [record]
  }
}

private actor GatedProgressUpdateCoordinator: UpdateCoordinating {
  private var progressReported = false
  private var released = false

  func check(_ applications: [AppRecord]) async -> [AppRecord] {
    applications
  }

  func update(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    progress(UpdateProgress(fractionCompleted: 0.42, status: "正在下载…"))
    progressReported = true
    while !released {
      await Task.yield()
    }
  }

  func waitUntilProgressReported() async {
    while !progressReported {
      await Task.yield()
    }
  }

  func releaseUpdate() {
    released = true
  }
}

private struct EmptyActionScanner: ApplicationScanning {
  func scan() async -> [AppRecord] { [] }
}

private struct StaticActionScanner: ApplicationScanning {
  let applications: [AppRecord]

  func scan() async -> [AppRecord] { applications }
}

private actor RecordingActionUpdateCoordinator: UpdateCoordinating {
  private var updatedIDs: [AppRecord.ID] = []
  private var checks = 0

  func check(_ applications: [AppRecord]) async -> [AppRecord] {
    checks += 1
    return applications
  }

  func update(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    updatedIDs.append(application.id)
  }

  func updatedApplicationIDs() -> [AppRecord.ID] {
    updatedIDs
  }

  func checkCount() -> Int {
    checks
  }
}
