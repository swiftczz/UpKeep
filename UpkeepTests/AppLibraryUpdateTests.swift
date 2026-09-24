import Foundation
import XCTest

@testable import Upkeep

@MainActor
final class AppLibraryUpdateTests: XCTestCase {
  func testInformationalSparkleUpdateOpensWebsiteWithoutInstallingOrQuitting() async throws {
    let application = AppRecord(
      name: "Resomark", bundleIdentifier: "com.resomark",
      applicationURL: URL(fileURLWithPath: "/Applications/Resomark.app"),
      currentVersion: "0.6.9", buildVersion: "1502",
      source: .sparkle, status: .updateAvailable,
      latestVersion: "0.6.10", latestBuildVersion: "1503",
      sourceURL: URL(string: "https://update.resomark.com/appcast.xml"),
      updatePageURL: URL(string: "https://resomark.com/private-beta?ref=updater&from=0.6.9")
    )
    let restored = try JSONDecoder().decode(AppRecord.self, from: JSONEncoder().encode(application))
    XCTAssertEqual(restored.manualUpdateURL, application.updatePageURL)
    let library = try makeLibrary(
      applications: [restored], runningBundleIdentifiers: [application.bundleIdentifier]
    )
    let requiresConfirmation = await library.requiresRelaunchConfirmation(for: restored)
    XCTAssertFalse(requiresConfirmation)
    XCTAssertTrue(library.automaticUpdates.isEmpty)
    let destination = await library.performPrimaryAction(for: application.id)
    XCTAssertEqual(destination, application.updatePageURL)

    var checking = application
    checking.status = .checking
    checking.updatePageURL = nil
    let merged = try XCTUnwrap(
      AppLibrary.mergeKeepingCheckResults([checking], previous: [application]).first
    )
    XCTAssertEqual(merged.manualUpdateURL, application.updatePageURL)

    var current = application
    current.status = .upToDate
    XCTAssertNil(current.manualUpdateURL)
    current.status = .updateAvailable
    current.canAutomaticallyUpdate = true
    XCTAssertNil(current.manualUpdateURL)
    current.canAutomaticallyUpdate = false
    current.updatePageURL = URL(string: "file:///tmp/App.app")
    XCTAssertNil(current.manualUpdateURL)
  }

  func testRequiresRelaunchConfirmationWhenUpdatableApplicationIsRunning() async throws {
    let application = makeUpdateApplication(name: "Running", bundleIdentifier: "com.example.running")
    let library = try makeLibrary(
      applications: [application],
      runningBundleIdentifiers: ["com.example.running"]
    )

    let requiresConfirmation = await library.requiresRelaunchConfirmation(for: application)
    XCTAssertTrue(requiresConfirmation)
    let runningApplications = await library.automaticUpdatesRequiringRelaunch()
    XCTAssertEqual(runningApplications.map(\.id), [application.id])
  }

  func testDoesNotRequireRelaunchConfirmationWhenApplicationIsNotRunning() async throws {
    let application = makeUpdateApplication(name: "Closed", bundleIdentifier: "com.example.closed")
    let library = try makeLibrary(
      applications: [application],
      runningBundleIdentifiers: []
    )

    let requiresConfirmation = await library.requiresRelaunchConfirmation(for: application)
    XCTAssertFalse(requiresConfirmation)
    let runningApplications = await library.automaticUpdatesRequiringRelaunch()
    XCTAssertTrue(runningApplications.isEmpty)
  }

  func testDoesNotRequireRelaunchConfirmationWhenPrimaryActionOpensTheApp() async throws {
    let application = AppRecord(
      name: "Open",
      bundleIdentifier: "com.example.open",
      applicationURL: URL(fileURLWithPath: "/Applications/Open.app"),
      currentVersion: "1.0",
      source: .sparkle,
      status: .upToDate
    )
    let library = try makeLibrary(
      applications: [application],
      runningBundleIdentifiers: ["com.example.open"]
    )

    let requiresConfirmation = await library.requiresRelaunchConfirmation(for: application)
    XCTAssertFalse(requiresConfirmation)
  }

