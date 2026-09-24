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
            sourceSystemImage: application.sourceSystemImage,
            sourceTitle: application.sourceTitle,
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
  let sourceSystemImage: String
  let sourceTitle: String
  let isChecking: Bool
  let updateState: ApplicationUpdateState?

  private var updateProgress: UpdateProgress? { updateState?.progress }

  var body: some View {
    accessory
      .frame(width: 16, height: 16)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: accessoryState)
  }

  @ViewBuilder
  private var accessory: some View {
    if let updateProgress {
      if let fraction = updateProgress.fractionCompleted {
        ProgressView(value: fraction)
          .progressViewStyle(.circular)
          .controlSize(.small)
          .help(updateProgress.status)
          .accessibilityLabel(progressAccessibilityLabel(updateProgress))
          .transition(.opacity)
      } else {
        ProgressView()
          .controlSize(.small)
          .help(updateProgress.status)
          .accessibilityLabel(updateProgress.status)
          .transition(.opacity)
      }
    } else if isChecking {
      ProgressView()
        .controlSize(.small)
        .help("正在检查更新")
        .accessibilityLabel("正在检查更新")
        .transition(.opacity)
    } else {
      Image(systemName: sourceSystemImage)
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(sourceTitle)
        .accessibilityLabel(sourceTitle)
        .transition(.opacity)
    }
  }

  private var accessoryState: Int {
    if updateProgress != nil {
      return 2
    }
    if isChecking {
      return 1
    }
    return 0
  }

  private func progressAccessibilityLabel(_ progress: UpdateProgress) -> String {
    if let percentText = progress.percentText {
      return "\(progress.status)，\(percentText)"
    }
    return progress.status
  }
}
