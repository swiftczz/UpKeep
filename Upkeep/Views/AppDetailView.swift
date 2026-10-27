import SwiftUI

struct AppDetailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var primaryActionNamespace
    let application: AppRecord
    let updateState: ApplicationUpdateState?
    let isUpdateIgnored: Bool
    let prereleasePolicy: PrereleasePolicy
    let setPrereleasePolicy: (PrereleasePolicy) -> Void
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
    /// Shown only when the running-app check is slow, so a quick check never flashes.
    @State private var showsPreparation = false
    @State private var isShowingMoreActions = false

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
        // Drawn above the scroll view so the panel is never clipped or covered.
        .overlayPreferenceValue(MoreActionsAnchorKey.self) { anchor in
            moreActionsOverlay(below: anchor)
        }
        .onChange(of: application.id) { _, _ in
            cancelPreparation()
            isConfirmingRelaunch = false
            isShowingMoreActions = false
        }
        .onChange(of: primaryActionPhase) { _, _ in
            isShowingMoreActions = false
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
                    .padding(.leading, ActionRowMetrics.leadingInset)
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

            Button {
                setMoreActionsShown(!isShowingMoreActions)
            } label: {
                Image(systemName: "chevron.down")
                    .foregroundStyle(primaryActionForeground)
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(isShowingMoreActions ? 180 : 0))
                    .frame(width: 30)
                    .padding(.vertical, 6)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("更多操作")
            .accessibilityLabel("更多操作")
            .accessibilityValue(isShowingMoreActions ? "已展开" : "已收起")
        }
        .glassEffect(primaryActionGlass, in: .rect(cornerRadius: 8))
        .glassEffectID(PrimaryActionGlassID.shape, in: primaryActionNamespace)
        .anchorPreference(key: MoreActionsAnchorKey.self, value: .bounds) { $0 }
        // Repeat clicks are ignored without restyling the control mid-check.
        .allowsHitTesting(preparationID == nil)
        .disabled(showsPreparation)
    }

    /// The panel drops down from the action control, matching its width and left edge
    /// so its icons and titles line up with the primary action's.
    @ViewBuilder
    private func moreActionsOverlay(below anchor: Anchor<CGRect>?) -> some View {
        GeometryReader { proxy in
            if let anchor {
                let control = proxy[anchor]
                ZStack(alignment: .topLeading) {
                    if isShowingMoreActions {
                        // Clicking anywhere else closes the panel, like a menu.
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture { setMoreActionsShown(false) }
                            .accessibilityHidden(true)

                        Button("关闭", action: { setMoreActionsShown(false) })
                            .keyboardShortcut(.cancelAction)
                            .frame(width: 0, height: 0)
                            .opacity(0)
                            .accessibilityHidden(true)
                    }

                    // Stays in place while closed so opening can pull it out of the button.
                    MoreActionsPanel(
                        items: moreActionItems, progress: isShowingMoreActions ? 1 : 0
                    ) { item in
                        setMoreActionsShown(false)
                        item.action()
                    }
                    .frame(width: control.width)
                    .offset(x: control.minX, y: control.maxY + 6)
                    .allowsHitTesting(isShowingMoreActions)
                    .accessibilityHidden(!isShowingMoreActions)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func setMoreActionsShown(_ shown: Bool) {
        withAnimation(reduceMotion ? nil : .smooth(duration: shown ? 0.3 : 0.2)) {
            isShowingMoreActions = shown
        }
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

    /// "在 Finder 中显示" lives on the Location item in the information grid.
    private var moreActionItems: [MoreActionsPanel.Item] {
        var items: [MoreActionsPanel.Item] = []
        if usesUpdatePrimaryAction {
            items.append(
                .init(title: "打开", systemImage: "arrow.up.forward.app", action: openApplication))
        }
        items.append(
            .init(
                title: "卸载", systemImage: "trash", isDestructive: true,
                action: uninstallApplication))
        return items
    }

    private var primaryActionLabel: some View {
        // The same icon column as the drop-down rows, so their titles line up.
        HStack(spacing: ActionRowMetrics.iconSpacing) {
            if showsPreparation {
                ProgressView().controlSize(.small)
                    .frame(width: ActionRowMetrics.iconWidth)
                Text("正在准备…")
            } else {
                Image(systemName: primaryActionSystemImage)
                    .frame(width: ActionRowMetrics.iconWidth)
                Text(primaryActionTitle)
            }
        }
        .foregroundStyle(primaryActionForeground)
        .help("\(primaryActionHelp)（\(usesUpdatePrimaryAction ? "⌘U" : "⌘O")）")
        .accessibilityLabel(showsPreparation ? "正在准备更新" : primaryActionTitle)
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
                    informationRow(item)
                }
            }

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

    private struct InformationItem {
        let label: String
        let value: String
        var action: (() -> Void)? = nil
        /// Tooltip for a linked value.
        var help: String? = nil
        /// Paths stay on one line and are shortened in the middle.
        var truncatesMiddle = false
        /// Choices shown in a menu on the value, with the current one checked.
        var choices: [(title: String, isSelected: Bool, select: () -> Void)] = []
    }

    /// Store, Homebrew-only and VS Code updates have no preview releases to choose.
    private var offersPrereleaseChoice: Bool {
        let mechanism =
            application.updateConfiguration.mechanism == .homebrew
            ? application.alternateUpdateCheckRecord?.updateConfiguration.mechanism
            : application.updateConfiguration.mechanism
        guard let mechanism else { return false }
        return [.sparkle, .githubReleases, .tauri, .customAPI, .electronBuilder].contains(mechanism)
    }

    /// The receive-version choice, kept in a fixed early slot of the grid.
    private var receivedVersionsItem: InformationItem? {
        guard offersPrereleaseChoice else { return nil }
        var resolved = application
        resolved.prereleasePolicy = prereleasePolicy
        let value =
            prereleasePolicy == .automatic
            ? "自动（\(resolved.acceptsPrereleases ? PrereleasePolicy.includePrereleases.title : PrereleasePolicy.stableOnly.title)）"
            : prereleasePolicy.title
        return InformationItem(
            label: "接收版本", value: value,
            help: "选择是否接收 alpha、beta、rc 等预览版本",
            choices: PrereleasePolicy.allCases.map { policy in
                (policy.title, policy == prereleasePolicy, { setPrereleasePolicy(policy) })
            })
    }

    private var informationItems: [InformationItem] {
        var items = [
            InformationItem(label: "状态", value: isUpdateIgnored ? "已忽略更新" : statusTitle),
            InformationItem(label: "当前版本", value: application.versionSummary),
            InformationItem(label: "更新来源", value: application.channelTitle),
            InformationItem(label: "更新机制", value: application.mechanismTitle),
        ]
        if application.updateConfiguration.mechanism == .appStore,
            let platform = application.appStorePlatform
        {
            items.append(InformationItem(label: "商店平台", value: platform.title))
        }
        if let latestVersionSummary = application.latestVersionSummary {
            items.append(InformationItem(label: "最新版本", value: latestVersionSummary))
        }
        if let releaseDate = application.releaseDate {
            items.append(
                InformationItem(
                    label: "发布日期",
                    value: releaseDate.formatted(date: .abbreviated, time: .omitted)))
        }
        items.append(InformationItem(label: "Bundle ID", value: application.bundleIdentifier))
        if let packageSize = application.packageSizeDescription {
            items.append(InformationItem(label: "更新包", value: packageSize))
        }
        if let homepageURL = application.updateConfiguration.homepageURL {
            items.append(
                InformationItem(
                    label: "主页", value: homepageDisplay(from: homepageURL),
                    action: openHomepage, help: "打开主页"))
        }
        if application.applicationURL.isFileURL {
            let path = application.applicationURL.path
            items.append(
                InformationItem(
                    label: "位置", value: (path as NSString).abbreviatingWithTildeInPath,
                    action: showInFinder, help: "在 Finder 中显示 \(path)",
                    truncatesMiddle: true))
        }
        if let receivedVersionsItem {
            items.insert(receivedVersionsItem, at: min(5, items.count))
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

    private func informationRow(_ item: InformationItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(item.label)
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .leading)
            if !item.choices.isEmpty {
                Menu {
                    ForEach(item.choices, id: \.title) { choice in
                        Button(action: choice.select) {
                            if choice.isSelected {
                                Label(choice.title, systemImage: "checkmark")
                            } else {
                                Text(choice.title)
                            }
                        }
                    }
                } label: {
                    // Plain text keeps this row the same height as the other values.
                    HStack(spacing: 4) {
                        Text(item.value)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(item.help ?? "")
                .accessibilityLabel("\(item.label) \(item.value)")
            } else if let action = item.action {
                Button(action: action) {
                    informationValue(item)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.link)
                .accessibilityLabel("\(item.label) \(item.value)")
                .help(item.help ?? "")
            } else {
                informationValue(item)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func informationValue(_ item: InformationItem) -> some View {
        if item.truncatesMiddle {
            Text(item.value)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text(item.value)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        // Only an automatic update can need a relaunch confirmation. Opening the app or
        // its update page acts at once, so the control is never disabled for a frame.
        guard application.needsUpdate, application.canAutomaticallyUpdate else {
            primaryAction()
            return
        }
        guard preparationID == nil else { return }
        let requestID = UUID()
        preparationID = requestID
        preparationTask = Task {
            let indicator = Task {
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled, preparationID == requestID { showsPreparation = true }
            }
            let requiresConfirmation = await requiresRelaunchConfirmation()
            indicator.cancel()
            guard !Task.isCancelled, preparationID == requestID else { return }
            preparationTask = nil
            preparationID = nil
            showsPreparation = false
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
        showsPreparation = false
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

/// Shared by the primary action and the drop-down rows so icons and titles align.
private enum ActionRowMetrics {
    static let leadingInset: CGFloat = 14
    static let iconWidth: CGFloat = 16
    static let iconSpacing: CGFloat = 8
    static let panelPadding: CGFloat = 4
}

private struct MoreActionsAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Secondary actions that drop down beneath the primary action.
private struct MoreActionsPanel: View, Animatable {
    struct Item: Identifiable {
        var id: String { title }
        let title: String
        let systemImage: String
        var isDestructive = false
        let action: () -> Void
    }

    let items: [Item]
    /// How far the panel is pulled out, from 0 (closed) to 1 (open).
    var progress: Double
    let perform: (Item) -> Void
    @State private var fullHeight: CGFloat = 0

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        rows
            .padding(ActionRowMetrics.panelPadding)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
            // The rows slide down a little behind the growing edge.
            .offset(y: -8 * (1 - progress))
            // The glass grows from the top edge, so its bottom edge is pulled down.
            .frame(height: progress < 1 ? fullHeight * progress : nil, alignment: .top)
            .clipped()
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .shadow(color: .black.opacity(0.12 * progress), radius: 12, y: 6)
            .opacity(progress > 0 ? 1 : 0)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                // Destructive actions sit in their own group.
                if item.isDestructive, index > 0, !items[index - 1].isDestructive {
                    Divider().padding(.horizontal, 8).padding(.vertical, 2)
                }
                MoreActionRow(item: item) { perform(item) }
            }
        }
    }
}

private struct MoreActionRow: View {
    let item: MoreActionsPanel.Item
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: ActionRowMetrics.iconSpacing) {
                Image(systemName: item.systemImage)
                    .frame(width: ActionRowMetrics.iconWidth)
                Text(item.title)
                Spacer(minLength: 0)
            }
            .foregroundStyle(item.isDestructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            // Panel padding plus row padding equals the primary action's inset.
            .padding(.leading, ActionRowMetrics.leadingInset - ActionRowMetrics.panelPadding)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(highlight, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(item.title)
    }

    private var highlight: AnyShapeStyle {
        guard isHovered else { return AnyShapeStyle(.clear) }
        return item.isDestructive
            ? AnyShapeStyle(.red.opacity(0.12)) : AnyShapeStyle(.primary.opacity(0.08))
    }
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
