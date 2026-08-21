import SwiftUI

struct AppRowView: View {
  let application: AppRecord
  let isUpdateIgnored: Bool

  var body: some View {
    HStack(spacing: 11) {
      AppIconView(applicationURL: application.applicationURL, size: 42)

      VStack(alignment: .leading, spacing: 2) {
        Text(application.name)
          .font(.headline)
          .lineLimit(1)

        if let latestVersion = application.latestVersion,
          application.needsUpdate
        {
          Text("\(application.currentVersion) → \(latestVersion)")
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
          Text("版本 \(application.versionSummary)")
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Spacer(minLength: 8)

      if isUpdateIgnored {
        Image(systemName: "bell.slash")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help("已忽略更新")
      }

      if application.status == .checking {
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
    .padding(.vertical, 5)
    .contentShape(.rect)
    .help(application.bundleIdentifier)
  }
}
