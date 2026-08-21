import SwiftUI

struct AppPulseRootView: View {
  @State private var library: AppLibrary
  @State private var searchText = ""

  init(library: AppLibrary = AppLibrary()) {
    _library = State(initialValue: library)
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
        ignoreUpdates: { library.ignoreUpdates(for: $0) },
        stopIgnoringUpdates: { library.stopIgnoringUpdates(for: $0) }
      )
      .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 430)
    } detail: {
      if let application = library.selectedApplication {
        AppDetailView(
          application: application,
          isUpdating: library.updatingApplicationIDs.contains(application.id),
          isUpdateIgnored: library.isUpdateIgnored(application),
          primaryAction: {
            Task {
              await library.performPrimaryAction(for: application.id)
            }
          },
          openReleaseNotes: {
            library.openReleaseNotes(for: application)
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
        if let phaseTitle = library.phase.title {
          ProgressView()
            .controlSize(.small)
            .help(phaseTitle)
        }

        if !library.automaticUpdates.isEmpty {
          Button("更新全部", systemImage: "arrow.down.circle") {
            Task {
              await library.updateAll()
            }
          }
          .disabled(library.isRefreshing || !library.updatingApplicationIDs.isEmpty)
          .help("通过 Homebrew 更新 \(library.automaticUpdates.count) 个应用")
        }

        Button("检查更新", systemImage: "arrow.clockwise") {
          Task {
            await library.refresh()
          }
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(library.isRefreshing || !library.updatingApplicationIDs.isEmpty)
        .help("重新扫描并检查所有应用")
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
}

#Preview("AppPulse") {
  AppPulseRootView(library: AppLibrary(applications: AppRecord.previewApps))
    .frame(width: 1160, height: 760)
}
