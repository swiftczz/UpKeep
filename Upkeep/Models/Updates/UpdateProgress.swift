import Foundation

struct UpdateProgress: Hashable, Sendable {
    /// Where an update is in its pipeline. Each stage owns a fixed share of one
    /// overall bar, so progress keeps moving forward across stages.
    enum Stage: Int, Hashable, Sendable, CaseIterable, Comparable {
        case preparing
        case downloading
        case verifying
        case installing
        case finishing

        /// Providers report readable status text; this maps it to a stage in one
        /// place instead of every provider tagging its reports.
        init(status: String) {
            func has(_ keywords: String...) -> Bool { keywords.contains { status.contains($0) } }
            if has("等待安装") {
                self = .installing
            } else if has("下载", "重试") {
                self = .downloading
            } else if has("校验", "验证") {
                self = .verifying
            } else if has("解压", "安装", "处理更新", "授权") {
                self = .installing
            } else if has("完成", "重新打开") {
                self = .finishing
            } else {
                self = .preparing
            }
        }

        /// The stage's share of the overall bar. Downloads dominate an update's time.
        var span: ClosedRange<Double> {
            switch self {
            case .preparing: 0...0.04
            case .downloading: 0.04...0.8
            case .verifying: 0.8...0.86
            case .installing: 0.86...0.97
            case .finishing: 0.97...1
            }
        }

        static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var fractionCompleted: Double?
    var status: String
    var stage: Stage
    var completedBytes: Int64?
    var totalBytes: Int64?

    init(
        fractionCompleted: Double?,
        status: String,
        stage: Stage? = nil,
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil
    ) {
        self.fractionCompleted = fractionCompleted
        self.status = status
        self.stage = stage ?? Stage(status: status)
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    static func indeterminate(_ status: String) -> UpdateProgress {
        UpdateProgress(fractionCompleted: nil, status: status)
    }

    /// Position on the single bar across all stages. A stage without a measurable
    /// fraction sits at its start.
    var overallFraction: Double {
        let span = stage.span
        let fraction = fractionCompleted.map { min(max($0, 0), 1) } ?? 0
        return span.lowerBound + (span.upperBound - span.lowerBound) * fraction
    }

    var percentText: String? {
        guard let fractionCompleted else { return nil }
        return "\(Int((min(max(fractionCompleted, 0), 1) * 100).rounded()))%"
    }

    static func clamp(_ value: Double) -> Double {
        let normalized = value > 1.0001 ? value / 100 : value
        return min(max(normalized, 0), 1)
    }
}

/// Download speed from progress reports, smoothed so the estimate does not jitter.
struct TransferRateEstimator: Equatable, Sendable {
    private var lastBytes: Int64?
    private var lastTime: TimeInterval?
    private(set) var bytesPerSecond: Double?
    private var samples = 0

    /// Samples closer together than this are folded into the next one.
    static let minimumInterval: TimeInterval = 0.25

    mutating func record(bytes: Int64, at time: TimeInterval) {
        guard let lastBytes, let lastTime else {
            self.lastBytes = bytes
            self.lastTime = time
            return
        }
        let elapsed = time - lastTime
        guard elapsed >= Self.minimumInterval else { return }
        guard bytes >= lastBytes else {
            // A retried download starts over; so does the estimate.
            self = TransferRateEstimator()
            record(bytes: bytes, at: time)
            return
        }
        let rate = Double(bytes - lastBytes) / elapsed
        bytesPerSecond = bytesPerSecond.map { $0 * 0.7 + rate * 0.3 } ?? rate
        samples += 1
        self.lastBytes = bytes
        self.lastTime = time
    }

    /// Nil until a few samples agree on a speed.
    func remainingSeconds(completed: Int64, total: Int64) -> TimeInterval? {
        guard samples >= 3, let bytesPerSecond, bytesPerSecond > 1, total > completed else {
            return nil
        }
        return Double(total - completed) / bytesPerSecond
    }
}
