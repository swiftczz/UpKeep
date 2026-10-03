import Foundation
import XCTest
@testable import Upkeep

final class PrivilegedApplicationTrashTests: XCTestCase {
  private let application = URL(fileURLWithPath: "/Applications/Example.app")

  func testAuthenticatesOnlyAfterHelperIsReadyAndBeforeMoving() async throws {
    let events = TrashEvents()
    let handled = try await PrivilegedApplicationTrash.moveToTrash([application],
      prepare: { await events.append("ready"); return true },
      authenticate: { _ in await events.append("authenticate") },
      move: { _ in await events.append("move") })
    XCTAssertTrue(handled)
    let recorded = await events.values
    XCTAssertEqual(recorded, ["ready", "authenticate", "move"])
  }

  func testUnavailableHelperDoesNotShowFingerprintPrompt() async throws {
    let handled = try await PrivilegedApplicationTrash.moveToTrash([application],
      prepare: { false },
      authenticate: { _ in XCTFail("Must not authenticate without a usable helper") },
      move: { _ in XCTFail("Must not move without a usable helper") })
    XCTAssertFalse(handled)
  }

  func testHelperApprovalFailureDoesNotAuthenticateOrMove() async {
    do {
      _ = try await PrivilegedApplicationTrash.moveToTrash([application],
        prepare: { throw NSError(domain: "approval-required", code: 5) },
        authenticate: { _ in XCTFail("Helper must be approved first") },
        move: { _ in XCTFail("Helper must be approved first") })
      XCTFail("Expected approval error")
    } catch { XCTAssertEqual((error as NSError).domain, "approval-required") }
  }

  func testCancelledAuthenticationNeverMovesAnything() async {
    do {
      _ = try await PrivilegedApplicationTrash.moveToTrash([application],
        prepare: { true },
        authenticate: { _ in throw FinderTrashError.authorizationCancelled },
        move: { _ in XCTFail("Cancelled authentication must stop the operation") })
      XCTFail("Expected cancellation")
    } catch let error as FinderTrashError {
      guard case .authorizationCancelled = error else { return XCTFail("Unexpected error") }
    } catch { XCTFail("Unexpected error: \(error)") }
  }

  func testFailedAuthenticationNeverMovesAnything() async {
    do {
      _ = try await PrivilegedApplicationTrash.moveToTrash([application],
        prepare: { true },
        authenticate: { _ in throw NSError(domain: "authentication-failed", code: 1) },
        move: { _ in XCTFail("Failed authentication must stop the operation") })
      XCTFail("Expected authentication failure")
    } catch { XCTAssertEqual((error as NSError).domain, "authentication-failed") }
  }

