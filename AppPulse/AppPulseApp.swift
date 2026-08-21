import AppKit
import SwiftUI

@main
struct AppPulseApp: App {
  @NSApplicationDelegateAdaptor(AppPulseApplicationDelegate.self) private var applicationDelegate

  var body: some Scene {
    WindowGroup("AppPulse") {
      AppPulseRootView()
        .frame(minWidth: 880, minHeight: 560)
    }
    .defaultSize(width: 1160, height: 760)
    .windowResizability(.contentMinSize)
  }
}

private final class AppPulseApplicationDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
  }
}
