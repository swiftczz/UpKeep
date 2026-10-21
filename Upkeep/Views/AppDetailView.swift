import SwiftUI

struct AppDetailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var primaryActionNamespace
    let application: AppRecord
    let updateState: ApplicationUpdateState?
    let isUpdateIgnored: Bool
    let requiresRelaunchConfirmation: () async -> Bool
    let primaryAction: () -> Void
    let openApplication: () -> Void
    let showInFinder: () -> Void
    let openHomepage: () -> Void
    let openReleaseNotes: () -> Void
    let uninstallApplication: () -> Void

    @State private var isConfirmingRelaunch = false
    @State private var preparationTask: Task<Void, Never>?
    @State private var preparationID: UUID?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                header

                if let updateFailure {
                    UpdateFailureBanner(
                        message: updateFailure,
                        retry: retryAction,
                        dismiss: { updateState?.clearOutcome() }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider()

                applicationInformation

                Divider()

                releaseNotes
            }
            .padding(32)
            .frame(maxWidth: 900, alignment: .leading)
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: updateFailure)
        }
        // Each application's lazy layout starts at the top with fresh height estimates.
        .id(application.id)
        .navigationTitle(application.name)
        .background(.background)
        .onChange(of: application.id) { _, _ in
            cancelPreparation()
            isConfirmingRelaunch = false
        }
        .onDisappear { cancelPreparation() }
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
                    UpdateChannelBadge(application: application)

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
            // The name keeps its width; the progress bar beside it gives way first.
            .layoutPriority(1)

            Spacer(minLength: 24)

            primaryActionArea
        }
    }

    private enum PrimaryActionPhase: Equatable {
        case idle
        case updating
        case succeeded(version: String)
    }

    private var primaryActionPhase: PrimaryActionPhase {
        guard let updateState else { return .idle }
        if updateState.isUpdating { return .updating }
        if case .succeeded(let version) = updateState.outcome { return .succeeded(version: version) }
        return .idle
    }

    private var updateFailure: String? {
        guard let updateState, !updateState.isUpdating,
            case .failed(let message) = updateState.outcome
        else { return nil }
        return message
    }

    private var retryAction: (() -> Void)? {
        guard usesUpdatePrimaryAction else { return nil }
        return { handlePrimaryAction() }
    }

    /// The action, its progress and the result share one glass shape that morphs between them.
    private var primaryActionArea: some View {
        GlassEffectContainer {
            switch primaryActionPhase {
            case .updating:
                if let updateState {
                    // Sits directly in the header: no card or border around the progress.
                    AppUpdateProgressView(state: updateState)
                        .transition(.blurReplace)
                }
            case .succeeded(let version):
                UpdateSucceededBadge(version: version)
                    .glassEffect(.regular, in: .rect(cornerRadius: 8))
                    .glassEffectID(PrimaryActionGlassID.shape, in: primaryActionNamespace)
            case .idle:
                splitActionControl
            }
        }
        // Keeps the header height stable while the trailing control changes.
        .frame(minHeight: 34)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: primaryActionPhase)
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
            .keyboardShortcut(usesUpdatePrimaryAction ? "u" : "o", modifiers: .command)

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
        .glassEffectID(PrimaryActionGlassID.shape, in: primaryActionNamespace)
        .disabled(preparationID != nil)
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

    private var primaryActionLabel: some View {
        HStack(spacing: 6) {
            if preparationID != nil {
                ProgressView().controlSize(.small)
                Text("正在准备…")
            } else {
                Label(primaryActionTitle, systemImage: primaryActionSystemImage)
            }
        }
        .foregroundStyle(primaryActionForeground)
        .help("\(primaryActionHelp)（\(usesUpdatePrimaryAction ? "⌘U" : "⌘O")）")
        .accessibilityLabel(preparationID == nil ? primaryActionTitle : "正在准备更新")
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
            if usesApplicationUpdaterHandoff {
                Text("此更新需使用应用自带的安装程序，请打开应用后检查更新。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
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
            ("当前版本", application.versionSummary, nil),
            ("更新来源", application.channelTitle, nil),
            ("更新机制", application.mechanismTitle, nil),
        ]
        if application.updateConfiguration.mechanism == .appStore,
            let platform = application.appStorePlatform
        {
            items.append(("商店平台", platform.title, nil))
        }
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
        if let homepageURL = application.updateConfiguration.homepageURL {
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

            if let message = githubConnectionIssue {
                GitHubConnectionNotice(message: message)
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
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.link)
                .accessibilityLabel("\(label) \(value)")
                .help("打开主页")
            } else {
                Text(value)
                    .fixedSize(horizontal: false, vertical: true)
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
        if usesApplicationUpdaterHandoff { return "打开应用，使用应用自身的更新器完成安装" }
        if application.manualUpdateURL != nil {
            return "此条目未提供安装包，前往开发者页面查看更新详情"
        }
        if usesUpdatePrimaryAction {
            if usesAppStoreUpdateHandoff {
                return application.requiresAppStoreUpdatePageHandoff
                    ? "在 App Store 更新页安装此更新"
                    : "在 App Store 中打开此应用并更新"
            }
            return application.updateConfiguration.mechanism.traits.installHelp
        }

        return application.needsUpdate
            ? "打开应用并使用其更新器"
            : "打开 \(application.name)"
    }

    private var primaryActionTitle: String {
        if application.manualUpdateURL != nil { return "查看更新" }
        if usesApplicationUpdaterHandoff { return "应用内更新" }
        return usesUpdatePrimaryAction ? "更新" : "打开"
    }

    private var usesApplicationUpdaterHandoff: Bool {
        (application.updateConfiguration.mechanism == .sparkle
            || application.requiresBundleMigration)
            && application.needsUpdate
            && !application.canAutomaticallyUpdate && application.manualUpdateURL == nil
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
        guard preparationID == nil else { return }
        let requestID = UUID()
        preparationID = requestID
        preparationTask = Task {
            let requiresConfirmation = await requiresRelaunchConfirmation()
            guard !Task.isCancelled, preparationID == requestID else { return }
            preparationTask = nil
            preparationID = nil
            if requiresConfirmation {
                ApplicationProcess.activateHost()
                isConfirmingRelaunch = true
            } else {
                primaryAction()
            }
        }
    }

    private func cancelPreparation() {
        preparationTask?.cancel()
        preparationTask = nil
        preparationID = nil
    }

    private var canOpenAppStore: Bool {
        application.updateConfiguration.mechanism == .appStore
            && application.updateConfiguration.feedURL != nil
    }

    private var releaseNotesPlaceholder: String {
        if githubConnectionIssue != nil { return "暂时无法获取更新说明。" }
        return switch application.status {
        case .unavailable(let message): message
        case .selfManaged: "此应用需在自身内检查更新，当前没有可读取的更新说明。"
        default: "此版本未提供更新说明。"
        }
    }

    private var githubConnectionIssue: String? {
        guard case .unavailable(let message) = application.status,
            GitHubConnectionNotice.recognizes(message)
        else { return nil }
        return message
    }
}

private enum PrimaryActionGlassID: Hashable {
    case shape
}

private struct UpdateSucceededBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var celebrates = false
    let version: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: celebrates)
            Text("已更新到 \(version)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .onAppear {
            if !reduceMotion { celebrates = true }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct UpdateFailureBanner: View {
    let message: String
    let retry: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("更新未完成")
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if let retry {
                Button("重试", action: retry)
                    .buttonStyle(.glass)
            }

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help("关闭")
            .accessibilityLabel("关闭失败提示")
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.orange.opacity(0.25))
        }
    }
}

private struct UpdateChannelBadge: View {
    let application: AppRecord

    var body: some View {
        Label {
            Text(application.channelTitle)
        } icon: {
            UpdateChannelIconView(application: application)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("更新来源：\(application.channelTitle)")
        .help("更新来源：\(application.channelTitle)；更新机制：\(application.mechanismTitle)")
    }
}