  func testAutomaticUpdatesRequiringRelaunchIgnoresClosedAndIgnoredApps() async throws {
    let running = makeUpdateApplication(name: "Running", bundleIdentifier: "com.example.running")
    let closed = makeUpdateApplication(name: "Closed", bundleIdentifier: "com.example.closed")
    let ignored = makeUpdateApplication(name: "Ignored", bundleIdentifier: "com.example.ignored")
    let library = try makeLibrary(
      applications: [running, closed, ignored],
      runningBundleIdentifiers: ["com.example.running", "com.example.ignored"]
    )
    library.ignoreUpdates(for: ignored.id)

    let runningApplications = await library.automaticUpdatesRequiringRelaunch()
    XCTAssertEqual(runningApplications.map(\.name), ["Running"])
  }

  func testIPhoneAppStoreUpdateOpensUpdatesPage() async throws {
    let application = AppRecord(
      name: "Minis",
      bundleIdentifier: "com.openminis.app",
      applicationURL: URL(fileURLWithPath: "/Applications/Minis.app"),
      currentVersion: "1.12",
      source: .appStore,
      appStorePlatform: .iPhone,
      status: .updateAvailable,
      latestVersion: "1.13",
      sourceURL: URL(string: "https://apps.apple.com/cn/app/minis/id123456789"),
      canAutomaticallyUpdate: false
    )
    let library = try makeLibrary(
      applications: [application],
      runningBundleIdentifiers: []
    )

    let destination = await library.performPrimaryAction(for: application.id)

    XCTAssertEqual(destination?.scheme, "macappstore")
    XCTAssertEqual(destination?.host, "showUpdatesPage")
    XCTAssertTrue(library.automaticUpdates.isEmpty)
  }

  func testAppStoreUpdateOpensUpdatesPageWhenAppStoreCountryDiffersFromAccount() async throws {
    let application = AppRecord(
      name: "Clash",
      bundleIdentifier: "com.hako.network",
      applicationURL: URL(fileURLWithPath: "/Applications/Clash.app"),
      currentVersion: "1.0.6",
      source: .appStore,
      appStorePlatform: .mac,
      appStoreCountryCode: "us",
      appStoreAccountCountryCode: "cn",
      status: .updateAvailable,
      latestVersion: "1.0.7",
      sourceURL: URL(string: "https://apps.apple.com/us/app/clash/id6794257189"),
      canAutomaticallyUpdate: false
    )
    let library = try makeLibrary(
      applications: [application],
      runningBundleIdentifiers: []
    )

    let destination = await library.performPrimaryAction(for: application.id)

    XCTAssertEqual(destination?.scheme, "macappstore")
    XCTAssertEqual(destination?.host, "showUpdatesPage")
    XCTAssertTrue(library.automaticUpdates.isEmpty)
  }

  func testAppStoreUpdateOpensAppPageWhenAppStoreCountryMatchesAccount() async throws {
    let application = AppRecord(
      name: "Sequel Ace",
      bundleIdentifier: "com.sequel-ace.sequel-ace",
      applicationURL: URL(fileURLWithPath: "/Applications/Sequel Ace.app"),
      currentVersion: "5.3.1",
      source: .appStore,
      appStorePlatform: .mac,
      appStoreCountryCode: "us",
      appStoreAccountCountryCode: "USA",
      status: .updateAvailable,
      latestVersion: "5.4.0",
      sourceURL: URL(string: "https://apps.apple.com/us/app/sequel-ace/id1518036000"),
      canAutomaticallyUpdate: false
    )
    let library = try makeLibrary(
      applications: [application],
      runningBundleIdentifiers: []
    )

    let destination = await library.performPrimaryAction(for: application.id)

    XCTAssertEqual(destination?.scheme, "macappstore")
    XCTAssertEqual(destination?.host, "apps.apple.com")
    XCTAssertEqual(destination?.path, "/us/app/sequel-ace/id1518036000")
    XCTAssertTrue(library.automaticUpdates.isEmpty)
  }

