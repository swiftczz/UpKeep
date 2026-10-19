import SwiftUI

@main
struct UpkeepApp: App {
    private let applicationIconClient = ApplicationIconClient.live()
    @State private var githubAccount = GitHubAccount.shared

    var body: some Scene {
        WindowGroup("Upkeep") {
            UpkeepRootView()
                .frame(minWidth: 880, minHeight: 560)
                .environment(\.applicationIconClient, applicationIconClient)
                .environment(githubAccount)
                .task {
                    await Task.detached(priority: .utility) {
                        PrivilegedPackageInstaller.prepareIfBundled()
                    }.value
                }
        }
        .defaultSize(width: 1160, height: 760)
        .windowResizability(.contentMinSize)

        Settings {
            UpkeepSettingsView()
                .environment(githubAccount)
        }
        .windowResizability(.contentSize)
    }
}
