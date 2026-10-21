import Observation

@MainActor
@Observable
final class ApplicationUpdateState {
    enum Outcome: Equatable {
        case succeeded(version: String)
        case failed(message: String)
    }

    private(set) var isUpdating = false
    private(set) var progress: UpdateProgress?
    /// Position on the overall bar. It only moves forward, so a retried download
    /// or a provider that repeats a stage never makes the bar jump back.
    private(set) var overallFraction: Double = 0
    /// The last finished attempt: success fades on its own, failure stays until retried.
    private(set) var outcome: Outcome?
    @ObservationIgnored private var outcomeExpiration: Task<Void, Never>?

    static let successDisplayDuration: Duration = .seconds(2.5)

    func begin() {
        clearOutcome()
        overallFraction = 0
        progress = .indeterminate("正在更新…")
        isUpdating = true
    }

    func report(_ progress: UpdateProgress) {
        guard isUpdating, self.progress != progress else { return }
        self.progress = progress
        let advanced = max(overallFraction, progress.overallFraction)
        if advanced != overallFraction { overallFraction = advanced }
    }

    func finish() {
        isUpdating = false
        progress = nil
    }

    func succeed(version: String) {
        finish()
        clearOutcome()
        outcome = .succeeded(version: version)
        outcomeExpiration = Task { [weak self] in
            try? await Task.sleep(for: Self.successDisplayDuration)
            guard !Task.isCancelled else { return }
            self?.clearOutcome()
        }
    }

    func fail(_ message: String) {
        finish()
        clearOutcome()
        outcome = .failed(message: message)
    }

    func clearOutcome() {
        outcomeExpiration?.cancel()
        outcomeExpiration = nil
        if outcome != nil { outcome = nil }
    }
}
