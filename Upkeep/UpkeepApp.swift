import SwiftUI

@main
struct UpkeepApp: App {
  private let applicationIconClient = ApplicationIconClient.live()

  var body: some Scene {
    WindowGroup("Upkeep") {
      UpkeepRootView()
        .frame(minWidth: 880, minHeight: 560)
        .environment(\.applicationIconClient, applicationIconClient)
    }
    .defaultSize(width: 1160, height: 760)
    .windowResizability(.contentMinSize)
  }
}
