import SwiftUI

struct AppRowView: View {
    let application: AppRecord
    let isUpdateIgnored: Bool
    var isChecking = false
    var updateState: ApplicationUpdateState? = nil

    private var listDate: Date? {
        application.sidebarDate(isUpdateIgnored: isUpdateIgnored)
    }

    var body: some View {
        HStack(spacing: 11) {
            AppIconView(applicationURL: application.applicationURL, size: 42)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(application.name)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if let listDate {
                        Text(listDate.slashDateText)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .layoutPriority(1)
                            .help(dateHelp(for: listDate))
                            .accessibilityLabel(dateAccessibilityLabel(for: listDate))
                    }
                }

                HStack(alignment: .center, spacing: 8) {
                    versionLabel
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if isUpdateIgnored {
                        Image(systemName: "bell.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("已忽略更新")
                    }

                    AppRowAccessoryView(
                        channelSystemImage: application.channelSystemImage,
                        channelTitle:
                            "更新来源：\(application.channelTitle)；更新机制：\(application.mechanismTitle)",
                        isChecking: isChecking || application.status == .checking,
                        updateState: updateState
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
        .contentShape(.rect)
        .help(application.bundleIdentifier)
    }

    @ViewBuilder
    private var versionLabel: some View {
        if let updateVersionSummary = application.updateVersionSummary {
            Text(updateVersionSummary)
        } else {
            Text(application.versionDescription)
        }
    }

    private var usesReleaseDate: Bool {
        application.sidebarDateIsReleaseDate && !isUpdateIgnored
    }

    private func dateHelp(for date: Date) -> String {
        let formattedDate = date.formatted(date: .long, time: .omitted)
        return usesReleaseDate ? "发布日期 \(formattedDate)" : "本机更新日期 \(formattedDate)"
    }

    private func dateAccessibilityLabel(for date: Date) -> String {
        let formattedDate = date.formatted(date: .long, time: .omitted)
        return usesReleaseDate ? "发布于\(formattedDate)" : "更新于\(formattedDate)"
    }
}

extension AppRowView: Equatable {
    nonisolated static func == (lhs: AppRowView, rhs: AppRowView) -> Bool {
        lhs.application == rhs.application
            && lhs.isUpdateIgnored == rhs.isUpdateIgnored
            && lhs.isChecking == rhs.isChecking
            && lhs.updateState === rhs.updateState
    }
}

private struct AppRowAccessoryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.backgroundProminence) private var backgroundProminence
    let channelSystemImage: String
    let channelTitle: String
    let isChecking: Bool
    let updateState: ApplicationUpdateState?

    private var updateProgress: UpdateProgress? { updateState?.progress }
    private var outcome: ApplicationUpdateState.Outcome? { updateState?.outcome }

    var body: some View {
        accessory
            .frame(width: 16, height: 16)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: accessoryState)
    }

    @ViewBuilder
    private var accessory: some View {
        if let updateProgress {
            // The same overall fraction as the detail bar, so both move together.
            ProgressRing(
                fraction: updateState?.overallFraction,
                isWorking: updateProgress.fractionCompleted == nil
            )
            .help(updateProgress.status)
            .accessibilityLabel(progressAccessibilityLabel(updateProgress))
            .transition(.opacity)
        } else if isChecking {
            ProgressRing(fraction: nil)
                .help("正在检查更新")
                .accessibilityLabel("正在检查更新")
                .transition(.opacity)
        } else {
            // One symbol view, so channel, success and failure swap with a symbol replace.
            Image(systemName: symbol.name)
                .font(.caption)
                .foregroundStyle(symbol.style)
                .contentTransition(.symbolEffect(.replace))
                .help(symbol.help)
                .accessibilityLabel(symbol.help)
                .transition(.opacity)
        }
    }

    private var symbol: (name: String, style: AnyShapeStyle, help: String) {
        // On a selected row the accent background would swallow green and orange;
        // the symbol's shape still tells success from failure.
        let prominent = backgroundProminence == .increased
        switch outcome {
        case .succeeded(let version):
            return (
                "checkmark.circle.fill", prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.green),
                "已更新到 \(version)"
            )
        case .failed(let message):
            return (
                "exclamationmark.triangle.fill",
                prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.orange),
                "更新未完成：\(message)"
            )
        case nil:
            return (channelSystemImage, AnyShapeStyle(.secondary), channelTitle)
        }
    }

    private var accessoryState: Int {
        if updateProgress != nil {
            return 2
        }
        if isChecking {
            return 1
        }
        switch outcome {
        case .succeeded: return 3
        case .failed: return 4
        case nil: return 0
        }
    }

    private func progressAccessibilityLabel(_ progress: UpdateProgress) -> String {
        let fraction = updateState?.overallFraction ?? progress.overallFraction
        return "\(progress.status)，\(Int((fraction * 100).rounded(.down)))%"
    }
}