  func testCancelledTaskNeverStartsAuthentication() async throws {
    let application = application
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await PrivilegedApplicationTrash.moveToTrash([application],
        prepare: { XCTFail("Cancelled task"); return true },
        authenticate: { _ in XCTFail("Cancelled task") },
        move: { _ in XCTFail("Cancelled task") })
    }
    do { _ = try await task.value; XCTFail("Expected cancellation") }
    catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
  }

  func testUnsupportedBatchDoesNotPreparePrivilegedHelper() async throws {
    for paths in [[], ["/Library/Caches/example"], ["/Applications/Nested/Example.app"],
      ["/Applications/Example.app", "/System/Applications/Safari.app"]] as [[String]] {
      let handled = try await PrivilegedApplicationTrash.moveToTrash(paths.map { URL(fileURLWithPath: $0) },
        prepare: { XCTFail("Unsupported batch must not reach helper"); return true },
        authenticate: { _ in XCTFail("Unsupported batch") },
        move: { _ in XCTFail("Unsupported batch") })
      XCTAssertFalse(handled)
    }
  }

  func testHelperHandlesApplicationAndFinderOnlyHandlesResidues() async throws {
    let residue = URL(fileURLWithPath: "/Library/Caches/example")
    let application = application
    try await FinderBatchTrash.recycleWithAuthorization([application, residue],
      privilegedRecycle: { XCTAssertEqual($0, [application]); return true },
      finderRecycle: { XCTAssertEqual($0, [residue]) })
  }

  func testNoFinderPromptAfterSuccessfulHelperMove() async throws {
    try await FinderBatchTrash.recycleWithAuthorization([application],
      privilegedRecycle: { _ in true },
      finderRecycle: { _ in XCTFail("Successful helper move must not prompt again") })
  }

  func testNoFinderRetryAfterAuthenticationOrHelperFailure() async {
    for error in [FinderTrashError.authorizationCancelled, .failed("helper failed")] {
      do {
        try await FinderBatchTrash.recycleWithAuthorization([application],
          privilegedRecycle: { _ in throw error },
          finderRecycle: { _ in XCTFail("Must not prompt again after entering helper flow") })
        XCTFail("Expected failure")
      } catch {}
    }
  }

  func testUnavailableHelperRetainsFinderFallback() async throws {
    let application = application
    try await FinderBatchTrash.recycleWithAuthorization([application],
      privilegedRecycle: { _ in false },
      finderRecycle: { XCTAssertEqual($0, [application]) })
  }

  func testResiduesNeverReachPrivilegedHelper() async throws {
    let residue = URL(fileURLWithPath: "/Library/Caches/example")
    try await FinderBatchTrash.recycleWithAuthorization([residue],
      privilegedRecycle: { _ in XCTFail("Residues must not reach root helper"); return true },
      finderRecycle: { XCTAssertEqual($0, [residue]) })
  }

  func testPreparesMissingTrashDirectoryWithPrivatePermissions() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try PrivilegedApplicationTrash.prepareTrashDirectory(homeDirectory: home)
    let attributes = try FileManager.default.attributesOfItem(
      atPath: home.appendingPathComponent(".Trash").path)
    XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeDirectory)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
  }

  func testReusesExistingTrashWithoutChangingContentsOrPermissions() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let trash = home.appendingPathComponent(".Trash", isDirectory: true)
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o750])
    let existingItem = trash.appendingPathComponent("Keep.txt")
    let content = Data("already in trash".utf8)
    try content.write(to: existingItem)
    let before = try FileManager.default.attributesOfItem(atPath: trash.path)

    try PrivilegedApplicationTrash.prepareTrashDirectory(homeDirectory: home)
    try PrivilegedApplicationTrash.prepareTrashDirectory(homeDirectory: home)

    let after = try FileManager.default.attributesOfItem(atPath: trash.path)
    XCTAssertEqual(after[.systemFileNumber] as? NSNumber, before[.systemFileNumber] as? NSNumber)
    XCTAssertEqual(after[.posixPermissions] as? NSNumber, before[.posixPermissions] as? NSNumber)
    XCTAssertEqual(try Data(contentsOf: existingItem), content)
  }

  func testDoesNotReplaceRegularFileAtTrashPath() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let trash = home.appendingPathComponent(".Trash")
    let content = Data("do not remove".utf8)
    try content.write(to: trash)
    XCTAssertThrowsError(try PrivilegedApplicationTrash.prepareTrashDirectory(homeDirectory: home))
    XCTAssertEqual(try Data(contentsOf: trash), content)
  }

  func testRejectsTrashSymlinkWithoutChangingItsTarget() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let target = home.appendingPathComponent("OtherDirectory")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let marker = target.appendingPathComponent("Keep.txt")
    try Data("keep".utf8).write(to: marker)
    let trash = home.appendingPathComponent(".Trash")
    try FileManager.default.createSymbolicLink(at: trash, withDestinationURL: target)

    XCTAssertThrowsError(try PrivilegedApplicationTrash.prepareTrashDirectory(homeDirectory: home))
    XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: trash.path), target.path)
  }

  func testDoesNotCreateMissingHomeDirectory() throws {
    let home = try makeTemporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let missing = home.appendingPathComponent("Missing")
    XCTAssertThrowsError(try PrivilegedApplicationTrash.prepareTrashDirectory(homeDirectory: missing))
    XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
  }

  private func makeTemporaryHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("Upkeep-Trash-Preparation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    return home
  }
}

private actor TrashEvents {
  var values: [String] = []
  func append(_ value: String) { values.append(value) }
}
