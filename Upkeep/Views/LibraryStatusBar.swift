import SwiftUI

/// The sidebar footer for background work that otherwise has no visible progress.
struct LibraryStatusBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let phase: LibraryPhase
    let checkedCount: Int
    let checkTotalCount: Int
    let updateAllProgress: UpdateAllProgress?
    let lastCheckedAt: Date?

    var body: some View {
        Group {
            if let activity {
                row(text: activity.text) {
                    if let fraction = activity.fraction {
                        SmoothProgressView(fraction: fraction, isCircular: true)
                            .animation(
                                reduceMotion ? nil : .linear(duration: 0.25), value: fraction)
                    } else {
                        ProgressView()
                    }
                }
                .controlSize(.mini)
            } else if let lastCheckedAt {
                TimelineView(.everyMinute) { context in
                    row(text: "上次检查：\(Self.relativeText(for: lastCheckedAt, now: context.date))") {
                        Image(systemName: "checkmark.circle")
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: activity)
    }

    private struct Activity: Equatable {
        let fraction: Double?
        let text: String
    }

    private var activity: Activity? {
        if let updateAllProgress {
            let total = max(updateAllProgress.totalCount, 1)
            let position = min(updateAllProgress.completedCount + 1, total)
            var text = "正在更新 \(position)/\(total)"
            if let name = updateAllProgress.currentApplicationName {
                text += " · \(name)"
            }
            return Activity(
                fraction: Double(updateAllProgress.completedCount) / Double(total), text: text)
        }
        switch phase {
        case .scanning:
            return Activity(fraction: nil, text: "正在扫描应用…")
        case .checking where checkTotalCount > 0:
            return Activity(
                fraction: Double(checkedCount) / Double(checkTotalCount),
                text: "正在检查更新 \(checkedCount)/\(checkTotalCount)"
            )
        case .checking:
            return Activity(fraction: nil, text: "正在检查更新…")
        case .idle:
            return nil
        }
    }

    private func row(
        text: String, @ViewBuilder indicator: () -> some View
    ) -> some View {
        HStack(spacing: 8) {
            indicator()
                .frame(width: 14, height: 14)

            Text(text)
                .contentTransition(.numericText())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private static func relativeText(for date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "刚刚" }
        return date.formatted(.relative(presentation: .named))
    }
}
