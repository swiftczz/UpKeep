import SwiftUI

struct AppSidebarView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let applications: [AppRecord]
  @Binding var selection: AppRecord.ID?
  let searchText: String
  let phase: LibraryPhase
  let ignoredApplicationIDs: Set<AppRecord.ID>
  let checkingApplicationIDs: Set<AppRecord.ID>
  let updateProgressByID: [AppRecord.ID: UpdateProgress]
  let ignoreUpdates: (AppRecord.ID) -> Void
  let stopIgnoringUpdates: (AppRecord.ID) -> Void

  private var filteredApplications: [AppRecord] {
    guard !searchText.isEmpty else { return applications }
    return applications.filter {
      $0.name.localizedCaseInsensitiveContains(searchText)
        || $0.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
    }
  }

  private var availableUpdates: [AppRecord] {
    filteredApplications.availableUpdates(ignoredIDs: ignoredApplicationIDs)
  }

  private var installedApplications: [AppRecord] {
    filteredApplications.installedApplications()
  }

  private var ignoredUpdates: [AppRecord] {
    filteredApplications.ignoredUpdates(ignoredIDs: ignoredApplicationIDs)
  }

  private var layoutSnapshot: LayoutSnapshot {
    LayoutSnapshot(
      availableUpdateIDs: availableUpdates.map(\.id),
      installedApplicationIDs: installedApplications.map(\.id),
      ignoredUpdateIDs: ignoredUpdates.map(\.id)
    )
  }

  private var stableSelection: Binding<AppRecord.ID?> {
    Binding(
      get: { selection },
      set: { proposedSelection in
        if proposedSelection == nil,
          let selection,
          applications.contains(where: { $0.id == selection })
        {
          return
        }
        selection = proposedSelection
      }
    )
  }

  private var rowTransition: AnyTransition {
    .asymmetric(
      insertion: .move(edge: .top).combined(with: .opacity),
      removal: .opacity
    )
  }

  var body: some View {
    List(selection: stableSelection) {
      if !availableUpdates.isEmpty {
        Section {
          ForEach(availableUpdates) { application in
            AppRowView(
              application: application,
              isUpdateIgnored: false,
              isChecking: checkingApplicationIDs.contains(application.id),
              updateProgress: updateProgressByID[application.id]
            )
            .equatable()
            .id(application.id)
            .tag(application.id)
            .transition(rowTransition)
            .contextMenu {
              Button("忽略更新", systemImage: "bell.slash") {
                ignoreUpdates(application.id)
              }
            }
            .accessibilityAction(named: Text("忽略更新")) {
              ignoreUpdates(application.id)
            }
          }
        } header: {
          sectionHeader("可用更新", count: availableUpdates.count)
        }
      }

      if !installedApplications.isEmpty {
        Section {
          ForEach(installedApplications) { application in
            AppRowView(
              application: application,
              isUpdateIgnored: false,
              isChecking: checkingApplicationIDs.contains(application.id),
              updateProgress: updateProgressByID[application.id]
            )
            .equatable()
            .id(application.id)
            .tag(application.id)
            .transition(rowTransition)
          }
        } header: {
          sectionHeader("已安装的应用", count: installedApplications.count)
        }
      }

      if !ignoredUpdates.isEmpty {
        Section {
          ForEach(ignoredUpdates) { application in
            AppRowView(
              application: application,
              isUpdateIgnored: true,
              isChecking: checkingApplicationIDs.contains(application.id),
              updateProgress: updateProgressByID[application.id]
            )
            .equatable()
            .id(application.id)
            .tag(application.id)
            .transition(rowTransition)
            .contextMenu {
              Button("取消忽略更新", systemImage: "bell") {
                stopIgnoringUpdates(application.id)
              }
            }
            .accessibilityAction(named: Text("取消忽略更新")) {
              stopIgnoringUpdates(application.id)
            }
          }
        } header: {
          sectionHeader("已忽略的更新", count: ignoredUpdates.count)
        }
      }
    }
    .listStyle(.sidebar)
    .animation(
      reduceMotion ? nil : .smooth(duration: 0.24),
      value: layoutSnapshot
    )
    .navigationTitle("AppMint")
    .overlay {
      if applications.isEmpty {
        if phase != .idle {
          VStack(spacing: 10) {
            ProgressView()
              .controlSize(.small)
            Text(phase.title ?? "正在扫描应用…")
              .foregroundStyle(.secondary)
          }
        } else {
          ContentUnavailableView(
            "没有找到应用",
            systemImage: "app.dashed",
            description: Text("AppMint 会扫描“应用程序”和用户应用目录。")
          )
        }
      } else if filteredApplications.isEmpty, !searchText.isEmpty {
        ContentUnavailableView.search(text: searchText)
      }
    }
  }

  private func sectionHeader(_ title: String, count: Int) -> some View {
    HStack(spacing: 5) {
      Text(title)
      Text("(\(count))")
        .foregroundStyle(.tertiary)
    }
  }
}

private struct LayoutSnapshot: Equatable {
  let availableUpdateIDs: [AppRecord.ID]
  let installedApplicationIDs: [AppRecord.ID]
  let ignoredUpdateIDs: [AppRecord.ID]
}
