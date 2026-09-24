import Darwin
import Foundation
import XCTest

@testable import Upkeep

final class ApplicationScannerTests: XCTestCase {
  func testUsesLocalizedNameWhenRawDisplayNameIsBlank() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "Eudic.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
    let localizationURL = resourcesURL.appendingPathComponent(
      "zh-Hans.lproj",
      isDirectory: true
    )
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(
      at: localizationURL,
      withIntermediateDirectories: true
    )
    try writePropertyList(
      [
        "CFBundleIdentifier": "com.example.eudic",
        "CFBundleDisplayName": "",
        "CFBundleName": "Eudic",
        "CFBundleShortVersionString": "26.5.0",
        "CFBundlePackageType": "APPL",
      ],
      to: contentsURL.appendingPathComponent("Info.plist")
    )
    try writePropertyList(
      [
        "CFBundleDisplayName": "欧路词典",
        "CFBundleName": "欧路词典",
      ],
      to: localizationURL.appendingPathComponent("InfoPlist.strings")
    )

    let application = try XCTUnwrap(
      ApplicationScanner.makeRecord(
        from: applicationURL,
        preferredLanguages: ["zh-Hans-CN"]
      )
    )

    XCTAssertEqual(application.name, "欧路词典")
  }

  func testReloadsVersionAfterApplicationIsUpdatedInPlace() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "Updated.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let infoURL = contentsURL.appendingPathComponent("Info.plist")
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    try writePropertyList(
      basicInfo(
        bundleIdentifier: "com.example.updated",
        extraValues: ["CFBundleShortVersionString": "1.0"]
      ),
      to: infoURL
    )

    let original = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))

    try writePropertyList(
      basicInfo(
        bundleIdentifier: "com.example.updated",
        extraValues: ["CFBundleShortVersionString": "2.0"]
      ),
      to: infoURL
    )
    let updated = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))

    XCTAssertEqual(original.currentVersion, "1.0")
    XCTAssertEqual(updated.currentVersion, "2.0")
  }

  func testReusesCachedRecordWhenBundleIdentityVersionAndModificationDateAreUnchanged() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "Cached.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let infoURL = contentsURL.appendingPathComponent("Info.plist")
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    try writePropertyList(
      basicInfo(bundleIdentifier: "com.example.cached"),
      to: infoURL
    )

    var cached = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
    cached.source = .githubReleases
    cached.sourceIdentifier = "example/cached"
    cached.releaseNotes = "Cached release notes"

    let reused = try XCTUnwrap(
      ApplicationScanner.makeRecord(from: applicationURL, reusing: cached)
    )

    XCTAssertEqual(reused.source, .githubReleases)
    XCTAssertEqual(reused.sourceIdentifier, "example/cached")
    XCTAssertEqual(reused.releaseNotes, "Cached release notes")

    try writePropertyList(
      basicInfo(
        bundleIdentifier: "com.example.cached",
        extraValues: ["CFBundleShortVersionString": "2.0"]
      ),
      to: infoURL
    )
    let changed = try XCTUnwrap(
      ApplicationScanner.makeRecord(from: applicationURL, reusing: cached)
    )

    XCTAssertEqual(changed.currentVersion, "2.0")
    XCTAssertNil(changed.releaseNotes)
  }

  func testSortsNewestApplicationBundleFirst() {
    let older = makeApplication(name: "Older", modifiedAt: Date(timeIntervalSince1970: 100))
    let newer = makeApplication(name: "Newer", modifiedAt: Date(timeIntervalSince1970: 200))
    let unknown = makeApplication(name: "Unknown", modifiedAt: nil)

    let sorted = ApplicationScanner.sortedByModificationDate([older, unknown, newer])

    XCTAssertEqual(sorted.map(\.name), ["Newer", "Older", "Unknown"])
  }

  func testAvailableUpdatesAreSortedByReleaseDateDescending() {
    let older = makeApplication(
      name: "Older",
      status: .updateAvailable,
      releaseDate: Date(timeIntervalSince1970: 100)
    )
    let newer = makeApplication(
      name: "Newer",
      status: .updateAvailable,
      releaseDate: Date(timeIntervalSince1970: 200)
    )
    let missing = makeApplication(name: "Missing", status: .updateAvailable)
    let installed = makeApplication(
      name: "Installed",
      modifiedAt: Date(timeIntervalSince1970: 500)
    )

    let available = [missing, installed, older, newer].availableUpdates(ignoredIDs: [])

    XCTAssertEqual(available.map(\.name), ["Newer", "Older", "Missing"])
  }

  func testCachedUpdateStaysInAvailableUpdatesWhileRechecking() {
    var checking = makeApplication(name: "Checking", status: .checking)
    checking.latestVersion = "2.0"
    var unavailable = makeApplication(name: "Unavailable", status: .unavailable("timeout"))
    unavailable.latestVersion = "2.0"
    let current = makeApplication(name: "Current")

    let applications = [checking, unavailable, current]

    XCTAssertEqual(
      applications.availableUpdates(ignoredIDs: []).map(\.name),
      ["Checking", "Unavailable"]
    )
    XCTAssertEqual(applications.installedApplications().map(\.name), ["Current"])
  }

  func testInstalledApplicationsAreSortedByModificationDateDescending() {
    let older = makeApplication(name: "Older", modifiedAt: Date(timeIntervalSince1970: 100))
    let newer = makeApplication(name: "Newer", modifiedAt: Date(timeIntervalSince1970: 200))
    let ignored = makeApplication(
      name: "Ignored",
      modifiedAt: Date(timeIntervalSince1970: 150),
      status: .updateAvailable,
      releaseDate: Date(timeIntervalSince1970: 400)
    )
    let unknown = makeApplication(name: "Unknown", modifiedAt: nil)

    let installed = [unknown, ignored, older, newer].installedApplications()

    XCTAssertEqual(installed.map(\.name), ["Newer", "Older", "Unknown"])
  }

  func testInstalledApplicationsPreferLastInstalledAtOverPackageModificationDate() {
    let olderPackage = Date(timeIntervalSince1970: 100)
    let newerPackage = Date(timeIntervalSince1970: 200)
    let installedNow = Date(timeIntervalSince1970: 300)

    var grok = makeApplication(name: "Grok", modifiedAt: olderPackage)
    grok.lastInstalledAt = installedNow
    let other = makeApplication(name: "Other", modifiedAt: newerPackage)

    XCTAssertEqual([other, grok].installedApplications().map(\.name), ["Grok", "Other"])
  }

  func testInstalledApplicationsOnTheSameDayAreSortedByTimeDescending() {
    let calendar = Calendar(identifier: .gregorian)
    let day = calendar.date(from: DateComponents(year: 2026, month: 8, day: 21))!
    let morning = calendar.date(bySettingHour: 9, minute: 10, second: 11, of: day)!
    let evening = calendar.date(bySettingHour: 18, minute: 20, second: 21, of: day)!
    let noon = calendar.date(bySettingHour: 12, minute: 0, second: 1, of: day)!

    let installed = [
      makeApplication(name: "Morning", modifiedAt: morning),
      makeApplication(name: "Evening", modifiedAt: evening),
      makeApplication(name: "Noon", modifiedAt: noon),
    ].installedApplications()

    XCTAssertEqual(installed.map(\.name), ["Evening", "Noon", "Morning"])
    XCTAssertEqual(Set(installed.compactMap(\.applicationModificationDate?.slashDateText)), ["2026/08/21"])
  }

  func testAvailableUpdatesWithoutReleaseDateFallBackToModificationTime() {
    let calendar = Calendar(identifier: .gregorian)
    let day = calendar.date(from: DateComponents(year: 2026, month: 8, day: 21))!
    let earlier = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day)!
    let later = calendar.date(bySettingHour: 10, minute: 0, second: 30, of: day)!

    let first = makeApplication(
      name: "Alpha",
      modifiedAt: later,
      status: .updateAvailable
    )
    let second = makeApplication(
      name: "Zed",
      modifiedAt: earlier,
      status: .updateAvailable
    )

    XCTAssertEqual(
      [second, first].availableUpdates(ignoredIDs: []).map(\.name),
      ["Alpha", "Zed"]
    )
  }

  func testIgnoredUpdatesAreSortedByReleaseDateAndExcludedFromInstalledApplications() {
    let older = makeApplication(name: "Older", modifiedAt: Date(timeIntervalSince1970: 100))
    let newerIgnored = makeApplication(
      name: "Newer Ignored",
      modifiedAt: Date(timeIntervalSince1970: 150),
      status: .updateAvailable,
      releaseDate: Date(timeIntervalSince1970: 400)
    )
    let olderIgnored = makeApplication(
      name: "Older Ignored",
      modifiedAt: Date(timeIntervalSince1970: 50),
      status: .updateAvailable,
      releaseDate: Date(timeIntervalSince1970: 200)
    )

    let applications = [older, newerIgnored, olderIgnored]
    let ignoredIDs = Set([newerIgnored.id, olderIgnored.id])

    XCTAssertEqual(applications.installedApplications().map(\.name), ["Older"])
    XCTAssertEqual(
      applications.ignoredUpdates(ignoredIDs: ignoredIDs).map(\.name),
      ["Newer Ignored", "Older Ignored"]
    )
    XCTAssertTrue(applications.ignoredUpdates(ignoredIDs: []).isEmpty)
  }

  func testSlashDateTextUsesYearMonthDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let date = calendar.date(from: DateComponents(year: 2021, month: 1, day: 1))

    XCTAssertEqual(date?.slashDateText, "2021/01/01")
  }

  func testSidebarDateFallsBackToModificationDateWhenReleaseDateIsMissing() {
    let modifiedAt = Date(timeIntervalSince1970: 1_609_459_200)
    let application = makeApplication(
      name: "Claude",
      modifiedAt: modifiedAt,
      status: .updateAvailable
    )

    XCTAssertEqual(application.sidebarDate(isUpdateIgnored: false), modifiedAt)
    XCTAssertFalse(application.sidebarDateIsReleaseDate)
  }

  func testSidebarDatePrefersReleaseDateForAvailableUpdates() {
    let modifiedAt = Date(timeIntervalSince1970: 100)
    let releasedAt = Date(timeIntervalSince1970: 200)
    let application = makeApplication(
      name: "Proxyman",
      modifiedAt: modifiedAt,
      status: .updateAvailable,
      releaseDate: releasedAt
    )

    XCTAssertEqual(application.sidebarDate(isUpdateIgnored: false), releasedAt)
    XCTAssertTrue(application.sidebarDateIsReleaseDate)
  }

  func testSidebarDatePrefersLastInstalledAtForInstalledApplications() {
    let modifiedAt = Date(timeIntervalSince1970: 100)
    let installedAt = Date(timeIntervalSince1970: 200)
    var application = makeApplication(name: "Kumone", modifiedAt: modifiedAt)
    application.lastInstalledAt = installedAt

    XCTAssertEqual(application.sidebarDate(isUpdateIgnored: false), installedAt)
    XCTAssertFalse(application.sidebarDateIsReleaseDate)
  }

  func testSidebarDateDoesNotUseLastInstalledAtForAvailableUpdates() {
    let modifiedAt = Date(timeIntervalSince1970: 100)
    let releasedAt = Date(timeIntervalSince1970: 150)
    let installedAt = Date(timeIntervalSince1970: 300)
    var application = makeApplication(
      name: "Update",
      modifiedAt: modifiedAt,
      status: .updateAvailable,
      releaseDate: releasedAt
    )
    application.lastInstalledAt = installedAt

    XCTAssertEqual(application.sidebarDate(isUpdateIgnored: false), releasedAt)
    XCTAssertTrue(application.sidebarDateIsReleaseDate)
  }

  func testLastInstalledAtSurvivesJSONRoundTrip() throws {
    var application = makeApplication(
      name: "Grok",
      modifiedAt: Date(timeIntervalSince1970: 100)
    )
    application.lastInstalledAt = Date(timeIntervalSince1970: 1_777_000_000)

    let decoded = try JSONDecoder().decode(
      AppRecord.self,
      from: try JSONEncoder().encode(application)
    )

    XCTAssertEqual(decoded.lastInstalledAt, application.lastInstalledAt)
  }

  func testAlternateUpdateSourceSurvivesJSONRoundTrip() throws {
    var application = makeApplication(
      name: "Termio",
      modifiedAt: Date(timeIntervalSince1970: 100)
    )
    application.source = .homebrew
    application.sourceIdentifier = "termio"
    application.homebrewCaskToken = "termio"
    application.alternateUpdateSource = .sparkle
    application.alternateSourceURL = URL(string: "https://downloads.termio.sh/appcast.xml")
    application.alternateHomepageURL = URL(string: "https://termio.sh/")

    let decoded = try JSONDecoder().decode(
      AppRecord.self,
      from: try JSONEncoder().encode(application)
    )

    XCTAssertEqual(decoded.alternateUpdateSource, .sparkle)
    XCTAssertEqual(decoded.alternateSourceURL, application.alternateSourceURL)
    XCTAssertEqual(decoded.alternateHomepageURL, application.alternateHomepageURL)
  }

  func testDecodesSnapshotWithoutLastInstalledAt() throws {
    var application = makeApplication(name: "Legacy")
    application.lastInstalledAt = Date(timeIntervalSince1970: 1)
    var payload = try JSONSerialization.jsonObject(
      with: try JSONEncoder().encode(application)
    ) as! [String: Any]
    payload.removeValue(forKey: "lastInstalledAt")
    let data = try JSONSerialization.data(withJSONObject: payload)

    let decoded = try JSONDecoder().decode(AppRecord.self, from: data)

    XCTAssertNil(decoded.lastInstalledAt)
  }

  func testDetectsNativeMacAppStoreReceipt() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "MacStore.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let receiptURL = contentsURL.appendingPathComponent("_MASReceipt/receipt")
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(
      at: receiptURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try writePropertyList(
      basicInfo(bundleIdentifier: "com.example.mac-store"),
      to: contentsURL.appendingPathComponent("Info.plist")
    )
    try Data().write(to: receiptURL)
    try setWhereFroms(
      ["https://github.com/example/mac-store/releases/download/1.0/MacStore.dmg"],
      at: applicationURL
    )

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))

    XCTAssertEqual(application.source, .appStore)
    XCTAssertEqual(application.appStorePlatform, .mac)
    XCTAssertEqual(application.sourceTitle, "Mac App Store")
    XCTAssertEqual(application.sourceSystemImage, "apple.logo")
    XCTAssertEqual(application.sourcePlatformSystemImage, "macwindow")
  }

  func testInstalledApplicationRecordDetectsNativeMacAppStoreReceipt() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "TestFlight.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let receiptURL = contentsURL.appendingPathComponent("_MASReceipt/receipt")
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(
      at: receiptURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try writePropertyList(
      basicInfo(bundleIdentifier: "com.apple.TestFlight"),
      to: contentsURL.appendingPathComponent("Info.plist")
    )
    try Data("receipt".utf8).write(to: receiptURL)

    let application = try XCTUnwrap(
      ApplicationScanner.makeInstalledApplicationRecord(from: applicationURL)
    )

    XCTAssertEqual(application.source, .appStore)
    XCTAssertEqual(application.appStorePlatform, .mac)
    XCTAssertEqual(application.status, .upToDate)
  }

  func testDoesNotReuseUnknownSourceWhenMacAppStoreReceiptExists() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "TestFlight.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let receiptURL = contentsURL.appendingPathComponent("_MASReceipt/receipt")
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(
      at: receiptURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try writePropertyList(
      basicInfo(bundleIdentifier: "com.apple.TestFlight"),
      to: contentsURL.appendingPathComponent("Info.plist")
    )
    try Data("receipt".utf8).write(to: receiptURL)

    var cached = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
    cached.source = .selfManaged
    cached.appStorePlatform = nil
    cached.status = .selfManaged

    let rescanned = try XCTUnwrap(
      ApplicationScanner.makeRecord(from: applicationURL, reusing: cached)
    )

    XCTAssertEqual(rescanned.source, .appStore)
    XCTAssertEqual(rescanned.appStorePlatform, .mac)
  }

  func testReadsAdamIdentifierFromInstalledMacAppStoreApplication() throws {
    let applicationURL = URL(fileURLWithPath: "/Applications/OpenCat.app")
    guard FileManager.default.fileExists(atPath: applicationURL.path) else {
      throw XCTSkip("OpenCat.app is not installed")
    }

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))

    XCTAssertEqual(application.source, .appStore)
    XCTAssertEqual(application.appStorePlatform, .mac)
    XCTAssertEqual(application.bundleIdentifier, "tech.baye.OpenCat")
    XCTAssertEqual(application.sourceIdentifier, "6445999201")
  }

  func testDetectsWrappedIPhoneAppStoreApplication() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "NoWords.app",
      isDirectory: true
    )
    let wrapperURL = applicationURL.appendingPathComponent("Wrapper", isDirectory: true)
    let wrappedApplicationURL = wrapperURL.appendingPathComponent(
      "LangEasyLexis.app",
      isDirectory: true
    )
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(
      at: wrappedApplicationURL,
      withIntermediateDirectories: true
    )
    try writePropertyList(
      basicInfo(
        bundleIdentifier: "cn.com.langeasy.LangEasyLexis",
        extraValues: [
          "CFBundleDisplayName": "不背单词",
          "CFBundleSupportedPlatforms": ["iPhoneOS"],
          "LSRequiresIPhoneOS": true,
          "UIDeviceFamily": [1, 2],
        ]
      ),
      to: wrappedApplicationURL.appendingPathComponent("Info.plist")
    )
    try writePropertyList(
      [
        "itemId": 698_570_469,
        "softwareVersionBundleId": "cn.com.langeasy.LangEasyLexis",
        "storefrontCountryCode": "cn",
      ],
      to: wrapperURL.appendingPathComponent("iTunesMetadata.plist")
    )
    try fileManager.createSymbolicLink(
      atPath: applicationURL.appendingPathComponent("WrappedBundle").path,
      withDestinationPath: "Wrapper/LangEasyLexis.app"
    )

    let infoURL = wrappedApplicationURL.appendingPathComponent("Info.plist")
    let completeInfo = try Data(contentsOf: infoURL)
    var incompleteInfo = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: completeInfo, format: nil) as? [String: Any]
    )
    incompleteInfo.removeValue(forKey: "CFBundleShortVersionString")
    incompleteInfo.removeValue(forKey: "CFBundleVersion")
    try writePropertyList(incompleteInfo, to: infoURL)
    let incomplete = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
    XCTAssertEqual(incomplete.currentVersion, "未知")

    try completeInfo.write(to: infoURL)
    let application = try XCTUnwrap(
      ApplicationScanner.makeRecord(from: applicationURL, reusing: incomplete)
    )

    XCTAssertEqual(application.source, .appStore)
    XCTAssertEqual(application.appStorePlatform, .iPhone)
    XCTAssertEqual(application.appStoreCountryCode, "cn")
    XCTAssertEqual(application.sourceIdentifier, "698570469")
    XCTAssertEqual(application.sourceTitle, "iPhone App Store")
    XCTAssertEqual(application.sourceSystemImage, "apple.logo")
    XCTAssertEqual(application.sourcePlatformSystemImage, "iphone")
    XCTAssertEqual(application.currentVersion, "1.0")
    XCTAssertEqual(application.buildVersion, "1")
    XCTAssertEqual(application.applicationURL, applicationURL)

    // App Store can finish or replace the inner bundle while Upkeep is running.
    // A rescan must read the plist on disk instead of Foundation's cached wrapper.
    try writePropertyList(
      basicInfo(
        bundleIdentifier: "cn.com.langeasy.LangEasyLexis",
        extraValues: [
          "CFBundleShortVersionString": "2.0",
          "CFBundleVersion": "2",
          "CFBundleSupportedPlatforms": ["iPhoneOS"],
          "UIDeviceFamily": [1, 2],
        ]
      ),
      to: wrappedApplicationURL.appendingPathComponent("Info.plist")
    )

    let updated = try XCTUnwrap(
      ApplicationScanner.makeRecord(from: applicationURL, reusing: application)
    )
    let installed = try XCTUnwrap(
      ApplicationScanner.makeInstalledApplicationRecord(from: applicationURL)
    )
    for record in [updated, installed] {
      XCTAssertEqual(record.currentVersion, "2.0")
      XCTAssertEqual(record.buildVersion, "2")
      XCTAssertEqual(record.applicationURL, applicationURL)
      XCTAssertEqual(record.appStorePlatform, .iPhone)
    }
  }

  func testDoesNotTreatGitHubDownloadMetadataAsAnUpdateSource() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "Downloaded.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    try writePropertyList(
      basicInfo(bundleIdentifier: "com.example.downloaded"),
      to: contentsURL.appendingPathComponent("Info.plist")
    )
    try setWhereFroms(
      [
        "https://objects.githubusercontent.com/release.zip",
        "https://github.com/example/downloaded/releases/tag/1.0",
      ],
      at: applicationURL
    )

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))

    XCTAssertEqual(application.source, .selfManaged)
    XCTAssertNil(application.sourceURL)
  }

  func testDetectsGitHubReleasesUpdaterInNativeExecutable() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent("tty7.app", isDirectory: true)
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
    try writePropertyList(
      basicInfo(bundleIdentifier: "com.github.tty7"),
      to: contentsURL.appendingPathComponent("Info.plist")
    )
    try Data(
      "gpui::app https://github.com/l0ng-ai/tty7/releases/latest".utf8
    ).write(to: macOSURL.appendingPathComponent("tty7"))

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))

    XCTAssertEqual(application.source, .githubReleases)
    XCTAssertEqual(application.sourceIdentifier, "l0ng-ai/tty7")
    XCTAssertEqual(
      application.sourceURL?.absoluteString,
      "https://api.github.com/repos/l0ng-ai/tty7/releases/latest"
    )
    XCTAssertEqual(application.homepageURL?.absoluteString, "https://github.com/l0ng-ai/tty7")
    XCTAssertEqual(application.sourceTitle, "GitHub Releases")
  }

  func testDoesNotTreatSpecificGitHubReleaseLinkAsLatestUpdater() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent("Notes.app", isDirectory: true)
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
    try writePropertyList(
      basicInfo(bundleIdentifier: "com.example.notes"),
      to: contentsURL.appendingPathComponent("Info.plist")
    )
    try Data(
      "Release notes: https://github.com/example/notes/releases/tag/v1.0.0".utf8
    ).write(to: macOSURL.appendingPathComponent("Notes"))

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
    XCTAssertEqual(application.source, .selfManaged)
  }

  func testDoesNotTreatDependencyGitHubRepositoryAsApplicationUpdater() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent("FlClash.app", isDirectory: true)
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
    try writePropertyList(
      basicInfo(bundleIdentifier: "com.follow.clash"),
      to: contentsURL.appendingPathComponent("Info.plist")
    )
    try Data(
      "Download core: https://github.com/MetaCubeX/mihomo/releases/latest".utf8
    ).write(to: macOSURL.appendingPathComponent("FlClash"))

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
    XCTAssertEqual(application.source, .selfManaged)
  }

  func testDetectsGitHubReleasesUpdaterInFlutterAppFramework() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent("FlClash.app", isDirectory: true)
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
    let appFrameworkExecutableURL = contentsURL
      .appendingPathComponent("Frameworks/App.framework/Versions/A", isDirectory: true)
      .appendingPathComponent("App")
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: appFrameworkExecutableURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try writePropertyList(
      basicInfo(
        bundleIdentifier: "com.follow.clash",
        extraValues: [
          "CFBundleDisplayName": "FlClash",
          "CFBundleName": "FlClash",
          "CFBundleExecutable": "FlClash",
        ]
      ),
      to: contentsURL.appendingPathComponent("Info.plist")
    )
    try Data(
      "Download core: https://github.com/MetaCubeX/mihomo/releases/latest".utf8
    ).write(to: macOSURL.appendingPathComponent("FlClash"))
    try Data(
      "App update: https://api.github.com/repos/chen08209/FlClash/releases/latest".utf8
    ).write(to: appFrameworkExecutableURL)

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))

    XCTAssertEqual(application.source, .githubReleases)
    XCTAssertEqual(application.sourceIdentifier, "chen08209/FlClash")
    XCTAssertEqual(
      application.sourceURL?.absoluteString,
      "https://api.github.com/repos/chen08209/FlClash/releases/latest"
    )
  }

  func testDetectsGitHubReleasesListUpdaterInFlutterAppFramework() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "ProxyPin.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
    let appFrameworkExecutableURL = contentsURL
      .appendingPathComponent("Frameworks/App.framework/Versions/A", isDirectory: true)
      .appendingPathComponent("App")
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: appFrameworkExecutableURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try writePropertyList(
      basicInfo(
        bundleIdentifier: "com.proxy.pin",
        extraValues: [
          "CFBundleDisplayName": "ProxyPin",
          "CFBundleName": "ProxyPin",
          "CFBundleExecutable": "ProxyPin",
        ]
      ),
      to: contentsURL.appendingPathComponent("Info.plist")
    )
    try Data("ProxyPin launcher".utf8).write(to: macOSURL.appendingPathComponent("ProxyPin"))
    try Data(
      "Updates: https://api.github.com/repos/wanghongenpin/proxypin/releases".utf8
    ).write(to: appFrameworkExecutableURL)

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))

    XCTAssertEqual(application.source, .githubReleases)
    XCTAssertEqual(application.sourceIdentifier, "wanghongenpin/proxypin")
    XCTAssertEqual(
      application.sourceURL?.absoluteString,
      "https://api.github.com/repos/wanghongenpin/proxypin/releases/latest"
    )
  }

  func testDetectsElectronBuilderGitHubProvider() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "CodePilot.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
    try writePropertyList(
      basicInfo(bundleIdentifier: "com.example.codepilot"),
      to: contentsURL.appendingPathComponent("Info.plist")
    )
    try Data(
      """
      owner: op7418
      repo: CodePilot
      provider: github
      """.utf8
    ).write(to: resourcesURL.appendingPathComponent("app-update.yml"))

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))

    XCTAssertEqual(application.source, .electronBuilder)
    XCTAssertEqual(application.sourceIdentifier, "op7418/CodePilot")
    XCTAssertEqual(
      application.sourceURL?.absoluteString,
      "https://github.com/op7418/CodePilot/releases/latest/download/latest-mac.yml"
    )
    XCTAssertEqual(application.homepageURL?.absoluteString, "https://github.com/op7418/CodePilot")
    XCTAssertEqual(application.sourceTitle, "electron-updater")
  }

  func testInstalledApplicationRecordSkipsUpdaterSourceDetection() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "CodePilot.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
    try writePropertyList(
      basicInfo(bundleIdentifier: "com.example.codepilot"),
      to: contentsURL.appendingPathComponent("Info.plist")
    )
    try Data(
      """
      owner: op7418
      repo: CodePilot
      provider: github
      """.utf8
    ).write(to: resourcesURL.appendingPathComponent("app-update.yml"))

    let installed = try XCTUnwrap(
      ApplicationScanner.makeInstalledApplicationRecord(from: applicationURL)
    )
    let fullyScanned = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))

    XCTAssertEqual(installed.source, .selfManaged)
    XCTAssertEqual(installed.status, .selfManaged)
    XCTAssertNil(installed.sourceURL)
    XCTAssertEqual(fullyScanned.source, .electronBuilder)
  }

  func testDetectsElectronBuilderGenericProvider() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "ChatWise.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
    try writePropertyList(
      basicInfo(bundleIdentifier: "app.chatwise"),
      to: contentsURL.appendingPathComponent("Info.plist")
    )
    try Data(
      """
      provider: generic
      url: https://releases.chatwise.app
      """.utf8
    ).write(to: resourcesURL.appendingPathComponent("app-update.yml"))

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))

    XCTAssertEqual(application.source, .electronBuilder)
    XCTAssertEqual(
      application.sourceURL?.absoluteString,
      "https://releases.chatwise.app/latest-mac.yml"
    )
  }

  func testDoesNotTreatCustomElectronProviderAsUpdateSource() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "CustomProvider.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
    try writePropertyList(
      basicInfo(bundleIdentifier: "com.example.custom-provider"),
      to: contentsURL.appendingPathComponent("Info.plist")
    )
    try Data(
      """
      owner: example
      repo: custom-provider
      provider: custom
      """.utf8
    ).write(to: resourcesURL.appendingPathComponent("app-update.yml"))

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))

    XCTAssertEqual(application.source, .selfManaged)
  }

  func testDoesNotTreatLocalhostElectronProviderAsUpdateSource() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "Localhost.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
    try writePropertyList(
      basicInfo(bundleIdentifier: "com.example.localhost"),
      to: contentsURL.appendingPathComponent("Info.plist")
    )
    try Data(
      """
      provider: generic
      url: http://localhost:3000
      """.utf8
    ).write(to: resourcesURL.appendingPathComponent("app-update.yml"))

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
    XCTAssertEqual(application.source, .selfManaged)
  }

  func testDetectsTauriUpdaterEndpointInExecutable() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "Grok.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
    try writePropertyList(
      basicInfo(bundleIdentifier: "com.example.grok"),
      to: contentsURL.appendingPathComponent("Info.plist")
    )
    try Data(
      """
      junkicon.icohttps://github.com/RongleCat/grok-app/releases/download/grok-desktop-latest/latest.jsontrailing
      """.utf8
    ).write(to: macOSURL.appendingPathComponent("Example"))

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))

    XCTAssertEqual(application.source, .tauri)
    XCTAssertEqual(
      application.sourceURL?.absoluteString,
      "https://github.com/RongleCat/grok-app/releases/download/grok-desktop-latest/latest.json"
    )
    XCTAssertEqual(application.sourceTitle, "Tauri updater")
  }

  func testDoesNotTreatGPUIAppAsTauriUpdater() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "Longbridge.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
    try writePropertyList(
      basicInfo(bundleIdentifier: "com.longbridge.app.desktop"),
      to: contentsURL.appendingPathComponent("Info.plist")
    )
    try Data(
      """
      gpui::app https://assets.lbkrs.com/github/release/longbridge-desktop/latest.json
      """.utf8
    ).write(to: macOSURL.appendingPathComponent("Example"))

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
    XCTAssertNotEqual(application.source, .tauri)
    XCTAssertEqual(application.source, .releaseJSON)
    XCTAssertEqual(
      application.sourceURL?.absoluteString,
      "https://assets.lbkrs.com/github/release/longbridge-desktop/latest.json"
    )
    XCTAssertEqual(application.sourceTitle, "JSON release")
  }

  func testDetectsReleaseJSONFromSplitLatestJSONURL() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "Longbridge.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
    try writePropertyList(
      basicInfo(bundleIdentifier: "com.longbridge.app.desktop"),
      to: contentsURL.appendingPathComponent("Info.plist")
    )
    var executable = Data("gpui::app ".utf8)
    executable.append(contentsOf: "https://assets.lbkrs.com/github/release/longbridge-desktop/".utf8)
    executable.append(contentsOf: [0xC0, 0x0C])
    executable.append(contentsOf: "/latest.json".utf8)
    try executable.write(to: macOSURL.appendingPathComponent("Example"))

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
    XCTAssertEqual(application.source, .releaseJSON)
    XCTAssertEqual(
      application.sourceURL?.absoluteString,
      "https://assets.lbkrs.com/github/release/longbridge-desktop/stable/latest.json"
    )
  }

  func testDetectsVSCodeUpdaterProductJSON() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "Code.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let appURL = contentsURL.appendingPathComponent("Resources/app", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: appURL, withIntermediateDirectories: true)
    try writePropertyList(
      basicInfo(
        bundleIdentifier: "com.microsoft.VSCode",
        extraValues: [
          "CFBundleShortVersionString": "1.134.0",
          "CFBundleVersion": "1.134.0",
        ]
      ),
      to: contentsURL.appendingPathComponent("Info.plist")
    )
    try Data(
      """
      {
        "quality": "stable",
        "commit": "110a328ea54b42367b803ec53ee0bf52ef26b419",
        "updateUrl": "https://update.code.visualstudio.com",
        "downloadUrl": "https://code.visualstudio.com"
      }
      """.utf8
    ).write(to: appURL.appendingPathComponent("product.json"))

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
    XCTAssertEqual(application.source, .vscodeUpdater)
    XCTAssertEqual(application.sourceTitle, "VS Code updater")
    XCTAssertEqual(
      application.sourceURL?.absoluteString,
      "https://update.code.visualstudio.com"
    )
    XCTAssertEqual(
      application.sourceIdentifier,
      "stable/110a328ea54b42367b803ec53ee0bf52ef26b419"
    )
    XCTAssertEqual(application.homepageURL?.absoluteString, "https://code.visualstudio.com")
    XCTAssertEqual(application.buildVersion, "110a328")
    let installed = try XCTUnwrap(ApplicationScanner.makeInstalledApplicationRecord(from: applicationURL))
    XCTAssertEqual(installed.source, .vscodeUpdater)
    XCTAssertEqual(installed.buildVersion, application.buildVersion)
    XCTAssertEqual(installed.sourceIdentifier, application.sourceIdentifier)

    // Reproduce a snapshot left by the old installed-only refresh: matching version/date,
    // but stale commit and a semantic version in the build field.
    var stale = application
    stale.buildVersion = application.currentVersion
    stale.sourceIdentifier = "stable/7debcd0e2acdea1c52de81bf9ee1620444407dda"
    let refreshed = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL, reusing: stale))
    XCTAssertEqual(refreshed.sourceIdentifier, application.sourceIdentifier)
    XCTAssertEqual(refreshed.buildVersion, application.buildVersion)

  }

  func testDoesNotTreatLocalhostVSCodeUpdateURLAsAnUpdateSource() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "LocalCode.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let appURL = contentsURL.appendingPathComponent("Resources/app", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: appURL, withIntermediateDirectories: true)
    try writePropertyList(
      basicInfo(bundleIdentifier: "com.example.localcode"),
      to: contentsURL.appendingPathComponent("Info.plist")
    )
    try Data(
      """
      {
        "commit": "abc",
        "updateUrl": "http://localhost:4000"
      }
      """.utf8
    ).write(to: appURL.appendingPathComponent("product.json"))

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
    XCTAssertEqual(application.source, .selfManaged)
  }

  func testPrefersElectronBuilderOverVSCodeProductJSON() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "Both.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
    let appURL = resourcesURL.appendingPathComponent("app", isDirectory: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: appURL, withIntermediateDirectories: true)
    try writePropertyList(
      basicInfo(bundleIdentifier: "com.example.both"),
      to: contentsURL.appendingPathComponent("Info.plist")
    )
    try Data(
      """
      provider: generic
      url: https://releases.example.com
      """.utf8
    ).write(to: resourcesURL.appendingPathComponent("app-update.yml"))
    try Data(
      """
      {
        "commit": "abc",
        "updateUrl": "https://update.example.com"
      }
      """.utf8
    ).write(to: appURL.appendingPathComponent("product.json"))

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
    XCTAssertEqual(application.source, .electronBuilder)
  }

  func testElectronNativeServiceDetectionAndOldSnapshotRecovery() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ServiceTest-\(UUID().uuidString)")
    let app = root.appendingPathComponent("Example.app")
    let contents = app.appendingPathComponent("Contents")
    defer { try? fm.removeItem(at: root) }
    for path in ["MacOS", "Resources/service", "Frameworks/Electron Framework.framework"] {
      try fm.createDirectory(at: contents.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    try writePropertyList(basicInfo(bundleIdentifier: "com.example.service"),
      to: contents.appendingPathComponent("Info.plist"))
    let launcher = contents.appendingPathComponent("MacOS/Example")
    try Data("https://runtime.example.com/latest.json".utf8).write(to: launcher)
    XCTAssertNil(ExecutableUpdaterDetector.detect(bundleURL: app).tauriEndpoint)
    let old = try XCTUnwrap(ApplicationScanner.makeRecord(from: app))
    let service = contents.appendingPathComponent("Resources/service/example-desktop")
    try Data("prefixhttps://updates.example.com/latest/latest.jsonsuffix".utf8).write(to: service)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: service.path)
    var cached = old
    let detected = try XCTUnwrap(ApplicationScanner.makeRecord(from: app, reusing: cached))
    XCTAssertEqual(detected.source, .tauri)
    XCTAssertEqual(detected.sourceURL?.absoluteString, "https://updates.example.com/latest/latest.json")
    // A legacy self-managed snapshot with exactly the current timestamp must be re-probed.
    cached = detected
    cached.source = .selfManaged
    cached.sourceURL = nil
    XCTAssertEqual(ApplicationScanner.makeRecord(from: app, reusing: cached)?.source, .tauri)
    try fm.removeItem(at: service)
    try fm.createSymbolicLink(at: service, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
    XCTAssertNil(ExecutableUpdaterDetector.detect(bundleURL: app).tauriEndpoint)
  }

  func testElectronHostDetectionIgnoresExampleVersionsAndEscapingSymlinks() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("HostTest-\(UUID().uuidString)")
    let app = root.appendingPathComponent("Example Studio.app")
    let contents = app.appendingPathComponent("Contents")
    defer { try? fm.removeItem(at: root) }
    for path in ["MacOS", "Resources/bin", "Frameworks/Electron Framework.framework"] {
      try fm.createDirectory(at: contents.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    var info = basicInfo(bundleIdentifier: "com.example.studio")
    info["CFBundleExecutable"] = "Example Studio"
    try writePropertyList(info, to: contents.appendingPathComponent("Info.plist"))
    try Data().write(to: contents.appendingPathComponent("MacOS/Example Studio"))
    let host = contents.appendingPathComponent("Resources/bin/example-studio-host")
    try Data("tauri_plugin_updater https://example.com/studio-vX.Y.Z/latest.json https://example.com/studio/versions.json".utf8).write(to: host)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.path)
    XCTAssertEqual(ExecutableUpdaterDetector.detect(bundleURL: app).tauriEndpoint?.absoluteString,
      "https://example.com/studio/versions.json")
    try fm.removeItem(at: host)
    try fm.createSymbolicLink(at: host, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
    XCTAssertNil(ExecutableUpdaterDetector.detect(bundleURL: app).tauriEndpoint)
  }

  func testDetectsInstalledReasonixUpdaterWhenPresent() throws {
    let applicationURL = URL(fileURLWithPath: "/Applications/Reasonix.app")
    guard FileManager.default.fileExists(atPath: applicationURL.path) else {
      throw XCTSkip("Reasonix.app is not installed on this machine")
    }

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
    XCTAssertEqual(application.source, .tauri)
    XCTAssertEqual(
      application.sourceURL?.absoluteString,
      "https://dl.reasonix.io/latest/latest.json"
    )
  }

  func testDetectsInstalledTTY7GitHubReleasesWhenPresent() throws {
    let applicationURL = URL(fileURLWithPath: "/Applications/tty7.app")
    guard FileManager.default.fileExists(atPath: applicationURL.path) else {
      throw XCTSkip("tty7.app is not installed on this machine")
    }

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
    XCTAssertEqual(application.source, .githubReleases)
    XCTAssertEqual(application.sourceIdentifier, "l0ng-ai/tty7")
    XCTAssertEqual(
      application.sourceURL?.absoluteString,
      "https://api.github.com/repos/l0ng-ai/tty7/releases/latest"
    )
  }

  func testDetectsInstalledFlClashGitHubReleasesWhenPresent() throws {
    let applicationURL = URL(fileURLWithPath: "/Applications/FlClash.app")
    guard FileManager.default.fileExists(atPath: applicationURL.path) else {
      throw XCTSkip("FlClash.app is not installed on this machine")
    }

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
    XCTAssertEqual(application.source, .githubReleases)
    XCTAssertEqual(application.sourceIdentifier, "chen08209/FlClash")
    XCTAssertEqual(
      application.sourceURL?.absoluteString,
      "https://api.github.com/repos/chen08209/FlClash/releases/latest"
    )
  }

  func testDetectsInstalledProxyPinGitHubReleasesWhenPresent() throws {
    let applicationURL = URL(fileURLWithPath: "/Applications/ProxyPin.app")
    guard FileManager.default.fileExists(atPath: applicationURL.path) else {
      throw XCTSkip("ProxyPin.app is not installed on this machine")
    }

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
    XCTAssertEqual(application.source, .githubReleases)
    XCTAssertEqual(application.sourceIdentifier, "wanghongenpin/proxypin")
    XCTAssertEqual(
      application.sourceURL?.absoluteString,
      "https://api.github.com/repos/wanghongenpin/proxypin/releases/latest"
    )
  }

  func testDetectsInstalledReasonixStudioUpdaterWhenPresent() throws {
    let applicationURL = URL(fileURLWithPath: "/Applications/ReasonixStudio.app")
    guard FileManager.default.fileExists(atPath: applicationURL.path) else {
      throw XCTSkip("ReasonixStudio.app is not installed on this machine")
    }

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
    XCTAssertEqual(application.source, .tauri)
    XCTAssertEqual(
      application.sourceURL?.absoluteString,
      "https://dl.reasonix.io/studio/versions.json"
    )
  }

  func testUsesNewestInnerFileModificationDate() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "Dated.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let infoURL = contentsURL.appendingPathComponent("Info.plist")
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    try writePropertyList(
      basicInfo(bundleIdentifier: "com.example.dated"),
      to: infoURL
    )

    let older = Date(timeIntervalSince1970: 1_777_000_000)
    let newer = Date(timeIntervalSince1970: 1_777_000_321)
    try fileManager.setAttributes([.modificationDate: older], ofItemAtPath: applicationURL.path)
    try fileManager.setAttributes([.modificationDate: older], ofItemAtPath: contentsURL.path)
    try fileManager.setAttributes([.modificationDate: newer], ofItemAtPath: infoURL.path)

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
    let recorded = try XCTUnwrap(application.applicationModificationDate)
    XCTAssertEqual(recorded.timeIntervalSince1970, newer.timeIntervalSince1970, accuracy: 1)
  }

  func testIgnoresOuterBundleModificationDateWhenInnerFilesAreOlder() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("UpkeepTests-\(UUID().uuidString)", isDirectory: true)
    let applicationURL = temporaryDirectory.appendingPathComponent(
      "Wrapper.app",
      isDirectory: true
    )
    let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
    let infoURL = contentsURL.appendingPathComponent("Info.plist")
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    try fileManager.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    try writePropertyList(
      basicInfo(bundleIdentifier: "com.example.wrapper"),
      to: infoURL
    )

    let inner = Date(timeIntervalSince1970: 1_777_000_000)
    let outer = Date(timeIntervalSince1970: 1_777_900_000)
    try fileManager.setAttributes([.modificationDate: inner], ofItemAtPath: contentsURL.path)
    try fileManager.setAttributes([.modificationDate: inner], ofItemAtPath: infoURL.path)
    try fileManager.setAttributes([.modificationDate: outer], ofItemAtPath: applicationURL.path)

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))
    let recorded = try XCTUnwrap(application.applicationModificationDate)
    XCTAssertEqual(recorded.timeIntervalSince1970, inner.timeIntervalSince1970, accuracy: 1)
  }

  private func makeApplication(
    name: String,
    modifiedAt: Date? = nil,
    status: UpdateStatus = .upToDate,
    releaseDate: Date? = nil
  ) -> AppRecord {
    AppRecord(
      name: name,
      bundleIdentifier: "com.example.\(name.lowercased())",
      applicationURL: URL(fileURLWithPath: "/Applications/\(name).app"),
      currentVersion: "1.0",
      applicationModificationDate: modifiedAt,
      status: status,
      latestVersion: status == .updateAvailable ? "2.0" : nil,
      releaseDate: releaseDate
    )
  }

  private func basicInfo(
    bundleIdentifier: String,
    extraValues: [String: Any] = [:]
  ) -> [String: Any] {
    var values: [String: Any] = [
      "CFBundleIdentifier": bundleIdentifier,
      "CFBundleDisplayName": "Example",
      "CFBundleName": "Example",
      "CFBundleShortVersionString": "1.0",
      "CFBundleVersion": "1",
      "CFBundleExecutable": "Example",
      "CFBundlePackageType": "APPL",
    ]
    values.merge(extraValues) { _, newValue in newValue }
    return values
  }

  private func writePropertyList(_ value: Any, to url: URL) throws {
    let data = try PropertyListSerialization.data(
      fromPropertyList: value,
      format: .xml,
      options: 0
    )
    try data.write(to: url)
  }

  private func setWhereFroms(_ values: [String], at url: URL) throws {
    let data = try PropertyListSerialization.data(
      fromPropertyList: values,
      format: .binary,
      options: 0
    )
    let result = data.withUnsafeBytes { bytes in
      url.path.withCString { path in
        "com.apple.metadata:kMDItemWhereFroms".withCString { attributeName in
          setxattr(path, attributeName, bytes.baseAddress, bytes.count, 0, 0)
        }
      }
    }
    guard result == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
  }
}
