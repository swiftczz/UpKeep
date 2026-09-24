import Foundation

/// Serial parsing runs on this actor, never on the UI actor. Completed documents
/// are reused across selections; cancelled selections cannot publish stale work.
actor ReleaseNotesCache {
  struct Request: Hashable, Sendable {
    let source: String
    let baseURL: URL?
  }

  static let shared = ReleaseNotesCache()

  private struct Entry {
    let request: Request
    let document: ReleaseNotesMarkdown.Document
  }

  private let capacity: Int
  private let blockLimit: Int
  private let parse: @Sendable (Request) -> ReleaseNotesMarkdown.Document
  private var entries: [Entry] = []
  private var cachedBlockCount = 0

  init(
    capacity: Int = 12,
    blockLimit: Int = 12_000,
    parse: @escaping @Sendable (Request) -> ReleaseNotesMarkdown.Document = { request in
      ReleaseNotesMarkdown.Document(
        blocks: ReleaseNotesMarkdown.parse(request.source, baseURL: request.baseURL)
      )
    }
  ) {
    self.capacity = max(capacity, 0)
    self.blockLimit = max(blockLimit, 0)
    self.parse = parse
  }

  func document(for request: Request) throws -> ReleaseNotesMarkdown.Document {
    try Task.checkCancellation()
    if let index = entries.firstIndex(where: { $0.request == request }) {
      let entry = entries.remove(at: index)
      entries.append(entry)
      return entry.document
    }

    let document = parse(request)
    try Task.checkCancellation()
    guard capacity > 0, document.blockCount <= blockLimit else { return document }
    while !entries.isEmpty,
      entries.count >= capacity || cachedBlockCount + document.blockCount > blockLimit
    {
      cachedBlockCount -= entries.removeFirst().document.blockCount
    }
    entries.append(Entry(request: request, document: document))
    cachedBlockCount += document.blockCount
    return document
  }
}
