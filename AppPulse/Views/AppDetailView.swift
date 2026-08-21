import SwiftUI

struct AppDetailView: View {
  let application: AppRecord
  let isUpdating: Bool
  let isUpdateIgnored: Bool
  let primaryAction: () -> Void
  let openReleaseNotes: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        header

        Divider()

        applicationInformation

        Divider()

        releaseNotes
      }
      .padding(32)
      .frame(maxWidth: 900, alignment: .leading)
    }
    .navigationTitle(application.name)
    .background(.background)
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 18) {
      AppIconView(applicationURL: application.applicationURL, size: 80)

      VStack(alignment: .leading, spacing: 6) {
        Text(application.name)
          .font(.title2.weight(.semibold))

        Text(versionDescription)
          .foregroundStyle(.secondary)

        HStack(spacing: 6) {
          SourceBadge(application: application)

          if isUpdateIgnored {
            Label("已忽略更新", systemImage: "bell.slash")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(.quaternary, in: .capsule)
          }
        }
      }

      Spacer(minLength: 24)
      primaryButton
    }
  }

  @ViewBuilder
  private var primaryButton: some View {
    if application.needsUpdate {
      Button(action: primaryAction) {
        if isUpdating {
          ProgressView()
            .controlSize(.small)
        } else {
          Label(primaryActionTitle, systemImage: "arrow.up.forward.app")
        }
      }
      .buttonStyle(.glassProminent)
      .disabled(isUpdating)
      .help(primaryActionHelp)
      .accessibilityHint(primaryActionHelp)
    } else {
      Button(action: primaryAction) {
        Label("打开", systemImage: "arrow.up.forward.app")
      }
      .buttonStyle(.glass)
    }
  }

  private var applicationInformation: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("应用信息")
        .font(.headline)

      Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 10) {
        informationRow(
          "状态",
          value: isUpdateIgnored ? "已忽略更新" : application.status.title
        )
        informationRow("当前版本", value: application.versionSummary)

        if let latestVersion = application.latestVersion {
          informationRow("最新版本", value: latestVersion)
        }

        informationRow("更新来源", value: application.sourceTitle)
        informationRow("Bundle ID", value: application.bundleIdentifier)

        if let releaseDate = application.releaseDate {
          informationRow(
            "发布日期",
            value: releaseDate.formatted(date: .abbreviated, time: .omitted)
          )
        }
      }

      Text(application.applicationURL.path)
        .font(.caption.monospaced())
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
    }
  }

  @ViewBuilder
  private var releaseNotes: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("发行说明")
          .font(.headline)

        Spacer()

        if application.releaseNotesURL != nil {
          Button("查看完整说明", action: openReleaseNotes)
            .buttonStyle(.link)
        }
      }

      if let notes = application.releaseNotes, !notes.isEmpty {
        Text(notes)
          .font(.body)
          .textSelection(.enabled)
          .lineSpacing(3)
      } else {
        ContentUnavailableView(
          "没有发行说明",
          systemImage: "doc.text.magnifyingglass",
          description: Text(releaseNotesPlaceholder)
        )
        .frame(maxWidth: .infinity, minHeight: 190)
      }
    }
  }

  private func informationRow(_ label: String, value: String) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
      Text(value)
        .textSelection(.enabled)
    }
  }

  private var versionDescription: String {
    if let latestVersion = application.latestVersion, application.needsUpdate {
      return "版本 \(application.currentVersion) → \(latestVersion)"
    }
    return "版本 \(application.versionSummary)"
  }

  private var primaryActionHelp: String {
    switch application.source {
    case .appStore:
      "在 \(application.sourceTitle) 中打开此应用的更新页面"
    case .sparkle, .github, .selfManaged, .homebrew:
      "打开应用并使用其更新器"
    }
  }

  private var primaryActionTitle: String {
    application.source == .appStore ? "打开 App Store" : "打开应用"
  }

  private var releaseNotesPlaceholder: String {
    switch application.status {
    case .unavailable(let message): message
    case .selfManaged where application.source == .github:
      "此应用来自 GitHub，当前没有可读取的发行说明。"
    case .selfManaged: "此应用由自身更新器管理，当前没有可读取的发行说明。"
    default: "此版本未提供发行说明。"
    }
  }
}

private struct SourceBadge: View {
  let application: AppRecord

  var body: some View {
    Label {
      Text(application.sourceTitle)
    } icon: {
      AppSourceIconView(application: application)
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(.quaternary, in: .capsule)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(application.sourceTitle)
  }
}
