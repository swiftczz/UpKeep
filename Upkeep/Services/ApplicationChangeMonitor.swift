import CoreServices
import Foundation

struct ApplicationChangeMonitor: Sendable {
  var changes: @Sendable () -> AsyncStream<Void>

  static func live(fileManager: FileManager = .default) -> ApplicationChangeMonitor {
    let paths = monitoredApplicationDirectories(fileManager: fileManager)
    return ApplicationChangeMonitor {
      guard !paths.isEmpty else {
        return AsyncStream { $0.finish() }
      }

      return AsyncStream { continuation in
        let watcher = ApplicationDirectoryWatcher(paths: paths) {
          continuation.yield(())
        }
        continuation.onTermination = { @Sendable _ in
          watcher.stop()
        }
        watcher.start()
      }
    }
  }

  static func monitoredApplicationDirectories(fileManager: FileManager = .default) -> [String] {
    [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Applications", isDirectory: true),
    ]
    .map { $0.standardizedFileURL.path }
    .filter { fileManager.fileExists(atPath: $0) }
  }

  static func affectsApplicationBundle(_ path: String) -> Bool {
    path.split(separator: "/").contains { component in
      component.lowercased().hasSuffix(".app")
    }
  }

  static func requiresApplicationRescan(path: String, flags: FSEventStreamEventFlags) -> Bool {
    if affectsApplicationBundle(path) {
      return true
    }

    let rescanFlags =
      FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
      | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
      | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
      | FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
    return flags & rescanFlags != 0
  }
}

private final class ApplicationDirectoryWatcher: @unchecked Sendable {
  private let paths: [String]
  private let onChange: @Sendable () -> Void
  private let queue = DispatchQueue(label: "upkeep.application-change-monitor")
  private let lock = NSLock()
  private var stream: FSEventStreamRef?

  init(paths: [String], onChange: @escaping @Sendable () -> Void) {
    self.paths = paths
    self.onChange = onChange
  }

  deinit {
    stop()
  }

  func start() {
    lock.lock()
    defer { lock.unlock() }

    guard stream == nil else { return }

    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )
    let flags =
      FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
      | FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
      | FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)

    guard
      let createdStream = FSEventStreamCreate(
        kCFAllocatorDefault,
        Self.handleEvents,
        &context,
        paths as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.75,
        flags
      )
    else {
      return
    }

    FSEventStreamSetDispatchQueue(createdStream, queue)
    FSEventStreamStart(createdStream)
    stream = createdStream
  }

  func stop() {
    lock.lock()
    let streamToStop = stream
    stream = nil
    lock.unlock()

    guard let streamToStop else { return }
    FSEventStreamStop(streamToStop)
    FSEventStreamInvalidate(streamToStop)
    FSEventStreamRelease(streamToStop)
  }

  private func handle(events: [(path: String, flags: FSEventStreamEventFlags)]) {
    guard
      events.contains(where: {
        ApplicationChangeMonitor.requiresApplicationRescan(path: $0.path, flags: $0.flags)
      })
    else {
      return
    }

    onChange()
  }

  private static let handleEvents: FSEventStreamCallback = {
    _,
    callbackInfo,
    eventCount,
    eventPathsPointer,
    eventFlagsPointer,
    _ in
    guard let callbackInfo else { return }
    let watcher = Unmanaged<ApplicationDirectoryWatcher>
      .fromOpaque(callbackInfo)
      .takeUnretainedValue()
    let eventPaths = unsafeBitCast(eventPathsPointer, to: CFArray.self) as NSArray
    var events: [(path: String, flags: FSEventStreamEventFlags)] = []
    events.reserveCapacity(eventCount)

    for index in 0..<eventCount {
      if let path = eventPaths[index] as? String {
        events.append((path: path, flags: eventFlagsPointer[index]))
      }
    }

    watcher.handle(events: events)
  }
}
