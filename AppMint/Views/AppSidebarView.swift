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
  @State private var scrollPosition = ScrollPosition()
  @State private var scrollOffsetY: CGFloat = 0
  @State private var visibleApplicationIDs = Set<AppRecord.ID>()

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
    filteredApplications.installedApplications(ignoredIDs: ignoredApplicationIDs)
  }

  var body: some View {
    List(selection: scrollStableSelection) {
      if !availableUpdates.isEmpty {
        Section {
          ForEach(availableUpdates) { application in
            AppRowView(
              application: application,
              isUpdateIgnored: false,
              updateProgress: updateProgressByID[application.id]
            )
              .tag(application.id)
              .trackScrollVisibility(
                applicationID: application.id,
                visibleApplicationIDs: $visibleApplicationIDs
              )
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
            let isUpdateIgnored = ignoredApplicationIDs.contains(application.id)
            installedApplicationRow(application, isUpdateIgnored: isUpdateIgnored)
              .trackScrollVisibility(
                applicationID: application.id,
                visibleApplicationIDs: $visibleApplicationIDs
              )
          }
        } header: {
          sectionHeader("已安装的应用", count: installedApplications.count)
        }
      }
    }
    .listStyle(.sidebar)
    .scrollPosition($scrollPosition)
    .onScrollGeometryChange(for: CGFloat.self) { geometry in
      geometry.contentOffset.y
    } action: { _, newOffsetY in
      scrollOffsetY = newOffsetY
    }
    .navigationTitle("AppMint")
    .overlay {
      if applications.isEmpty, phase == .idle {
        ContentUnavailableView(
          "没有找到应用",
          systemImage: "app.dashed",
          description: Text("AppMint 会扫描“应用程序”和用户应用目录。")
        )
      } else if filteredApplications.isEmpty, !searchText.isEmpty {
        ContentUnavailableView.search(text: searchText)
      }
    }
  }

  private var scrollStableSelection: Binding<AppRecord.ID?> {
    Binding(
      get: { selection },
      set: { newSelection in
        let wasSelectionOutsideViewport =
          selection.map {
            !visibleApplicationIDs.contains($0)
          } ?? false
        let isNewSelectionVisible = newSelection.map(visibleApplicationIDs.contains) == true
        let shouldRestoreScrollPosition =
          wasSelectionOutsideViewport && isNewSelectionVisible
        let preservedOffsetY = scrollOffsetY

        selection = newSelection

        guard shouldRestoreScrollPosition else { return }
        Task { @MainActor in
          await Task.yield()
          var transaction = Transaction()
          transaction.disablesAnimations = true
          withTransaction(transaction) {
            scrollPosition.scrollTo(y: preservedOffsetY)
          }
        }
      }
    )
  }

  private func sectionHeader(_ title: String, count: Int) -> some View {
    HStack(spacing: 5) {
      Text(title)
      Text("(\(count))")
        .foregroundStyle(.tertiary)
    }
  }

  @ViewBuilder
  private func installedApplicationRow(
    _ application: AppRecord,
    isUpdateIgnored: Bool
  ) -> some View {
    if isUpdateIgnored {
      AppRowView(
        application: application,
        isUpdateIgnored: true,
        updateProgress: updateProgressByID[application.id]
      )
        .tag(application.id)
        .contextMenu {
          Button("取消忽略更新", systemImage: "bell") {
            stopIgnoringUpdates(application.id)
          }
        }
        .accessibilityAction(named: Text("取消忽略更新")) {
          stopIgnoringUpdates(application.id)
        }
    } else {
      AppRowView(
        application: application,
        isUpdateIgnored: false,
        updateProgress: updateProgressByID[application.id]
      )
        .tag(application.id)
    }
  }
}

extension View {
  fileprivate func trackScrollVisibility(
    applicationID: AppRecord.ID,
    visibleApplicationIDs: Binding<Set<AppRecord.ID>>
  ) -> some View {
    onScrollVisibilityChange(threshold: 0.01) { isVisible in
      if isVisible {
        visibleApplicationIDs.wrappedValue.insert(applicationID)
      } else {
        visibleApplicationIDs.wrappedValue.remove(applicationID)
      }
    }
  }
}
