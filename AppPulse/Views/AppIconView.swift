import CoreGraphics
import SwiftUI

struct AppIconView: View {
  let applicationURL: URL
  let size: CGFloat
  @Environment(\.applicationIconClient) private var applicationIconClient
  @Environment(\.displayScale) private var displayScale
  @State private var icon: CGImage?

  var body: some View {
    Group {
      if let icon {
        Image(decorative: icon, scale: displayScale)
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
      let loadedIcon = await applicationIconClient.load(applicationURL, displayScale)
      guard !Task.isCancelled else { return }
      icon = loadedIcon
    }
    .accessibilityHidden(true)
  }
}