  func testFailedUpdateKeepsOriginalSelectionAndReportsFailure() async throws {
    let eudic = makeUpdateApplication(
      name: "欧路词典",
      bundleIdentifier: "com.eusoft.eudic"
    )
    let tencent = makeUpdateApplication(
      name: "腾讯视频",
      bundleIdentifier: "com.tencent.tenvideo"
    )
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let library = AppLibrary(
      applications: [eudic, tencent],
      scanner: UpdateSelectionScanner(applications: [tencent, eudic]),
      coordinator: FailingUpdateCoordinator(),
      userDefaults: defaults,
      libraryStore: .memory()
    )
    library.selectedApplicationID = eudic.id

    _ = await library.performPrimaryAction(for: eudic.id)

    XCTAssertEqual(library.selectedApplicationID, eudic.id)
    XCTAssertEqual(library.selectedApplication?.name, "欧路词典")
    XCTAssertEqual(library.alertMessage, "模拟更新失败")
  }

  func testSuccessfulUpdateDoesNotSettleBeforeInstalledVersionAppears() async throws {
    let application = makeUpdateApplication(
      name: "Settled",
      bundleIdentifier: "com.example.settled"
    )
    let scanner = CountingUpdateScanner(applications: [application])
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let library = AppLibrary(
      applications: [application],
      scanner: scanner,
      coordinator: SuccessfulUpdateCoordinator(),
      userDefaults: defaults,
      libraryStore: .memory()
    )

    _ = await library.performPrimaryAction(for: application.id)
    let scanCount = await scanner.numberOfScans()

    XCTAssertEqual(library.availableUpdates.map(\.id), [application.id])
    XCTAssertEqual(library.applications.first?.currentVersion, "1.0")
    XCTAssertEqual(library.applications.first?.status, .updateAvailable)
    XCTAssertTrue(library.applications.first?.canAutomaticallyUpdate ?? false)
    XCTAssertNil(library.applications.first?.lastInstalledAt)
    XCTAssertEqual(scanCount, 0)
  }

  func testSuccessfulUpdateSettlesAfterInstalledVersionAppearsWithoutScanning() async throws {
    let applicationURL = try makeApplicationBundle(
      name: "Installed",
      bundleIdentifier: "com.example.installed",
      version: "1.0"
    )
    let application = AppRecord(
      name: "Installed",
      bundleIdentifier: "com.example.installed",
      applicationURL: applicationURL,
      currentVersion: "1.0",
      buildVersion: "1",
      source: .sparkle,
      status: .updateAvailable,
      latestVersion: "2.0",
      latestBuildVersion: "2",
      canAutomaticallyUpdate: true
    )
    let scanner = CountingUpdateScanner(applications: [application])
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let library = AppLibrary(
      applications: [application],
      scanner: scanner,
      coordinator: InstallingUpdateCoordinator(
        applicationURL: applicationURL,
        version: "2.0",
        buildVersion: "2"
      ),
      userDefaults: defaults,
      libraryStore: .memory()
    )

    _ = await library.performPrimaryAction(for: application.id)
    let scanCount = await scanner.numberOfScans()

    XCTAssertTrue(library.availableUpdates.isEmpty)
    XCTAssertEqual(library.applications.first?.currentVersion, "2.0")
    XCTAssertEqual(library.applications.first?.status, .upToDate)
    XCTAssertFalse(library.applications.first?.canAutomaticallyUpdate ?? true)
    XCTAssertNotNil(library.applications.first?.lastInstalledAt)
    XCTAssertEqual(scanCount, 0)
  }

  private func makeLibrary(
    applications: [AppRecord],
    coordinator: any UpdateCoordinating = UpdateCoordinator(),
    runningBundleIdentifiers: Set<String>
  ) throws -> AppLibrary {
    let suiteName = "UpkeepTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    addTeardownBlock {
      defaults.removePersistentDomain(forName: suiteName)
    }

