import SwiftUI

struct AppDetailView: View {
  let application: AppRecord
  let isUpdating: Bool
  let updateProgress: UpdateProgress?
  let isUpdateIgnored: Bool
  let primaryAction: () -> Void
  let openApplication: () -> Void
  let showInFinder: () -> Void
  let openAppStore: () -> Void
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

      if isUpdating {
        updateProgressControl
      } else {
        primaryActionMenu
      }
    }
  }

  private var primaryActionMenu: some View {
    splitActionControl
  }

  private var splitActionControl: some View {
    HStack(spacing: 0) {
      Button(action: primaryAction) {
        primaryActionLabel
          .padding(.leading, 14)
          .padding(.trailing, 12)
          .padding(.vertical, 7)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)

      Rectangle()
        .fill(primaryActionForeground.opacity(0.3))
        .frame(width: 1, height: 18)
        .accessibilityHidden(true)

      Menu {
        secondaryActions
      } label: {
        Image(systemName: "chevron.down")
          .symbolRenderingMode(.palette)
          .foregroundStyle(primaryActionForeground)
          .font(.system(size: 11, weight: .semibold))
          .frame(width: 30)
          .padding(.vertical, 6)
          .contentShape(.rect)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .help("更多操作")
      .accessibilityLabel("更多操作")
    }
    .glassEffect(primaryActionGlass, in: .rect(cornerRadius: 8))
    .disabled(isUpdating)
  }

  private var primaryActionGlass: Glass {
    var glass = Glass.regular.interactive(!isUpdating)
    if usesUpdatePrimaryAction {
      glass = glass.tint(.blue)
    }
    return glass
  }

  private var primaryActionForeground: Color {
    usesUpdatePrimaryAction ? .white : .primary
  }

  @ViewBuilder
  private var secondaryActions: some View {
    if usesUpdatePrimaryAction {
      Button("打开应用", systemImage: "arrow.up.forward.app", action: openApplication)
    }

    if application.applicationURL.isFileURL {
      Button("在 Finder 中显示", systemImage: "folder", action: showInFinder)
    }

    if canOpenAppStore {
      Button("在 App Store 中查看", systemImage: "apple.logo", action: openAppStore)
    }

    Divider()

    Button("卸载应用", systemImage: "trash", role: .destructive) {}
      .disabled(true)
  }

  private var updateProgressControl: some View {
    VStack(alignment: .trailing, spacing: 6) {
      if let fraction = updateProgress?.fractionCompleted {
        ProgressView(value: fraction)
          .progressViewStyle(.linear)
          .tint(.blue)
          .frame(width: 168)
        Text(progressCaption)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
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

  private var primaryActionLabel: some View {
    HStack(spacing: 6) {
      if isUpdating {
        ProgressView()
          .controlSize(.small)
          .tint(primaryActionForeground)
          .accessibilityHidden(true)
        Text("正在更新…")
      } else {
        Label(primaryActionTitle, systemImage: primaryActionSystemImage)
      }
    }
    .foregroundStyle(primaryActionForeground)
    .help(primaryActionHelp)
    .accessibilityLabel(isUpdating ? "正在更新" : primaryActionTitle)
    .accessibilityHint(primaryActionHelp)
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
    if usesUpdatePrimaryAction {
      switch application.source {
      case .appStore:
        return "使用当前 App Store 账号下载并安装此更新"
      case .homebrew:
        return "使用 Homebrew 下载并安装此更新"
      case .sparkle, .github, .selfManaged:
        return "下载并安装此更新"
      }
    }

    return application.needsUpdate
      ? "打开应用并使用其更新器"
      : "打开 \(application.name)"
  }

  private var primaryActionTitle: String {
    usesUpdatePrimaryAction ? "更新" : "打开应用"
  }

  private var primaryActionSystemImage: String {
    usesUpdatePrimaryAction
      ? "arrow.down.circle"
      : "arrow.up.forward.app"
  }

  private var usesUpdatePrimaryAction: Bool {
    application.needsUpdate && application.canAutomaticallyUpdate
  }

  private var canOpenAppStore: Bool {
    application.source == .appStore && application.sourceURL != nil
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
