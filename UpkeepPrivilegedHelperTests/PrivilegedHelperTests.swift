import Foundation
import XCTest

@testable import UpkeepPrivilegedHelper

final class PrivilegedHelperTests: XCTestCase {
  func testFindsHostApplicationFromAbsoluteHelperPath() {
    let executableURL = URL(
      fileURLWithPath:
        "/Applications/Upkeep.app/Contents/MacOS/UpkeepPrivilegedHelper"
    )

    XCTAssertEqual(
      PrivilegedHelper.hostApplicationURL(from: executableURL)?.path,
      "/Applications/Upkeep.app"
    )
  }

  func testRejectsExecutableOutsideApplicationBundle() {
    XCTAssertNil(
      PrivilegedHelper.hostApplicationURL(
        from: URL(fileURLWithPath: "/usr/local/bin/UpkeepPrivilegedHelper")
      )
    )
  }

  func testRejectsInstallWhenHelperIsNotRoot() throws {
    let fixture = try InstallFixture()
    defer { fixture.remove() }

    let error = PrivilegedHelper.installAppStorePackage(
      packagePath: fixture.packageURL.path,
      receiptPath: fixture.receiptURL.path,
      applicationPath: fixture.applicationURL.path,
      isRoot: false,
      runCommand: { _, _ in XCTFail("Command must not run"); return nil }
    )

    XCTAssertEqual(error, "安装助手没有管理员权限。")
  }

  func testRejectsMissingOrInvalidInstallArtifacts() throws {
    let fixture = try InstallFixture()
    defer { fixture.remove() }

    let wrongPackageURL = fixture.rootURL.appendingPathComponent("update.zip")
    try Data().write(to: wrongPackageURL)
    XCTAssertEqual(
      fixture.install(packageURL: wrongPackageURL),
      "App Store 下载包格式不正确。"
    )

    try FileManager.default.removeItem(at: fixture.packageURL)
    XCTAssertEqual(fixture.install(), "找不到 App Store 下载包。")

    try Data().write(to: fixture.packageURL)
    let wrongReceiptURL = fixture.rootURL.appendingPathComponent("renamed-receipt")
    try Data().write(to: wrongReceiptURL)
    XCTAssertEqual(
      fixture.install(receiptURL: wrongReceiptURL),
      "找不到 App Store 收据文件。"
    )

    let invalidApplicationURL = fixture.rootURL.appendingPathComponent("Target")
    XCTAssertEqual(
      fixture.install(applicationURL: invalidApplicationURL),
      "应用路径不正确。"
    )
  }

  func testSuccessfulInstallRunsInstallerCopiesReceiptAndImportsMetadata() throws {
    let fixture = try InstallFixture(receiptContents: Data("receipt-data".utf8))
    defer { fixture.remove() }
    var commands: [(String, [String])] = []

    let error = fixture.install { launchPath, arguments in
      commands.append((launchPath, arguments))
      return nil
    }

    XCTAssertNil(error)
    XCTAssertEqual(commands.count, 2)
    XCTAssertEqual(commands[0].0, "/usr/sbin/installer")
    XCTAssertEqual(
      commands[0].1,
      ["-dumplog", "-pkg", fixture.packageURL.path, "-target", "/"]
    )
    XCTAssertEqual(commands[1].0, "/usr/bin/mdimport")
    XCTAssertEqual(commands[1].1, [fixture.applicationURL.path])

    let installedReceiptURL = fixture.applicationURL.appendingPathComponent(
      "Contents/_MASReceipt/receipt"
    )
    XCTAssertEqual(try Data(contentsOf: installedReceiptURL), Data("receipt-data".utf8))
    let permissions = try FileManager.default.attributesOfItem(atPath: installedReceiptURL.path)[
      .posixPermissions
    ] as? NSNumber
    XCTAssertEqual(permissions?.uint16Value, 0o644)
  }

  func testInstallerFailureStopsBeforeReceiptCopy() throws {
    let fixture = try InstallFixture()
    defer { fixture.remove() }
    var commandCount = 0

    let error = fixture.install { _, _ in
      commandCount += 1
      return "installer failed"
    }

    XCTAssertEqual(error, "installer failed")
    XCTAssertEqual(commandCount, 1)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: fixture.applicationURL.appendingPathComponent(
          "Contents/_MASReceipt/receipt"
        ).path
      )
    )
  }

  func testReceiptWriteFailureIsReported() throws {
    let fixture = try InstallFixture(applicationIsRegularFile: true)
    defer { fixture.remove() }

    let error = fixture.install { _, _ in nil }

    XCTAssertTrue(error?.contains("无法写入 App Store 收据") == true)
  }

  func testMetadataImportFailureIsReturned() throws {
    let fixture = try InstallFixture()
    defer { fixture.remove() }
    var commandCount = 0

    let error = fixture.install { _, _ in
      commandCount += 1
      return commandCount == 2 ? "metadata import failed" : nil
    }

    XCTAssertEqual(error, "metadata import failed")
    XCTAssertEqual(commandCount, 2)
  }

  func testCommandRunnerDrainsLargeOutputWithoutDeadlocking() {
    let error = PrivilegedHelper.run(
      "/bin/sh",
      arguments: ["-c", "yes output | head -c 200000"]
    )

    XCTAssertNil(error)
  }

  func testCommandRunnerReturnsProcessErrorOutput() {
    let error = PrivilegedHelper.run(
      "/bin/sh",
      arguments: ["-c", "echo helper-failed >&2; exit 7"]
    )

    XCTAssertEqual(error, "helper-failed")
  }

  func testCommandRunnerReportsLaunchFailure() {
    let error = PrivilegedHelper.run(
      "/path/that/does/not/exist",
      arguments: []
    )

    XCTAssertTrue(error?.contains("无法启动") == true)
  }
}

private final class InstallFixture {
  let rootURL: URL
  let packageURL: URL
  let receiptURL: URL
  let applicationURL: URL

  init(
    receiptContents: Data = Data("receipt".utf8),
    applicationIsRegularFile: Bool = false
  ) throws {
    rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    packageURL = rootURL.appendingPathComponent("update.pkg")
    receiptURL = rootURL.appendingPathComponent("receipt")
    applicationURL = rootURL.appendingPathComponent("Target.app", isDirectory: true)

    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try Data("package".utf8).write(to: packageURL)
    try receiptContents.write(to: receiptURL)
    if applicationIsRegularFile {
      try Data().write(to: applicationURL)
    } else {
      try FileManager.default.createDirectory(
        at: applicationURL,
        withIntermediateDirectories: true
      )
    }
  }

  func install(
    packageURL: URL? = nil,
    receiptURL: URL? = nil,
    applicationURL: URL? = nil,
    runCommand: (_ launchPath: String, _ arguments: [String]) -> String? = { _, _ in nil }
  ) -> String? {
    PrivilegedHelper.installAppStorePackage(
      packagePath: (packageURL ?? self.packageURL).path,
      receiptPath: (receiptURL ?? self.receiptURL).path,
      applicationPath: (applicationURL ?? self.applicationURL).path,
      isRoot: true,
      runCommand: runCommand
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
