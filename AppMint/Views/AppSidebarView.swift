import SwiftUI

struct AppSidebarView: View {
  let applications: [AppRecord]
  @Binding var selection: AppRecord.ID?
  let searchText: String
  let phase: LibraryPhase
  let ignoredApplicationIDs: Set<AppRecord.ID>
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

  var body: some View {
    List(selection: $selection) {
      if !availableUpdates.isEmpty {
        Section {
          ForEach(availableUpdates) { application in
            AppRowView(
              application: application,
              isUpdateIgnored: false,
              updateProgress: updateProgressByID[application.id]
            )
            .equatable()
            .tag(application.id)
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
              updateProgress: updateProgressByID[application.id]
            )
            .equatable()
            .tag(application.id)
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
              updateProgress: updateProgressByID[application.id]
            )
            .equatable()
            .tag(application.id)
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
    .animation(nil, value: applications)
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

extension AppSidebarView: Equatable {
  nonisolated static func == (lhs: AppSidebarView, rhs: AppSidebarView) -> Bool {
    lhs.applications == rhs.applications
      && lhs.searchText == rhs.searchText
      && lhs.phase == rhs.phase
      && lhs.ignoredApplicationIDs == rhs.ignoredApplicationIDs
      && lhs.updateProgressByID == rhs.updateProgressByID
  }
}
