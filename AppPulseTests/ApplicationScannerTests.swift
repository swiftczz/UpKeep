import Darwin
import Foundation
import XCTest

@testable import AppPulse

final class ApplicationScannerTests: XCTestCase {
  func testUsesLocalizedNameWhenRawDisplayNameIsBlank() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("AppPulseTests-\(UUID().uuidString)", isDirectory: true)
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

  func testSortsNewestApplicationBundleFirst() {
    let older = makeApplication(name: "Older", modifiedAt: Date(timeIntervalSince1970: 100))
    let newer = makeApplication(name: "Newer", modifiedAt: Date(timeIntervalSince1970: 200))
    let unknown = makeApplication(name: "Unknown", modifiedAt: nil)

    let sorted = ApplicationScanner.sortedByModificationDate([older, unknown, newer])

    XCTAssertEqual(sorted.map(\.name), ["Newer", "Older", "Unknown"])
  }

  func testDetectsNativeMacAppStoreReceipt() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("AppPulseTests-\(UUID().uuidString)", isDirectory: true)
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

  func testDetectsWrappedIPhoneAppStoreApplication() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("AppPulseTests-\(UUID().uuidString)", isDirectory: true)
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

    let application = try XCTUnwrap(ApplicationScanner.makeRecord(from: applicationURL))

    XCTAssertEqual(application.source, .appStore)
    XCTAssertEqual(application.appStorePlatform, .iPhone)
    XCTAssertEqual(application.appStoreCountryCode, "cn")
    XCTAssertEqual(application.sourceIdentifier, "698570469")
    XCTAssertEqual(application.sourceTitle, "iPhone App Store")
    XCTAssertEqual(application.sourceSystemImage, "apple.logo")
    XCTAssertEqual(application.sourcePlatformSystemImage, "iphone")
  }

  func testDetectsGitHubDownloadForOtherwiseUnknownApplication() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("AppPulseTests-\(UUID().uuidString)", isDirectory: true)
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

    XCTAssertEqual(application.source, .github)
    XCTAssertEqual(application.sourceIdentifier, "example/downloaded")
    XCTAssertEqual(application.sourceURL?.absoluteString, "https://github.com/example/downloaded")
    XCTAssertEqual(application.sourceSystemImage, "chevron.left.forwardslash.chevron.right")
  }

  func testDetectsElectronGitHubProviderForOtherwiseUnknownApplication() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("AppPulseTests-\(UUID().uuidString)", isDirectory: true)
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

    XCTAssertEqual(application.source, .github)
    XCTAssertEqual(application.sourceIdentifier, "op7418/CodePilot")
    XCTAssertEqual(application.sourceURL?.absoluteString, "https://github.com/op7418/CodePilot")
  }

  func testDoesNotTreatCustomElectronProviderAsGitHub() throws {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
      .appendingPathComponent("AppPulseTests-\(UUID().uuidString)", isDirectory: true)
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

  private func makeApplication(name: String, modifiedAt: Date?) -> AppRecord {
    AppRecord(
      name: name,
      bundleIdentifier: "com.example.\(name.lowercased())",
      applicationURL: URL(fileURLWithPath: "/Applications/\(name).app"),
      currentVersion: "1.0",
      applicationModificationDate: modifiedAt,
      status: .upToDate
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
