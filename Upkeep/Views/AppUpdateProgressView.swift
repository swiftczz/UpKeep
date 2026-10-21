import SwiftUI

/// The update action while it runs: one bar across every stage, shown directly in
/// the header without a container.
/// Only this leaf observes percentage changes; the detail layout observes start/end.
struct AppUpdateProgressView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: ApplicationUpdateState
    @State private var transfer = TransferRateEstimator()

    private var progress: UpdateProgress { state.progress ?? .indeterminate("正在更新…") }
    private var fraction: Double { state.overallFraction }
    /// Finishing turns the bar green just before the result badge replaces it.
    private var tint: Color { progress.stage == .finishing ? .green : .blue }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The stage icon sits beside the percentage, so the status, bar and caption
            // keep one shared left edge.
            HStack(spacing: 5) {
                Text(progress.status)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Spacer(minLength: 8)
                Image(systemName: progress.stage.systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                // Numbers change in place: progress reports arrive many times a second,
                // and rolling digits would never settle long enough to read.
                Text(percentText)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .transaction { $0.animation = nil }
            }

            UpdateProgressBar(
                fraction: fraction,
                isWaiting: progress.fractionCompleted == nil,
                tint: tint,
                isAnimated: !reduceMotion
            )
            .frame(height: 6)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .transaction { $0.animation = nil }
        }
        // Takes the free space beside the app's name and follows the window as it
        // narrows; capped so very wide windows do not stretch it out of proportion.
        .frame(minWidth: 140, idealWidth: 520, maxWidth: 520)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: progress.stage)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: fraction)
        .onChange(of: progress.completedBytes) { _, bytes in
            if let bytes { transfer.record(bytes: bytes, at: Date().timeIntervalSinceReferenceDate) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(progress.status) \(detail)")
        .accessibilityValue(percentText)
    }

    /// Rounded down, so 100% only appears once the update is complete.
    private var percentText: String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%"
    }

    private var detail: String {
        guard progress.stage == .downloading, let completed = progress.completedBytes,
            let total = progress.totalBytes, total > 0
        else { return progress.stage.hint }
        let sizes =
            "\(completed.formatted(.byteCount(style: .file))) / \(total.formatted(.byteCount(style: .file)))"
        guard let remaining = transfer.remainingSeconds(completed: completed, total: total) else {
            return sizes
        }
        return "\(sizes) · \(Self.remainingText(remaining))"
    }

    static func remainingText(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return "剩余几秒" }
        if seconds < 60 { return "剩余约 \(Int((seconds / 5).rounded()) * 5) 秒" }
        return "剩余约 \(max(1, Int((seconds / 60).rounded()))) 分钟"
    }
}

extension UpdateProgress.Stage {
    var systemImage: String {
        switch self {
        case .preparing: "hourglass"
        case .downloading: "arrow.down"
        case .verifying: "checkmark.shield"
        case .installing: "shippingbox"
        case .finishing: "sparkles"
        }
    }

    /// What the stage is doing, for when there is no number to show.
    var hint: String {
        switch self {
        case .preparing: "连接更新源"
        case .downloading: "从更新源获取安装包"
        case .verifying: "核对校验值与开发者签名"
        case .installing: "安装新版本"
        case .finishing: "刷新应用信息"
        }
    }
}

/// A capsule bar: a gradient fill with a slow sheen while progress is measurable,
/// and a soft band moving through the remaining track while a stage cannot be measured.
struct UpdateProgressBar: View {
    var fraction: Double
    var isWaiting: Bool
    var tint: Color
    var isAnimated: Bool

    private static let sheenPeriod: TimeInterval = 2.2
    private static let waitingPeriod: TimeInterval = 1.4

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let filled = fraction > 0 ? max(width * min(fraction, 1), height) : 0

            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)

                if isWaiting, isAnimated, width - filled > height * 4 {
                    TimelineView(.animation) { context in
                        let band = max(height * 4, (width - filled) * 0.35)
                        let phase = Self.phase(of: context.date, period: Self.waitingPeriod)
                        // Ease in and out so the band settles at each end of the track.
                        let eased = (1 - cos(phase * .pi * 2)) / 2
                        Capsule()
                            .fill(tint.opacity(0.3))
                            .frame(width: band)
                            .offset(x: filled + (width - filled - band) * eased)
                    }
                }

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.7), tint],
                            startPoint: .leading, endPoint: .trailing)
                    )
                    .overlay(alignment: .leading) {
                        if isAnimated, filled > height * 3 {
                            TimelineView(.animation) { context in
                                let sheen = height * 6
                                let phase = Self.phase(of: context.date, period: Self.sheenPeriod)
                                LinearGradient(
                                    colors: [.white.opacity(0), .white.opacity(0.45), .white.opacity(0)],
                                    startPoint: .leading, endPoint: .trailing
                                )
                                .frame(width: sheen)
                                .offset(x: -sheen + (filled + sheen * 2) * phase)
                            }
                        }
                    }
                    .clipShape(Capsule())
                    .frame(width: filled)
                    .shadow(color: tint.opacity(0.35), radius: 3)
            }
        }
        .accessibilityHidden(true)
    }

    private static func phase(of date: Date, period: TimeInterval) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
    }
}

/// A thin ring for compact places: the measured fraction as an arc, plus a short
/// rotating comet while the current work cannot be measured.
struct ProgressRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Increased on a selected list row, whose accent background would hide a tinted ring.
    @Environment(\.backgroundProminence) private var backgroundProminence
    /// Nil when nothing is measurable yet.
    var fraction: Double?
    /// Shows the comet even when part of the ring is already filled.
    var isWorking = false
    var lineWidth: CGFloat = 2
    var tint: Color = .blue

    private static let period: TimeInterval = 1.1

    private var isProminent: Bool { backgroundProminence == .increased }
    private var resolvedTint: Color { isProminent ? .white : tint }
    private var trackStyle: AnyShapeStyle {
        isProminent ? AnyShapeStyle(.white.opacity(0.3)) : AnyShapeStyle(.quaternary)
    }

    var body: some View {
        ZStack {
            Circle().stroke(trackStyle, lineWidth: lineWidth)

            if let fraction, fraction > 0 {
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0.03), 1))
                    .stroke(resolvedTint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }

            if fraction == nil || isWorking {
                if reduceMotion {
                    if fraction == nil { comet(at: 0) }
                } else {
                    TimelineView(.animation) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: Self.period) / Self.period
                        comet(at: phase * 360)
                    }
                }
            }
        }
        .padding(lineWidth / 2)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: fraction)
        // Callers describe what the ring stands for.
        .accessibilityElement(children: .ignore)
    }

    private func comet(at angle: Double) -> some View {
        Circle()
            .trim(from: 0, to: 0.24)
            .stroke(
                AngularGradient(
                    colors: [resolvedTint.opacity(0), resolvedTint], center: .center,
                    startAngle: .degrees(0), endAngle: .degrees(86)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .rotationEffect(.degrees(angle - 90))
    }
}
