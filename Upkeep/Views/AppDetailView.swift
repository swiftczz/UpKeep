import SwiftUI

struct AppDetailView: View {
  let application: AppRecord
  let isUpdating: Bool
  let updateProgress: UpdateProgress?
  let isUpdateIgnored: Bool
  let requiresRelaunchConfirmation: () -> Bool
  let primaryAction: () -> Void
  let openApplication: () -> Void
  let showInFinder: () -> Void
  let openHomepage: () -> Void
  let openReleaseNotes: () -> Void
  let uninstallApplication: () -> Void

  @State private var isConfirmingRelaunch = false

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
    .onChange(of: application.id) { _, _ in
      isConfirmingRelaunch = false
    }
    .alert(
      "将关闭并重新打开「\(application.name)」",
      isPresented: $isConfirmingRelaunch
    ) {
      Button("更新") {
        primaryAction()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("此应用正在运行。更新会退出应用，安装完成后会重新打开。")
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 18) {
      AppIconView(applicationURL: application.applicationURL, size: 80)
        .id(application.id)

      VStack(alignment: .leading, spacing: 6) {
        Text(application.name)
          .font(.title2.weight(.semibold))

        Text(application.versionDescription)
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
        splitActionControl
      }
    }
  }

  private var splitActionControl: some View {
    HStack(spacing: 0) {
      Button(action: handlePrimaryAction) {
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
  }

  private var primaryActionGlass: Glass {
    var glass = Glass.regular.interactive()
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
      Button("打开", systemImage: "arrow.up.forward.app", action: openApplication)
    }

    if application.applicationURL.isFileURL {
      Button("在 Finder 中显示", systemImage: "folder", action: showInFinder)
    }

    Divider()

    Button("卸载", systemImage: "trash", role: .destructive, action: uninstallApplication)
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
      Label(primaryActionTitle, systemImage: primaryActionSystemImage)
    }
    .foregroundStyle(primaryActionForeground)
    .help(primaryActionHelp)
    .accessibilityLabel(primaryActionTitle)
    .accessibilityHint(primaryActionHelp)
  }

  private var applicationInformation: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("应用信息")
        .font(.headline)

      LazyVGrid(
        columns: [
          GridItem(.flexible(), spacing: 32, alignment: .topLeading),
          GridItem(.flexible(), spacing: 32, alignment: .topLeading),
        ],
        alignment: .leading,
        spacing: 12
      ) {
        ForEach(informationItems, id: \.label) { item in
          informationRow(item.label, value: item.value, action: item.action)
        }
      }

