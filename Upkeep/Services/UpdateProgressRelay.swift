import Foundation
import Synchronization

/// The first value, phase changes and completion bypass the rate limit. Between
/// them, retain only the latest value and deliver it on the next deadline.
struct UpdateProgressThrottle {
  let interval: Duration
  private(set) var lastPublished: UpdateProgress?
  private var lastPublishedAt: ContinuousClock.Instant?
  private var pending: UpdateProgress?

  init(interval: Duration = .milliseconds(100)) {
    self.interval = interval
  }

  var deadline: ContinuousClock.Instant? {
    pending == nil ? nil : lastPublishedAt?.advanced(by: interval)
  }

  mutating func receive(_ progress: UpdateProgress, at now: ContinuousClock.Instant) -> UpdateProgress? {
    guard progress != lastPublished else {
      pending = nil
      return nil
    }
    let changesPhase = progress.status != lastPublished?.status
      || (progress.fractionCompleted == nil) != (lastPublished?.fractionCompleted == nil)
    let completes = (progress.fractionCompleted ?? 0) >= 1
    if changesPhase || completes || lastPublishedAt.map({ now >= $0.advanced(by: interval) }) != false {
      return publish(progress, at: now)
    }
    pending = progress
    return nil
  }

  mutating func flush(at now: ContinuousClock.Instant) -> UpdateProgress? {
    guard let pending else { return nil }
    return publish(pending, at: now)
  }

  private mutating func publish(_ progress: UpdateProgress, at now: ContinuousClock.Instant) -> UpdateProgress {
    pending = nil
    lastPublished = progress
    lastPublishedAt = now
    return progress
  }
}

/// Coalesce callbacks before they reach the main actor. A single trailing timer
/// and a one-element stream prevent a fast download from building a UI backlog.
final class UpdateProgressRelay: Sendable {
  let stream: AsyncStream<UpdateProgress>
  private let continuation: AsyncStream<UpdateProgress>.Continuation
  private let state = Mutex(State())

  private struct State {
    var throttle = UpdateProgressThrottle()
    var timer: Task<Void, Never>?
    var generation = 0
    var finished = false
  }

  init() {
    (stream, continuation) = AsyncStream.makeStream(
      of: UpdateProgress.self, bufferingPolicy: .bufferingNewest(1)
    )
  }

  func submit(_ progress: UpdateProgress) {
    state.withLock { state in
      guard !state.finished else { return }
      if let value = state.throttle.receive(progress, at: .now) {
        cancelTimer(&state)
        continuation.yield(value)
      } else if let deadline = state.throttle.deadline {
        guard state.timer == nil else { return }
        let generation = state.generation
        state.timer = Task.detached(priority: .utility) { [self] in
          do {
            try await Task.sleep(until: deadline, clock: .continuous)
            flush(generation: generation)
          } catch {}
        }
      } else {
        cancelTimer(&state)
      }
    }
  }

  func finish() {
    state.withLock { state in
      guard !state.finished else { return }
      state.finished = true
      cancelTimer(&state)
      if let value = state.throttle.flush(at: .now) { continuation.yield(value) }
      continuation.finish()
    }
  }

  private func flush(generation: Int) {
    state.withLock { state in
      guard !state.finished, state.generation == generation else { return }
      state.timer = nil
      if let value = state.throttle.flush(at: .now) { continuation.yield(value) }
    }
  }

  private func cancelTimer(_ state: inout State) {
    state.generation += 1
    state.timer?.cancel()
    state.timer = nil
  }
}
