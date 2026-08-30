import SwiftUI

struct AppMintRootView: View {
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  private let applicationLauncher: ApplicationLauncher
  @State private var library: AppLibrary
  @State private var searchText = ""
  @State private var uninstallingApplication: AppRecord?
  @State private var pendingUpdateAllRelaunch: [AppRecord] = []

  private static let backgroundRefreshInterval: TimeInterval = 30 * 60

  init(
    library: AppLibrary = AppLibrary(),
    applicationLauncher: ApplicationLauncher = .live
  ) {
    _library = State(initialValue: library)
    self.applicationLauncher = applicationLauncher
  }

  var body: some View {
    @Bindable var library = library

    NavigationSplitView {
      AppSidebarView(
        applications: library.applications,
        selection: $library.selectedApplicationID,
        searchText: searchText,
        phase: library.phase,
        ignoredApplicationIDs: library.ignoredApplicationIDs,
        checkingApplicationIDs: library.checkingApplicationIDs,
        updateProgressByID: library.updateProgressByID,
        ignoreUpdates: { library.ignoreUpdates(for: $0) },
        stopIgnoringUpdates: { library.stopIgnoringUpdates(for: $0) }
      )
      .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 430)
    } detail: {
      if let application = library.selectedApplication {
        if let uninstallingApplication, uninstallingApplication.id == application.id {
          UninstallApplicationView(
            application: uninstallingApplication,
            onCancel: {
              self.uninstallingApplication = nil
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
        } else {
          AppDetailView(
            application: application,
            isUpdating: library.updatingApplicationIDs.contains(application.id),
            updateProgress: library.updateProgressByID[application.id],
            isUpdateIgnored: library.isUpdateIgnored(application),
            requiresRelaunchConfirmation: {
              library.requiresRelaunchConfirmation(for: application)
            },
            primaryAction: {
              Task {
                if let destination = await library.performPrimaryAction(for: application.id) {
                  open(destination)
                }
              }
            },
            openApplication: {
              open(application.applicationURL)
            },
            showInFinder: {
              reveal(application.applicationURL)
            },
            openAppStore: {
              guard let destination = library.appStoreURL(for: application.id) else { return }
              open(destination)
            },
            openHomepage: {
              guard
                application.source == .homebrew || application.source == .sparkle
                  || application.source == .githubReleases,
                let homepageURL = application.homepageURL
              else {
                return
              }
              open(homepageURL)
            },
            openReleaseNotes: {
              guard let releaseNotesURL = application.releaseNotesURL else { return }
              open(releaseNotesURL)
            },
            uninstallApplication: {
              uninstallingApplication = application
            }
          )
          .task(
            id: "\(application.id)|\(application.latestVersion ?? "")|\(application.releaseNotes == nil)"
          ) {
            await library.refreshReleaseMetadataIfNeeded(for: application.id)
          }
        }
      } else {
        DetailUnavailableView(isLoading: library.isRefreshing)
      }
    }
    .navigationSplitViewStyle(.balanced)
    .animation(nil, value: library.selectedApplicationID)
    .searchable(text: $searchText, placement: .sidebar, prompt: "搜索应用或更新来源")
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if !library.automaticUpdates.isEmpty {
          Button("更新全部", systemImage: "arrow.down.circle") {
            beginUpdateAll()
          }
          .disabled(!library.updatingApplicationIDs.isEmpty)
          .help("更新 \(library.automaticUpdates.count) 个可自动更新的应用")
        }

        Button {
          Task {
            await library.refresh()
          }
        } label: {
          Group {
            if library.isRefreshing {
              ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            } else {
              Image(systemName: "arrow.clockwise")
            }
          }
          .frame(width: 16, height: 16)
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(!library.updatingApplicationIDs.isEmpty)
        .help(library.phase.title ?? "重新扫描并检查所有应用")
        .accessibilityLabel(library.phase.title ?? "检查更新")
      }
    }
    .task {
      await library.loadIfNeeded()
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      Task {
        await library.refreshIfStale()
      }
    }
    .task(id: scenePhase) {
      guard scenePhase == .active else { return }
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(Self.backgroundRefreshInterval))
        guard !Task.isCancelled, scenePhase == .active else { return }
        await library.refreshIfStale(after: 0)
      }
    }
    .onChange(of: library.selectedApplicationID) { _, selectedID in
      if uninstallingApplication?.id != selectedID {
        uninstallingApplication = nil
      }
    }
    .alert(
      rootAlertTitle,
      isPresented: Binding(
        get: { presentedRootAlert != nil },
        set: { if !$0 { dismissRootAlert() } }
      )
    ) {
      if case .relaunchAll = presentedRootAlert {
        Button("更新全部") {
          confirmPendingUpdateAll()
        }
        Button("取消", role: .cancel) {
          pendingUpdateAllRelaunch = []
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

  private var presentedRootAlert: RootAlert? {
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
    case .relaunchAll:
      return updateAllRelaunchTitle
    case .failure, .none:
      return "操作未完成"
    }
  }

  private var rootAlertMessage: String {
    switch presentedRootAlert {
    case .relaunchAll:
      return updateAllRelaunchMessage
    case .failure, .none:
      return library.alertMessage ?? "发生未知错误。"
    }
  }

  private func dismissRootAlert() {
    pendingUpdateAllRelaunch = []
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
    let running = library.automaticUpdatesRequiringRelaunch()
    guard !running.isEmpty else {
      Task {
        await library.updateAll()
      }
      return
    }
    pendingUpdateAllRelaunch = running
    ApplicationProcess.activateHost()
  }

  private func confirmPendingUpdateAll() {
    pendingUpdateAllRelaunch = []
    Task {
      await library.updateAll()
    }
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

#Preview("AppMint") {
  AppMintRootView(library: AppLibrary(applications: AppRecord.previewApps))
    .frame(width: 1160, height: 760)
}

private enum RootAlert {
  case relaunchAll
  case failure
}
