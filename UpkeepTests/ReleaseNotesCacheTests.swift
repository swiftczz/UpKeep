import Foundation
import Synchronization
import XCTest

@testable import Upkeep

@MainActor
final class ReleaseNotesCacheTests: XCTestCase {
  func testParsesOffMainThreadAndReusesConcurrentRequests() async throws {
    let calls = Mutex((count: 0, usedMainThread: false))
    let cache = ReleaseNotesCache { request in
      calls.withLock {
        $0.count += 1
        $0.usedMainThread = Thread.isMainThread
      }
      return ReleaseNotesMarkdown.Document(blocks: ReleaseNotesMarkdown.parse(request.source))
    }
    let request = ReleaseNotesCache.Request(source: "# Notes\n\nA change", baseURL: nil)
    async let first = cache.document(for: request)
    async let second = cache.document(for: request)
    let documents = try await (first, second)
    XCTAssertEqual(documents.0, documents.1)
    XCTAssertEqual(calls.withLock { $0.count }, 1)
    XCTAssertFalse(calls.withLock { $0.usedMainThread })
  }

  func testCacheKeyIncludesBaseURLAndSource() async throws {
    let cache = ReleaseNotesCache()
    let first = try await cache.document(for: .init(
      source: "[Notes](changes)", baseURL: URL(string: "https://example.com/one/")
    ))
    let second = try await cache.document(for: .init(
      source: "[Notes](changes)", baseURL: URL(string: "https://example.com/two/")
    ))
    guard case .paragraph(let firstBlock) = first.sections[0].content,
      case .paragraph(let secondBlock) = second.sections[0].content
    else { return XCTFail("Expected link paragraphs") }
    XCTAssertEqual(firstBlock.text.link?.absoluteString, "https://example.com/one/changes")
    XCTAssertEqual(secondBlock.text.link?.absoluteString, "https://example.com/two/changes")

    let changed = try await cache.document(for: .init(source: "New notes", baseURL: nil))
    XCTAssertNotEqual(first, changed)
  }

  func testEvictsLeastRecentlyUsedDocument() async throws {
    let sources = Mutex<[String]>([])
    let cache = ReleaseNotesCache(capacity: 2) { request in
      sources.withLock { $0.append(request.source) }
      return ReleaseNotesMarkdown.Document(blocks: ReleaseNotesMarkdown.parse(request.source))
    }
    for source in ["A", "B", "A", "C", "B"] {
      _ = try await cache.document(for: .init(source: source, baseURL: nil))
    }
    XCTAssertEqual(sources.withLock { $0 }, ["A", "B", "C", "B"])
  }

  func testOversizedDocumentsDoNotDisplaceCachedNotes() async throws {
    let sources = Mutex<[String]>([])
    let cache = ReleaseNotesCache(blockLimit: 1) { request in
      sources.withLock { $0.append(request.source) }
      return ReleaseNotesMarkdown.Document(blocks: ReleaseNotesMarkdown.parse(request.source))
    }
    for source in ["Small", "First\n\nSecond", "Small", "First\n\nSecond"] {
      _ = try await cache.document(for: .init(source: source, baseURL: nil))
    }
    XCTAssertEqual(sources.withLock { $0 }, ["Small", "First\n\nSecond", "First\n\nSecond"])
  }

  func testCancellationDuringParsingDoesNotPublishOrCacheResult() async throws {
    let started = expectation(description: "Background parse started")
    let gate = DispatchSemaphore(value: 0)
    let calls = Mutex(0)
    let cache = ReleaseNotesCache { request in
      let isFirst = calls.withLock { $0 += 1; return $0 == 1 }
      if isFirst {
        started.fulfill()
        _ = gate.wait(timeout: .now() + 5)
      }
      return ReleaseNotesMarkdown.Document(blocks: ReleaseNotesMarkdown.parse(request.source))
    }
    let request = ReleaseNotesCache.Request(source: "Old selection", baseURL: nil)
    let task = Task { try await cache.document(for: request) }
    await fulfillment(of: [started], timeout: 5)
    task.cancel()
    gate.signal()
    do {
      _ = try await task.value
      XCTFail("A cancelled selection must not receive a document")
    } catch is CancellationError {} catch {
      XCTFail("Unexpected error: \(error)")
    }
    _ = try await cache.document(for: request)
    XCTAssertEqual(calls.withLock { $0 }, 2)
  }
}