      Text(application.applicationURL.path)
        .font(.caption.monospaced())
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
    }
  }

  private var statusTitle: String {
    if application.needsUpdate {
      if case .checking = application.status {
        return application.status.title
      }
      return UpdateStatus.updateAvailable.title
    }
    return application.status.title
  }

  private var informationItems: [(label: String, value: String, action: (() -> Void)?)] {
    var items: [(label: String, value: String, action: (() -> Void)?)] = [
      ("状态", isUpdateIgnored ? "已忽略更新" : statusTitle, nil),
      ("更新来源", application.sourceTitle, nil),
      ("当前版本", application.versionSummary, nil),
    ]
    if let latestVersionSummary = application.latestVersionSummary {
      items.append(("最新版本", latestVersionSummary, nil))
    }
    if let releaseDate = application.releaseDate {
      items.append(("发布日期", releaseDate.formatted(date: .abbreviated, time: .omitted), nil))
    }
    items.append(("Bundle ID", application.bundleIdentifier, nil))
    if let packageSize = application.packageSizeDescription {
      items.append(("更新包", packageSize, nil))
    }
    if let homepageURL = application.homepageURL {
      items.append(("主页", homepageDisplay(from: homepageURL), openHomepage))
    }
    return items
  }

  @ViewBuilder
  private var releaseNotes: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("更新说明")
          .font(.headline)

        Spacer()

        if application.releaseNotesURL != nil {
          Button("查看完整说明", action: openReleaseNotes)
            .buttonStyle(.link)
        }
      }

      if let notes = application.releaseNotes, !notes.isEmpty {
        ReleaseNotesMarkdownView(source: notes, baseURL: application.releaseNotesURL)
      } else {
        ContentUnavailableView(
          "没有更新说明",
          systemImage: "doc.text.magnifyingglass",
          description: Text(releaseNotesPlaceholder)
        )
        .frame(maxWidth: .infinity, minHeight: 190)
      }
    }
  }

  private func informationRow(
    _ label: String,
    value: String,
    action: (() -> Void)? = nil
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label)
        .foregroundStyle(.secondary)
        .frame(minWidth: 64, alignment: .leading)
      if let action {
        Button(action: action) {
          Text(value)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.link)
        .accessibilityLabel("\(label) \(value)")
        .help("打开主页")
      } else {
        Text(value)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func homepageDisplay(from url: URL) -> String {
    if let appStore = appStoreHomepageDisplay(from: url) {
      return appStore
    }

    var value = url.absoluteString
    if let range = value.range(of: "https://", options: [.anchored, .caseInsensitive])
      ?? value.range(of: "http://", options: [.anchored, .caseInsensitive])
    {
      value.removeSubrange(range)
    }
    if let queryStart = value.firstIndex(of: "?") {
      value = String(value[..<queryStart])
    }
    if let fragmentStart = value.firstIndex(of: "#") {
      value = String(value[..<fragmentStart])
    }
    value = value.removingPercentEncoding ?? value
    if value.hasSuffix("/") {
      value.removeLast()
    }
    return value
  }

  private func appStoreHomepageDisplay(from url: URL) -> String? {
    let host = url.host?.lowercased()
    guard host == "apps.apple.com" || host == "itunes.apple.com" else {
      return nil
    }

    let parts = url.pathComponents.filter { $0 != "/" }
    guard let identifier = parts.last(where: { $0.lowercased().hasPrefix("id") }) else {
      return nil
    }

    if let appIndex = parts.firstIndex(where: { $0.lowercased() == "app" }),
      appIndex > 0,
      parts[appIndex - 1].count == 2
    {
      return "apps.apple.com/\(parts[appIndex - 1])/app/\(identifier)"
    }
    return "apps.apple.com/app/\(identifier)"
  }

  private var primaryActionHelp: String {
    if application.manualUpdateURL != nil {
      return "此条目未提供安装包，前往开发者页面查看更新详情"
    }
    if usesUpdatePrimaryAction {
      switch application.source {
      case .appStore:
        if usesAppStoreUpdateHandoff {
          return application.requiresAppStoreUpdatePageHandoff
            ? "在 App Store 更新页安装此更新"
            : "在 App Store 中打开此应用并更新"
        }
        return "使用当前 App Store 账号下载并安装此更新"
      case .homebrew:
        return "使用 Homebrew 下载并安装此更新"
      case .sparkle, .electronBuilder, .tauri, .vscodeUpdater, .releaseJSON,
        .githubReleases, .selfManaged:
        return "下载并安装此更新"
      }
    }

    return application.needsUpdate
      ? "打开应用并使用其更新器"
      : "打开 \(application.name)"
  }

  private var primaryActionTitle: String {
    if application.manualUpdateURL != nil { return "查看更新" }
    return usesUpdatePrimaryAction ? "更新" : "打开"
  }

  private var primaryActionSystemImage: String {
    if application.manualUpdateURL != nil { return "arrow.up.right.square" }
    return usesUpdatePrimaryAction
      ? "arrow.down.circle"
      : "arrow.up.forward.app"
  }

  private var usesUpdatePrimaryAction: Bool {
    application.needsUpdate
      && (application.canAutomaticallyUpdate || usesAppStoreUpdateHandoff
        || application.manualUpdateURL != nil)
  }

  private var usesAppStoreUpdateHandoff: Bool {
    application.needsUpdate
      && !application.canAutomaticallyUpdate
      && canOpenAppStore
  }

  private func handlePrimaryAction() {
    if requiresRelaunchConfirmation() {
      ApplicationProcess.activateHost()
      isConfirmingRelaunch = true
      return
    }
    primaryAction()
  }

  private var canOpenAppStore: Bool {
    application.source == .appStore && application.sourceURL != nil
  }

  private var releaseNotesPlaceholder: String {
    switch application.status {
    case .unavailable(let message): message
    case .selfManaged: "此应用需在自身内检查更新，当前没有可读取的更新说明。"
    default: "此版本未提供更新说明。"
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
