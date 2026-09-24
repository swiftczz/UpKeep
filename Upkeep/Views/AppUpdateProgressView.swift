import SwiftUI

/// Only this leaf observes percentage changes; the detail layout observes start/end.
struct AppUpdateProgressView: View {
  let state: ApplicationUpdateState
  private var updateProgress: UpdateProgress? { state.progress }

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      if let fraction = updateProgress?.fractionCompleted {
        ProgressView(value: fraction)
          .progressViewStyle(.linear)
          .tint(.blue)
          .frame(width: 168)
        Text(progressCaption)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      } else {
        ProgressView(updateProgress?.status ?? "正在更新…")
          .controlSize(.small)
      }
    }
    .frame(minWidth: 168, alignment: .trailing)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(progressAccessibilityLabel)
  }

  private var progressCaption: String {
    let status = updateProgress?.status ?? "正在更新…"
    if let percentText = updateProgress?.percentText {
      return "\(status) \(percentText)"
    }
    return status
  }

  private var progressAccessibilityLabel: String {
    if let percentText = updateProgress?.percentText {
      return "\(updateProgress?.status ?? "正在更新")，\(percentText)"
    }
    return updateProgress?.status ?? "正在更新"
  }
}
