import SwiftUI

struct UninstallApplicationView: View {
  @Environment(\.openURL) private var openURL

  let application: AppRecord
  var knownApplications: [AppRecord] = []
  var scanner: ApplicationResidueScanner = .live
  var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  var applicationLauncher: ApplicationLauncher = .live
  var onCancel: () -> Void
  var onUninstalled: () -> Void
  var onFailed: (String) -> Void

  @State private var items: [ApplicationResidueItem] = []
  @State private var selectedIDs: Set<String> = []
  @State private var isScanning = true
  @State private var isUninstalling = false
  @State private var isConfirming = false
  @State private var containerAccessMessage: String?
  @State private var scanTask: Task<Void, Never>?
  @State private var scanGeneration = UUID()

  var body: some View {
    VStack(spacing: 0) {
      header
        .padding(.horizontal, 32)
        .padding(.top, 32)
        .padding(.bottom, 20)

      Divider()

      Group {
        if isScanning {
          ProgressView("正在查找关联文件…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
          ContentUnavailableView(
            "没有找到关联文件",
            systemImage: "trash",
            description: Text("未找到 \(application.name) 的应用包或其他残留文件。")
          )
        } else {
          fileList
        }
      }

      Divider()

      footer
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.background)
    .navigationTitle("卸载 \(application.name)")
    .task(id: application.id) {
      await scan()
    }
    .confirmationDialog(
      "将选中的 \(selectedItems.count) 个项目移到废纸篓？",
      isPresented: $isConfirming,
      titleVisibility: .visible
    ) {
      Button("移到废纸篓", role: .destructive) {
        Task { await uninstall() }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text(confirmationMessage)
    }
    .alert(
      "需要访问应用数据",
      isPresented: Binding(
        get: { containerAccessMessage != nil },
        set: { if !$0 { containerAccessMessage = nil } }
      )
    ) {
      Button("重新添加完整磁盘访问") {
        if let url = URL(
          string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) {
          openURL(url)
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text(containerAccessMessage ?? "macOS 尚未允许 Upkeep 访问该应用的数据。")
    }
    .disabled(isUninstalling)
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 18) {
      AppIconView(applicationURL: application.applicationURL, size: 80)

      VStack(alignment: .leading, spacing: 6) {
        Text(application.name)
          .font(.title2.weight(.semibold))
        Text(application.bundleIdentifier)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      Spacer(minLength: 24)

      VStack(alignment: .trailing, spacing: 4) {
        Text(sizeSummary(for: selectedItems))
          .font(.title3.weight(.semibold).monospacedDigit())
        Text(selectionSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var fileList: some View {
    List {
      ForEach(ApplicationResidueItem.Category.allCases) { category in
        let groupedItems = items.filter { $0.category == category }
        if !groupedItems.isEmpty {
          Section {
            ForEach(groupedItems) { item in
              residueRow(item)
            }
          } header: {
            HStack {
              Label(category.title, systemImage: category.systemImage)
              Spacer()
              Text(
                "\(groupedItems.count) · \(sizeSummary(for: groupedItems))"
              )
              .foregroundStyle(.secondary)
              .monospacedDigit()
            }
          }
        }
      }
    }
    .listStyle(.inset)
  }

  private func residueRow(_ item: ApplicationResidueItem) -> some View {
    HStack(alignment: .center, spacing: 10) {
      Toggle(
        "",
        isOn: Binding(
          get: { selectedIDs.contains(item.id) },
          set: { isSelected in
            if isSelected {
              selectedIDs.insert(item.id)
            } else {
              selectedIDs.remove(item.id)
            }
          }
        )
      )
      .toggleStyle(.checkbox)
      .labelsHidden()
      .accessibilityLabel("\(item.displayName)，\(item.matchReason.explanation)")

      AppIconView(applicationURL: item.url, size: 28)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.displayName)
          .font(.body.weight(.medium))
          .lineLimit(1)
        Text(ApplicationResiduePath.breadcrumb(for: item.url, homeDirectory: homeDirectory))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .help(item.url.path)
        Text(item.matchReason.explanation)
          .font(.caption)
          .foregroundStyle(item.isSelectedByDefault ? Color.secondary : Color.orange)
          .lineLimit(2)
          .help(item.matchReason.explanation)
      }

      Spacer(minLength: 12)

      Text(item.formattedSize)
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 3)
    .contextMenu {
      Button("在 Finder 中显示", systemImage: "folder") {
        reveal(item.url)
      }
    }
  }

  private var footer: some View {
    HStack {
      Button(selectedIDs.count == items.count ? "取消全选" : "全选") {
        if selectedIDs.count == items.count {
          selectedIDs.removeAll()
        } else {
          selectedIDs = Set(items.map(\.id))
        }
      }
      .disabled(items.isEmpty || isScanning)

      Spacer()

      if isUninstalling {
        ProgressView()
          .controlSize(.small)
        Text("正在等待系统完成移除…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Button("返回详情", action: onCancel)
        .keyboardShortcut(.cancelAction)

      Button("移到废纸篓", role: .destructive) {
        isConfirming = true
      }
      .disabled(selectedItems.isEmpty || isScanning || isUninstalling)
      .keyboardShortcut(.defaultAction)
    }
  }

  private var selectedItems: [ApplicationResidueItem] {
    items.filter { selectedIDs.contains($0.id) }
  }

  private func sizeSummary(for items: [ApplicationResidueItem]) -> String {
    guard !isScanning, items.allSatisfy(\.isSizeCalculated) else { return "正在计算大小…" }
    return items.reduce(Int64(0)) { $0 + $1.byteCount }.formatted(.byteCount(style: .file))
  }

  private var selectionSummary: String {
    if isScanning {
      return "正在查找…"
    }
    return "\(selectedItems.count)/\(items.count) 个文件"
  }

  private var confirmationMessage: String {
    if selectedItems.contains(where: {
      $0.url.standardizedFileURL == application.applicationURL.standardizedFileURL
    }) {
      return "将删除 \(application.name) 及应用关联文件。项目会进入废纸篓，可在清空前恢复。"
    }
    return "只移除选中的关联文件。项目会进入废纸篓，可在清空前恢复。"
  }

  private func scan() async {
    scanTask?.cancel()
    let generation = UUID()
    scanGeneration = generation
    isScanning = true
    items = []
    selectedIDs = []
    let application = application
    var scanner = scanner
    scanner.knownApplications = knownApplications
    let task = Task { @MainActor in
      for await event in scanner.events(for: application) {
        guard !Task.isCancelled, scanGeneration == generation else { return }
        switch event {
        case .found(let scanned):
          items = scanned
          selectedIDs = ApplicationResidueItem.defaultSelection(in: scanned)
          isScanning = false
        case .measured(let item):
          if let index = items.firstIndex(where: { $0.id == item.id }) {
            // Keep row order and the user's choices stable as sizes arrive.
            items[index] = item
          }
        }
      }
    }
    scanTask = task
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func uninstall() async {
    scanTask?.cancel()
    scanGeneration = UUID()
    isUninstalling = true
    defer { isUninstalling = false }

    do {
      let result = try await ApplicationUninstaller.uninstall(
        application,
        items: selectedItems
      )
      if result.didRemoveApplication {
        onUninstalled()
      } else {
        await scan()
      }
    } catch {
      if let accessError = error as? ApplicationContainerAccessError {
        containerAccessMessage = accessError.localizedDescription
        return
      }
      await scan()
      onFailed(error.localizedDescription)
    }
  }

  private func reveal(_ url: URL) {
    Task {
      try? await applicationLauncher.reveal(url)
    }
  }
}
