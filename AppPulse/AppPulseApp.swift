import SwiftUI

@main
struct AppPulseApp: App {
  private let applicationIconClient = ApplicationIconClient.live()

  var body: some Scene {
    WindowGroup("AppPulse") {
      AppPulseRootView()
        .frame(minWidth: 880, minHeight: 560)
        .environment(\.applicationIconClient, applicationIconClient)
    }
    .defaultSize(width: 1160, height: 760)
    .windowResizability(.contentMinSize)
  }
}
