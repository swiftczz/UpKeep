import AppKit
import SwiftUI

struct UpkeepRootView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(GitHubAccount.self) private var githubAccount
    private let applicationLauncher: ApplicationLauncher
    private let applicationChangeMonitor: ApplicationChangeMonitor
    @State private var library: AppLibrary
    @State private var uninstallingApplication: AppRecord?
    @State private var pendingUpdateAllPlan: UpdateAllPlan?
    @State private var pendingAppStoreUpdate: (name: String, destination: URL)?
    @State private var updateAllPreparationTask: Task<Void, Never>?
    @State private var updateAllPreparationID: UUID?
    @State private var manualRefreshTask: Task<Void, Never>?
    @State private var isManualRefreshInProgress = false
    @State private var needsGitHubConnectionRefresh = false
    @State private var localApplicationChangeRefreshTask: Task<Void, Never>?

    private static let periodicRefreshInterval: TimeInterval = 10 * 60
    private static let localApplicationChangeDebounce: Duration = .seconds(2)

    init(
        library: AppLibrary = AppLibrary(),
        applicationLauncher: ApplicationLauncher = .live,
        applicationChangeMonitor: ApplicationChangeMonitor = .live()
    ) {
        _library = State(initialValue: library)
        self.applicationLauncher = applicationLauncher
        self.applicationChangeMonitor = applicationChangeMonitor
    }

    var body: some View {
        @Bindable var library = library

        NavigationSplitView {
            AppSidebarView(
                sections: library.sidebarSections,
                selection: $library.selectedApplicationID,
                searchText: library.searchText,
                phase: library.phase,
                checkingApplicationIDs: library.checkingApplicationIDs,
                updateStatesByID: library.updateStatesByID,
                ignoreUpdates: { library.ignoreUpdates(for: $0) },
                stopIgnoringUpdates: { library.stopIgnoringUpdates(for: $0) }
            )
            .safeAreaBar(edge: .bottom) {
                // The empty list already shows scan progress in its own placeholder.
                if !library.sidebarSections.applicationIDs.isEmpty {
                    LibraryStatusBar(
                        phase: library.phase,
                        checkedCount: max(
                            library.checkingTotalCount - library.checkingApplicationIDs.count, 0),
                        checkTotalCount: library.checkingTotalCount,
                        updateAllProgress: library.updateAllProgress,
                        lastCheckedAt: library.lastCheckedAt
                    )
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 430)
        } detail: {
            if let application = library.selectedApplication {
                if let uninstallingApplication, uninstallingApplication.id == application.id {
                    UninstallApplicationView(
                        application: uninstallingApplication,
                        knownApplications: library.applications,
                        onCancel: {
                            withAnimation(pageTransitionAnimation) {
                                self.uninstallingApplication = nil
                            }
                        },
                        onUninstalled: {
                            library.forgetUninstalled(uninstallingApplication)
                            self.uninstallingApplication = nil
                        },
                        onFailed: { message in
                            library.alertMessage = message
                        }
                    )
                    .id("uninstall-\(uninstallingApplication.id)")
                    .transition(.blurReplace)
                } else {
                    AppDetailView(
                        application: application,
                        updateState: library.updateStatesByID[application.id],
                        isUpdateIgnored: library.isUpdateIgnored(application),
                        prereleasePolicy: library.prereleasePolicy(for: application),
                        setPrereleasePolicy: { policy in
                            Task {
                                await library.setPrereleasePolicy(policy, for: application.id)
                            }
                        },
                        requiresRelaunchConfirmation: {
                            await library.requiresRelaunchConfirmation(for: application)
                        },
                        primaryAction: {
                            Task {
                                if let destination = await library.performPrimaryAction(
                                    for: application.id)
                                {
                                    if destination.scheme == "macappstore" {
                                        pendingAppStoreUpdate = (application.name, destination)
                                    } else {
                                        open(destination)
                                    }
                                }
                            }
                        },
                        openApplication: {
                            open(application.applicationURL)
                        },
                        showInFinder: {
                            reveal(application.applicationURL)
                        },
                        openHomepage: {
                            guard let homepageURL = application.updateConfiguration.homepageURL
                            else { return }
                            open(homepageURL)
                        },
                        openReleaseNotes: {
                            guard let releaseNotesURL = application.releaseNotesURL else { return }
                            open(releaseNotesURL)
                        },
                        uninstallApplication: {
                            withAnimation(pageTransitionAnimation) {
                                uninstallingApplication = application
                            }
                        }
                    )
                    .transition(.blurReplace)
                    .task(
                        id:
                            "\(application.id)|\(application.currentVersion)|\(application.latestVersion ?? "")|\(application.hasIncompleteReleaseMetadata)|\(library.phase == .idle)|\(library.updatingApplicationIDs.contains(application.id))"
                    ) {
                        await library.refreshReleaseMetadataIfNeeded(for: application.id)
                    }
                }
            } else {
                DetailUnavailableView(phase: library.phase)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .animation(nil, value: library.selectedApplicationID)
        .searchable(text: $library.searchText, placement: .sidebar, prompt: "搜索应用、来源或机制")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !library.automaticUpdates.isEmpty {
                    Button(action: beginUpdateAll) {
                        // A constant label keeps the toolbar from shifting while work runs;
                        // the sidebar footer reports which application is being updated.
                        Label {
                            Text("更新全部")
                        } icon: {
                            Group {
                                if isUpdateAllBusy {
                                    ProgressRing(fraction: updateAllFraction, isWorking: true)
                                } else {
                                    Image(systemName: "arrow.down.circle")
                                }
                            }
                            .frame(width: 16, height: 16)
                        }
                    }
                    // Updates started one by one keep running; this queues the rest.
                    .disabled(isUpdateAllBusy || library.remainingAutomaticUpdates.isEmpty)
                    .accessibilityLabel(updateAllAccessibilityLabel)
                    .help(updateAllHelp)
                }

                Button {
                    beginManualRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(
                            .rotate, isActive: isManualRefreshInProgress && !reduceMotion
                        )
                        .frame(width: 16, height: 16)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!library.updatingApplicationIDs.isEmpty || manualRefreshTask != nil)
                .help(isManualRefreshInProgress ? library.phase.title ?? "正在刷新…" : "重新扫描并检查所有应用")
                .accessibilityLabel(isManualRefreshInProgress ? "正在检查更新" : "检查更新")

                SettingsLink {
                    Label("设置", systemImage: "gearshape")
                }
                .help("设置更新来源")
                .accessibilityIdentifier("upkeep.settings")
            }
        }
        .task {
            await library.loadIfNeeded()
        }
        .onChange(of: library.availableUpdates.count, initial: true) { _, count in
            NSApp?.dockTile.badgeLabel = count > 0 ? String(count) : nil
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.periodicRefreshInterval))
                guard !Task.isCancelled else { return }
                await library.refreshIfStale(after: 0)
            }
        }
        .task {
            for await _ in applicationChangeMonitor.changes() {
                guard !Task.isCancelled else { return }
                scheduleRefreshAfterLocalApplicationChange()
            }
        }
        .onDisappear {
            needsGitHubConnectionRefresh = false
            cancelUpdateAllPreparation()
            cancelManualRefresh()
            cancelRefreshAfterLocalApplicationChange()
        }
        .onChange(of: library.selectedApplicationID) { _, selectedID in
            if uninstallingApplication?.id != selectedID {
                uninstallingApplication = nil
            }
        }
        .onChange(of: githubAccount.connectionRevision) { _, _ in
            needsGitHubConnectionRefresh = githubAccount.isConnected
            refreshAfterGitHubConnectionIfReady()
        }
        .onChange(of: isManualRefreshInProgress) { _, isRefreshing in
            if !isRefreshing { refreshAfterGitHubConnectionIfReady() }
        }
        .alert(
            rootAlertTitle,
            isPresented: Binding(
                get: { presentedRootAlert != nil },
                set: { if !$0 { dismissRootAlert() } }
            )
        ) {
            if case .appStoreUpdate = presentedRootAlert,
                let pending = pendingAppStoreUpdate
            {
                Button("确定") {
                    pendingAppStoreUpdate = nil
                    open(pending.destination)
                }
                Button("取消", role: .cancel) {
                    pendingAppStoreUpdate = nil
                }
            } else if case .relaunchAll = presentedRootAlert {
                Button("更新全部") {
                    confirmPendingUpdateAll()
                }
                Button("取消", role: .cancel) {
                    pendingUpdateAllPlan = nil
                }
            } else {
                Button("好", role: .cancel) {
                    library.alertMessage = nil
                }
            }
        } message: {
            Text(rootAlertMessage)
        }
    }

    private var pageTransitionAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.3)
    }

    /// Nil while preparing, so the ring shows only its comet.
    private var updateAllFraction: Double? {
        library.updateAllProgress.map {
            Double($0.completedCount) / Double(max($0.totalCount, 1))
        }
    }

    private var isUpdateAllBusy: Bool {
        updateAllPreparationID != nil || library.updateAllProgress != nil
    }

    private var updateAllHelp: String {
        if let progress = library.updateAllProgress {
            return "正在更新 \(progress.completedCount)/\(progress.totalCount)"
        }
        if updateAllPreparationID != nil { return "正在准备更新…" }
        return "更新 \(library.automaticUpdates.count) 个可自动更新的应用"
    }

    private var updateAllAccessibilityLabel: String {
        if library.updateAllProgress != nil { return "正在更新全部" }
        if updateAllPreparationID != nil { return "正在准备更新全部" }
        return "更新全部"
    }

    private var pendingUpdateAllRelaunch: [AppRecord] {
        pendingUpdateAllPlan?.runningApplications ?? []
    }

    private var presentedRootAlert: RootAlert? {
        if pendingAppStoreUpdate != nil {
            return .appStoreUpdate
        }
        if !pendingUpdateAllRelaunch.isEmpty {
            return .relaunchAll
        }
        if library.alertMessage != nil {
            return .failure
        }
        return nil
    }

    private var rootAlertTitle: String {
        switch presentedRootAlert {
        case .appStoreUpdate:
            return "前往 App Store 更新"
        case .relaunchAll:
            return updateAllRelaunchTitle
        case .failure, .none:
            return "操作未完成"
        }
    }

    private var rootAlertMessage: String {
        switch presentedRootAlert {
        case .appStoreUpdate:
            let name = pendingAppStoreUpdate?.name ?? "此应用"
            return "「\(name)」需要在 App Store 中完成更新。点击“确定”将打开 App Store，请在那里继续更新。"
        case .relaunchAll:
            return updateAllRelaunchMessage
        case .failure, .none:
            return library.alertMessage ?? "发生未知错误。"
        }
    }

    private func dismissRootAlert() {
        if pendingAppStoreUpdate != nil {
            pendingAppStoreUpdate = nil
            return
        }
        pendingUpdateAllPlan = nil
        library.alertMessage = nil
    }

    private var updateAllRelaunchTitle: String {
        if pendingUpdateAllRelaunch.count == 1, let name = pendingUpdateAllRelaunch.first?.name {
            return "将关闭并重新打开「\(name)」"
        }
        return "将关闭并重新打开正在运行的应用"
    }

    private var updateAllRelaunchMessage: String {
        let names = pendingUpdateAllRelaunch.map { "「\($0.name)」" }.joined(separator: "、")
        if pendingUpdateAllRelaunch.count <= 1 {
            return "\(names) 正在运行。更新需要退出此应用，安装完成后会重新打开。"
        }
        return "\(names) 正在运行。更新需要退出这些应用，安装完成后会重新打开。"
    }

    private func beginUpdateAll() {
        guard updateAllPreparationID == nil else { return }
        let requestID = UUID()
        updateAllPreparationID = requestID
        updateAllPreparationTask = Task {
            let plan = await library.prepareUpdateAll()
            guard !Task.isCancelled, updateAllPreparationID == requestID else { return }
            updateAllPreparationTask = nil
            updateAllPreparationID = nil
            if plan.runningApplications.isEmpty {
                await library.updateAll(applicationIDs: plan.applicationIDs)
            } else {
                pendingUpdateAllPlan = plan
                ApplicationProcess.activateHost()
            }
        }
    }

    private func cancelUpdateAllPreparation() {
        updateAllPreparationTask?.cancel()
        updateAllPreparationTask = nil
        updateAllPreparationID = nil
    }

    private func confirmPendingUpdateAll() {
        guard let plan = pendingUpdateAllPlan else { return }
        pendingUpdateAllPlan = nil
        Task {
            await library.updateAll(applicationIDs: plan.applicationIDs)
        }
    }

    private func beginManualRefresh() {
        guard manualRefreshTask == nil else { return }
        manualRefreshTask = Task {
            isManualRefreshInProgress = true
            defer {
                isManualRefreshInProgress = false
                manualRefreshTask = nil
            }

            await library.restartRefresh()
            while library.isRefreshing, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func refreshAfterGitHubConnectionIfReady() {
        guard needsGitHubConnectionRefresh, manualRefreshTask == nil else { return }
        needsGitHubConnectionRefresh = false
        beginManualRefresh()
    }

    private func cancelManualRefresh() {
        manualRefreshTask?.cancel()
        manualRefreshTask = nil
        isManualRefreshInProgress = false
    }

    private func scheduleRefreshAfterLocalApplicationChange() {
        localApplicationChangeRefreshTask?.cancel()
        localApplicationChangeRefreshTask = Task {
            try? await Task.sleep(for: Self.localApplicationChangeDebounce)
            guard !Task.isCancelled else { return }
            // Only the debounce delay is cancellable by the next file notification.
            localApplicationChangeRefreshTask = nil
            await library.refreshInstalledApplications()
        }
    }

    private func cancelRefreshAfterLocalApplicationChange() {
        localApplicationChangeRefreshTask?.cancel()
        localApplicationChangeRefreshTask = nil
    }

    private func open(_ url: URL) {
        guard !url.isFileURL else {
            Task {
                do {
                    try await applicationLauncher.launch(url)
                } catch {
                    library.reportOpeningFailure(for: url)
                }
            }
            return
        }

        openURL(url)
    }

    private func reveal(_ url: URL) {
        Task {
            try? await applicationLauncher.reveal(url)
        }
    }
}

#Preview("Upkeep") {
    UpkeepRootView(library: AppLibrary(applications: AppRecord.previewApps))
        .environment(GitHubAccount.preview())
        .frame(width: 1160, height: 760)
}

private enum RootAlert {
    case appStoreUpdate
    case relaunchAll
    case failure
}
