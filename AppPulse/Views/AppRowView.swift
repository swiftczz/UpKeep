import SwiftUI

struct AppRowView: View {
  let application: AppRecord
  let isUpdateIgnored: Bool
  var updateProgress: UpdateProgress? = nil

  private var listDate: Date? {
    if application.needsUpdate && !isUpdateIgnored {
      return application.releaseDate
    }
    return application.applicationModificationDate
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

          sourceAccessory
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
    if let latestVersion = application.latestVersion, application.needsUpdate {
      Text("\(application.currentVersion) → \(latestVersion)")
    } else {
      Text("版本 \(application.versionSummary)")
    }
  }

  @ViewBuilder
  private var sourceAccessory: some View {
    if let updateProgress {
      if let fraction = updateProgress.fractionCompleted {
        ProgressView(value: fraction)
          .progressViewStyle(.circular)
          .controlSize(.small)
          .help(updateProgress.status)
          .accessibilityLabel(progressAccessibilityLabel(updateProgress))
      } else {
        ProgressView()
          .controlSize(.small)
          .help(updateProgress.status)
          .accessibilityLabel(updateProgress.status)
      }
    } else if application.status == .checking {
      ProgressView()
        .controlSize(.small)
    } else {
      Image(systemName: application.sourceSystemImage)
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(application.sourceTitle)
        .accessibilityLabel(application.sourceTitle)
    }
  }

  private func progressAccessibilityLabel(_ progress: UpdateProgress) -> String {
    if let percentText = progress.percentText {
      return "\(progress.status)，\(percentText)"
    }
    return progress.status
  }

  private var usesReleaseDate: Bool {
    application.needsUpdate && !isUpdateIgnored
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
