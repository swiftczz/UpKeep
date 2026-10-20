import CoreGraphics
import SwiftUI

struct AppIconView: View {
    let applicationURL: URL
    let size: CGFloat
    @Environment(\.applicationIconClient) private var applicationIconClient
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loadedIcon: LoadedIcon?

    private struct LoadedIcon {
        let applicationURL: URL
        let image: CGImage
    }

    var body: some View {
        // Cached icons render in the first frame, so reused rows never flash the placeholder.
        let icon =
            applicationIconClient.cached(applicationURL, displayScale)
            ?? loadedIcon.flatMap { $0.applicationURL == applicationURL ? $0.image : nil }

        Group {
            if let icon {
                Image(decorative: icon, scale: displayScale)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.18)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .task(id: applicationURL) {
            guard applicationIconClient.cached(applicationURL, displayScale) == nil else { return }
            let image = await applicationIconClient.load(applicationURL, displayScale)
            guard !Task.isCancelled, let image else { return }
            // Only icons that were actually missing fade in.
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                loadedIcon = LoadedIcon(applicationURL: applicationURL, image: image)
            }
        }
        .accessibilityHidden(true)
    }
}
