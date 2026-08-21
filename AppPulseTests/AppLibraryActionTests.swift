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

  func testAppStoreUpdatePrimaryActionReturnsNativeStoreURL() async throws {
    let storeURL = try XCTUnwrap(URL(string: "https://apps.apple.com/app/id123456789"))
    let application = makeApplication(
      source: .appStore,
      status: .updateAvailable,
      sourceURL: storeURL
    )
    let library = try makeLibrary(application: application)

    let destination = await library.performPrimaryAction(for: application.id)

    XCTAssertEqual(destination?.scheme, "macappstore")
    XCTAssertEqual(destination?.host, storeURL.host)
    XCTAssertEqual(destination?.path, storeURL.path)
  }

  func testHomebrewUpdatePrimaryActionReturnsApplicationURL() async throws {
    let application = makeApplication(
      source: .homebrew,
      status: .updateAvailable,
      canAutomaticallyUpdate: true
    )
    let library = try makeLibrary(application: application)

    let destination = await library.performPrimaryAction(for: application.id)

    XCTAssertEqual(destination, application.applicationURL)
  }

  func testOpeningFailureIsPublishedAsAnAlert() throws {
    let application = makeApplication(source: .selfManaged, status: .selfManaged)
    let library = try makeLibrary(application: application)

    library.reportOpeningFailure(for: application.applicationURL)

    XCTAssertEqual(library.alertMessage, "无法打开 Example.app。")
  }

  private func makeLibrary(application: AppRecord) throws -> AppLibrary {
    let suiteName = "AppPulseTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    addTeardownBlock {
      defaults.removePersistentDomain(forName: suiteName)
    }
    return AppLibrary(applications: [application], userDefaults: defaults)
  }

  private func makeApplication(
    source: UpdateSource,
    status: UpdateStatus,
    sourceURL: URL? = nil,
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
      canAutomaticallyUpdate: canAutomaticallyUpdate
    )
  }
}
