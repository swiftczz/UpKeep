import SwiftUI

/// Only this leaf observes percentage changes; the detail layout observes start/end.
struct AppUpdateProgressView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: ApplicationUpdateState
    private var updateProgress: UpdateProgress? { state.progress }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let fraction = updateProgress?.fractionCompleted {
                SmoothProgressView(fraction: fraction)
                    .tint(.blue)
                    .frame(width: 168)
                    .animation(reduceMotion ? nil : .linear(duration: 0.25), value: fraction)
                Text(progressCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: fraction))
                    .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: progressCaption)
            } else {
                ProgressView(updateProgress?.status ?? "正在更新…")
                    .controlSize(.small)
            }
        }
        .frame(minWidth: 168, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progressAccessibilityLabel)
    }

    private var progressCaption: String {
        let status = updateProgress?.status ?? "正在更新…"
        if let percentText = updateProgress?.percentText {
            return "\(status) \(percentText)"
        }
        return status
    }

    private var progressAccessibilityLabel: String {
        if let percentText = updateProgress?.percentText {
            return "\(updateProgress?.status ?? "正在更新")，\(percentText)"
        }
        return updateProgress?.status ?? "正在更新"
    }
}

/// Interpolates determinate progress so bursty reports read as continuous motion.
struct SmoothProgressView: View, Animatable {
    var fraction: Double
    var isCircular = false

    nonisolated var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    var body: some View {
        if isCircular {
            ProgressView(value: fraction).progressViewStyle(.circular)
        } else {
            ProgressView(value: fraction).progressViewStyle(.linear)
        }
    }
}
