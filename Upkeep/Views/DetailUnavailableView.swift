import SwiftUI

struct DetailUnavailableView: View {
    let phase: LibraryPhase

    var body: some View {
        if let title = phase.title {
            VStack(spacing: 12) {
                ProgressView()
                Text(title)
                    .foregroundStyle(.secondary)
            }
        } else {
            ContentUnavailableView(
                "选择一个应用",
                systemImage: "square.split.2x1",
                description: Text("从左侧列表选择应用以查看版本和更新说明。")
            )
        }
    }
}
