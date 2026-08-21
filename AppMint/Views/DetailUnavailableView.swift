import SwiftUI

struct DetailUnavailableView: View {
  let isLoading: Bool

  var body: some View {
    if isLoading {
      VStack(spacing: 12) {
        ProgressView()
        Text("正在扫描应用…")
          .foregroundStyle(.secondary)
      }
    } else {
      ContentUnavailableView(
        "选择一个应用",
        systemImage: "square.split.2x1",
        description: Text("从左侧列表选择应用以查看版本和发行说明。")
      )
    }
  }
}
