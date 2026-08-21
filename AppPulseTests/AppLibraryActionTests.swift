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

  private func makeLibrary(
    application: AppRecord,
    scanner: any ApplicationScanning = EmptyActionScanner(),
    coordinator: any UpdateCoordinating = UpdateCoordinator()
  ) throws -> AppLibrary {
    let suiteName = "AppPulseTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    addTeardownBlock {
      defaults.removePersistentDomain(forName: suiteName)
    }
    return AppLibrary(
      applications: [application],
      scanner: scanner,
      coordinator: coordinator,
      userDefaults: defaults
    )
  }

  private func makeApplication(
    source: UpdateSource,
    status: UpdateStatus,
    sourceURL: URL? = nil,
    sourceIdentifier: String? = nil,
    canAutomaticallyUpdate: Bool = false
  ) -> AppRecord {
    AppRecord(
      name: "Example",
      bundleIdentifier: "com.example.application",
      applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
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

private struct EmptyActionScanner: ApplicationScanning {
  func scan() async -> [AppRecord] { [] }
}

private struct StaticActionScanner: ApplicationScanning {
  let applications: [AppRecord]

  func scan() async -> [AppRecord] { applications }
}

private actor RecordingActionUpdateCoordinator: UpdateCoordinating {
  private var updatedIDs: [AppRecord.ID] = []

  func check(_ applications: [AppRecord]) async -> [AppRecord] {
    applications
  }

  func update(_ application: AppRecord) async throws {
    updatedIDs.append(application.id)
  }

  func updatedApplicationIDs() -> [AppRecord.ID] {
    updatedIDs
  }
}
