import SwiftUI

struct AppSidebarView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let sections: AppSidebarSections
  @Binding var selection: AppRecord.ID?
  let searchText: String
  let phase: LibraryPhase
  let checkingApplicationIDs: Set<AppRecord.ID>
  let updateStatesByID: [AppRecord.ID: ApplicationUpdateState]
  let ignoreUpdates: (AppRecord.ID) -> Void
  let stopIgnoringUpdates: (AppRecord.ID) -> Void

  private var stableSelection: Binding<AppRecord.ID?> {
    Binding(
      get: { selection },
      set: { proposedSelection in
        if proposedSelection == nil,
          let selection,
          sections.applicationIDs.contains(selection)
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
      if !sections.availableUpdates.isEmpty {
        Section {
          ForEach(sections.availableUpdates) { application in
            AppRowView(
              application: application,
              isUpdateIgnored: false,
              isChecking: checkingApplicationIDs.contains(application.id),
              updateState: updateStatesByID[application.id]
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
          sectionHeader("可用更新", count: sections.availableUpdates.count)
        }
      }

      if !sections.installedApplications.isEmpty {
        Section {
          ForEach(sections.installedApplications) { application in
            AppRowView(
              application: application,
              isUpdateIgnored: false,
              isChecking: checkingApplicationIDs.contains(application.id),
              updateState: updateStatesByID[application.id]
            )
            .equatable()
            .id(application.id)
            .tag(application.id)
            .transition(rowTransition)
          }
        } header: {
          sectionHeader("已安装的应用", count: sections.installedApplications.count)
        }
      }

      if !sections.ignoredUpdates.isEmpty {
        Section {
          ForEach(sections.ignoredUpdates) { application in
            AppRowView(
              application: application,
              isUpdateIgnored: true,
              isChecking: checkingApplicationIDs.contains(application.id),
              updateState: updateStatesByID[application.id]
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
          sectionHeader("已忽略的更新", count: sections.ignoredUpdates.count)
        }
      }
    }
    .listStyle(.sidebar)
    .animation(
      reduceMotion ? nil : .smooth(duration: 0.24),
      value: sections.layout
    )
    .navigationTitle("Upkeep")
    .overlay {
      if sections.applicationIDs.isEmpty {
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
            description: Text("Upkeep 会扫描“应用程序”和用户应用目录。")
          )
        }
      } else if sections.isEmpty, !searchText.isEmpty {
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
