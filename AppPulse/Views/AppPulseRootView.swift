import AppKit
import SwiftUI

struct AppPulseRootView: View {
  @Environment(\.openURL) private var openURL
  private let applicationLauncher: ApplicationLauncher
  @State private var library: AppLibrary
  @State private var searchText = ""

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
        updateProgressByID: library.updateProgressByID,
        ignoreUpdates: { library.ignoreUpdates(for: $0) },
        stopIgnoringUpdates: { library.stopIgnoringUpdates(for: $0) }
      )
      .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 430)
    } detail: {
      if let application = library.selectedApplication {
        AppDetailView(
          application: application,
          isUpdating: library.updatingApplicationIDs.contains(application.id),
          updateProgress: library.updateProgressByID[application.id],
          isUpdateIgnored: library.isUpdateIgnored(application),
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
            NSWorkspace.shared.activateFileViewerSelecting([application.applicationURL])
          },
          openAppStore: {
            guard let destination = library.appStoreURL(for: application.id) else { return }
            open(destination)
          },
          openReleaseNotes: {
            guard let releaseNotesURL = application.releaseNotesURL else { return }
            open(releaseNotesURL)
          }
        )
        .id(application.id)
      } else {
        DetailUnavailableView(isLoading: library.isRefreshing)
      }
    }
    .navigationSplitViewStyle(.balanced)
    .searchable(text: $searchText, placement: .sidebar, prompt: "搜索应用")
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if !library.automaticUpdates.isEmpty {
          Button("更新全部", systemImage: "arrow.down.circle") {
            Task {
              await library.updateAll()
            }
          }
          .disabled(library.isRefreshing || !library.updatingApplicationIDs.isEmpty)
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
        .disabled(library.isRefreshing || !library.updatingApplicationIDs.isEmpty)
        .help(library.phase.title ?? "重新扫描并检查所有应用")
        .accessibilityLabel(library.phase.title ?? "检查更新")
      }
    }
    .task {
      await library.loadIfNeeded()
    }
    .alert(
      "操作未完成",
      isPresented: Binding(
        get: { library.alertMessage != nil },
        set: { if !$0 { library.alertMessage = nil } }
      )
    ) {
      Button("好", role: .cancel) {
        library.alertMessage = nil
      }
    } message: {
      Text(library.alertMessage ?? "发生未知错误。")
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
}

#Preview("AppPulse") {
  AppPulseRootView(library: AppLibrary(applications: AppRecord.previewApps))
    .frame(width: 1160, height: 760)
}