    return AppLibrary(
      applications: applications,
      scanner: UpdateSelectionScanner(applications: applications),
      coordinator: coordinator,
      process: ApplicationProcessClient(
        isRunning: { runningBundleIdentifiers.contains($0.bundleIdentifier) },
        quit: { _ in },
        launch: { _ in }
      ),
      userDefaults: defaults,
      libraryStore: .memory()
    )
  }

  private func makeUpdateApplication(
    name: String,
    bundleIdentifier: String
  ) -> AppRecord {
    AppRecord(
      name: name,
      bundleIdentifier: bundleIdentifier,
      applicationURL: URL(fileURLWithPath: "/Applications/\(name).app"),
      currentVersion: "1.0",
      source: .sparkle,
      status: .updateAvailable,
      latestVersion: "2.0",
      canAutomaticallyUpdate: true
    )
  }

  private func makeApplicationBundle(
    name: String,
    bundleIdentifier: String,
    version: String
  ) throws -> URL {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "UpkeepTests-\(UUID().uuidString)",
      isDirectory: true
    )
    let applicationURL = rootURL.appendingPathComponent("\(name).app", isDirectory: true)
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    try InstallingUpdateCoordinator.writeInfoPlist(
      at: applicationURL,
      bundleIdentifier: bundleIdentifier,
      version: version,
      buildVersion: "1"
    )
    addTeardownBlock {
      try? FileManager.default.removeItem(at: rootURL)
    }
    return applicationURL
  }
}

private struct UpdateSelectionScanner: ApplicationScanning {
  let applications: [AppRecord]

  func scan() async -> [AppRecord] {
    applications
  }
}

private struct FailingUpdateCoordinator: UpdateCoordinating {
  func enrich(_ applications: [AppRecord]) async -> [AppRecord] {
    applications
  }

  func check(_ application: AppRecord) async -> AppRecord {
    application
  }

  func update(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    throw ProcessRunnerError.failed(status: 1, message: "模拟更新失败")
  }
}

private struct SuccessfulUpdateCoordinator: UpdateCoordinating {
  func enrich(_ applications: [AppRecord]) async -> [AppRecord] {
    applications
  }

  func check(_ application: AppRecord) async -> AppRecord {
    application
  }

  func update(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    progress(UpdateProgress(fractionCompleted: 1, status: "正在完成…"))
  }
}

private struct InstallingUpdateCoordinator: UpdateCoordinating {
  let applicationURL: URL
  let version: String
  let buildVersion: String

  func enrich(_ applications: [AppRecord]) async -> [AppRecord] {
    applications
  }

  func check(_ application: AppRecord) async -> AppRecord {
    application
  }

  func update(
    _ application: AppRecord,
    progress: @escaping @Sendable (UpdateProgress) -> Void
  ) async throws {
    try Self.writeInfoPlist(
      at: applicationURL,
      bundleIdentifier: application.bundleIdentifier,
      version: version,
      buildVersion: buildVersion
    )
    progress(UpdateProgress(fractionCompleted: 1, status: "正在完成…"))
  }

  static func writeInfoPlist(
    at applicationURL: URL,
    bundleIdentifier: String,
    version: String,
    buildVersion: String
  ) throws {
    let info: [String: Any] = [
      "CFBundleIdentifier": bundleIdentifier,
      "CFBundleDisplayName": applicationURL.deletingPathExtension().lastPathComponent,
      "CFBundleName": applicationURL.deletingPathExtension().lastPathComponent,
      "CFBundleShortVersionString": version,
      "CFBundleVersion": buildVersion,
      "CFBundleExecutable": "TestApplication",
      "CFBundlePackageType": "APPL",
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: info,
      format: .xml,
      options: 0
    )
    try data.write(
      to: applicationURL.appendingPathComponent("Contents/Info.plist"),
      options: .atomic
    )
  }
}

private actor CountingUpdateScanner: ApplicationScanning {
  let applications: [AppRecord]
  private var scanCount = 0

  init(applications: [AppRecord]) {
    self.applications = applications
  }

  func scan() async -> [AppRecord] {
    scanCount += 1
    return applications
  }

  func numberOfScans() -> Int {
    scanCount
  }
}
