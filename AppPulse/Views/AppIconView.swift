import AppKit
import SwiftUI

struct AppIconView: View {
  let applicationURL: URL
  let size: CGFloat
  @State private var icon: NSImage?

  var body: some View {
    Group {
      if let icon {
        Image(nsImage: icon)
          .resizable()
          .scaledToFit()
      } else {
        Image(systemName: "app.fill")
          .resizable()
          .scaledToFit()
          .padding(size * 0.18)
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size)
    .task(id: applicationURL) {
      icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
    }
    .accessibilityHidden(true)
  }
}
