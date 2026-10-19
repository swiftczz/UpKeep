import SwiftUI

struct AppSidebarView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasShownInitialRows = false
    @State private var initialVisibleRowCount = 0

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
        let orderedIDs =
            sections.layout.availableUpdateIDs
            + sections.layout.installedApplicationIDs + sections.layout.ignoredUpdateIDs
        let visibleIDs = Set(
            orderedIDs.prefix(
                hasShownInitialRows || reduceMotion ? orderedIDs.count : initialVisibleRowCount
            ))
        let availableUpdates = sections.availableUpdates.filter { visibleIDs.contains($0.id) }
        let installedApplications = sections.installedApplications.filter {
            visibleIDs.contains($0.id)
        }
        let ignoredUpdates = sections.ignoredUpdates.filter { visibleIDs.contains($0.id) }
        let visibleLayout = AppSidebarSections.Layout(
            availableUpdateIDs: availableUpdates.map(\.id),
            installedApplicationIDs: installedApplications.map(\.id),
            ignoredUpdateIDs: ignoredUpdates.map(\.id)
        )

        List(selection: stableSelection) {
            if !availableUpdates.isEmpty {
                Section {
                    ForEach(availableUpdates) { application in
                        applicationRow(application)
                    }
                } header: {
                    sectionHeader("可用更新", count: sections.availableUpdates.count)
                }
            }

            if !installedApplications.isEmpty {
                Section {
                    ForEach(installedApplications) { application in
                        applicationRow(application)
                    }
                } header: {
                    sectionHeader("已安装的应用", count: sections.installedApplications.count)
                }
            }

            if !ignoredUpdates.isEmpty {
                Section {
                    ForEach(ignoredUpdates) { application in
                        applicationRow(application)
                    }
                } header: {
                    sectionHeader("已忽略的应用", count: sections.ignoredUpdates.count)
                }
            }
        }
        .listStyle(.sidebar)
        .animation(
            reduceMotion ? nil : .smooth(duration: hasShownInitialRows ? 0.24 : 0.32),
            value: visibleLayout
        )
        .task(id: sections.isEmpty) {
            guard !sections.isEmpty, !hasShownInitialRows else { return }
            if !reduceMotion {
                // Insert whole rows in batches so the list expands as it fills.
                do {
                    try await Task.sleep(for: .milliseconds(80))
                    let animatedRowCount = min(orderedIDs.count, 16)
                    while initialVisibleRowCount < animatedRowCount {
                        guard !Task.isCancelled else { return }
                        initialVisibleRowCount = min(initialVisibleRowCount + 4, animatedRowCount)
                        try await Task.sleep(for: .milliseconds(180))
                    }
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            hasShownInitialRows = true
        }
        .onDisappear {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                hasShownInitialRows = false
                initialVisibleRowCount = 0
            }
        }
        .onChange(of: searchText) { _, _ in
            // Search remains immediate even during the entrance.
            hasShownInitialRows = true
        }
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

    private func applicationRow(_ application: AppRecord) -> some View {
        let isIgnored = sections.ignoredApplicationIDs.contains(application.id)
        let actionTitle = isIgnored ? "取消忽略更新" : (application.needsUpdate ? "忽略更新" : "添加忽略")
        let actionImage = isIgnored ? "bell" : "bell.slash"

        return AppRowView(
            application: application,
            isUpdateIgnored: isIgnored,
            isChecking: checkingApplicationIDs.contains(application.id),
            updateState: updateStatesByID[application.id]
        )
        .equatable()
        .id(application.id)
        .tag(application.id)
        .transition(rowTransition)
        .contextMenu {
            Button(actionTitle, systemImage: actionImage) {
                setIgnoringUpdates(!isIgnored, for: application.id)
            }
        }
        .accessibilityAction(named: Text(actionTitle)) {
            setIgnoringUpdates(!isIgnored, for: application.id)
        }
    }

    private func setIgnoringUpdates(_ ignored: Bool, for applicationID: AppRecord.ID) {
        if ignored {
            ignoreUpdates(applicationID)
        } else {
            stopIgnoringUpdates(applicationID)
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
