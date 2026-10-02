import Foundation
import XCTest

@testable import Upkeep

final class SparkleDetectionTests: XCTestCase, @unchecked Sendable {
  private let feedURL = URL(string: "https://mac-releases.lorca.app/appcast.xml")!

  func testRedetectsSparkleWhenUnchangedApplicationWasCachedAsSelfManaged() throws {
    let applicationURL = try makeApplication()
    defer { try? FileManager.default.removeItem(at: applicationURL.deletingLastPathComponent()) }
    var cached = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
    cached.source = .selfManaged
    cached.sourceURL = nil
    cached.status = .selfManaged

    let recovered = try XCTUnwrap(
      ApplicationScanner.makeRecord(from: applicationURL, reusing: cached)
    )

    XCTAssertEqual(recovered.applicationModificationDate, cached.applicationModificationDate)
    XCTAssertEqual(recovered.source, .sparkle)
    XCTAssertEqual(recovered.sourceURL, feedURL)
    XCTAssertEqual(recovered.status, .checking)
  }

  func testInstalledScanRetainsSparkleFeed() throws {
    let applicationURL = try makeApplication()
    defer { try? FileManager.default.removeItem(at: applicationURL.deletingLastPathComponent()) }

    let application = try XCTUnwrap(
      ApplicationScanner.makeInstalledApplicationRecord(from: applicationURL)
    )

    XCTAssertEqual(application.source, .sparkle)
    XCTAssertEqual(application.sourceURL, feedURL)
    XCTAssertEqual(application.status, .checking)
  }

  func testFeedIdentifiesSparkleWithoutFrameworkAtStandardPath() throws {
    let applicationURL = try makeApplication(includeFramework: false)
    defer { try? FileManager.default.removeItem(at: applicationURL.deletingLastPathComponent()) }

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))

    XCTAssertEqual(application.source, .sparkle)
    XCTAssertEqual(application.sourceURL, feedURL)
  }

  func testValidSparkleCacheKeepsCheckedMetadata() throws {
    let applicationURL = try makeApplication()
    defer { try? FileManager.default.removeItem(at: applicationURL.deletingLastPathComponent()) }
    var cached = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
    cached.status = .updateAvailable
    cached.latestVersion = "1.0.9"
    cached.releaseNotes = "Cached notes"

    let reused = try XCTUnwrap(
      ApplicationScanner.makeRecord(from: applicationURL, reusing: cached)
    )

    XCTAssertEqual(reused.status, .updateAvailable)
    XCTAssertEqual(reused.latestVersion, "1.0.9")
    XCTAssertEqual(reused.releaseNotes, "Cached notes")
  }

  func testRecoveredLorcaRecordDetectsNewerRelease() async throws {
    let applicationURL = try makeApplication()
    defer { try? FileManager.default.removeItem(at: applicationURL.deletingLastPathComponent()) }
    var cached = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
    cached.source = .selfManaged
    cached.sourceURL = nil
    cached.status = .selfManaged
    let recovered = try XCTUnwrap(
      ApplicationScanner.makeRecord(from: applicationURL, reusing: cached)
    )
    let xml = """
      <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
        <channel><title>Lorca</title><item>
          <title>1.0.9</title>
          <pubDate>Fri, 02 Oct 2026 17:24:58 +0800</pubDate>
          <sparkle:version>1.0.9</sparkle:version>
          <sparkle:shortVersionString>1.0.9</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
          <enclosure url="https://mac-releases.lorca.app/Lorca-1.0.9.zip" length="21437319" />
          <sparkle:deltas>
            <enclosure url="https://mac-releases.lorca.app/Lorca1.0.9-1.0.7.delta" />
          </sparkle:deltas>
        </item></channel>
      </rss>
      """
    let feedURL = feedURL
    let provider = SparkleUpdateProvider(fetchData: { url in
      XCTAssertEqual(url, feedURL)
      return Data(xml.utf8)
    })

    let checked = await provider.check(recovered)

    XCTAssertEqual(checked.status, .updateAvailable)
    XCTAssertEqual(checked.latestVersion, "1.0.9")
    XCTAssertEqual(checked.latestBuildVersion, "1.0.9")
    XCTAssertEqual(checked.packageByteCount, 21_437_319)
    XCTAssertTrue(checked.canAutomaticallyUpdate)
  }

  private func makeApplication(includeFramework: Bool = true) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("UpkeepSparkleTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = directory.appendingPathComponent("Lorca.app", isDirectory: true)
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    if includeFramework {
      try FileManager.default.createDirectory(
        at: contentsURL.appendingPathComponent("Frameworks/Sparkle.framework", isDirectory: true),
        withIntermediateDirectories: true
      )
    }
    let info: [String: Any] = [
      "CFBundleIdentifier": "app.lorca",
      "CFBundleName": "Lorca",
      "CFBundlePackageType": "APPL",
      "CFBundleShortVersionString": "1.0.7",
      "CFBundleVersion": "1.0.7",
      "SUFeedURL": feedURL.absoluteString,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
    return applicationURL
  }
}
