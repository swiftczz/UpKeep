import AppKit
import UserNotifications

/// Reports finished updates in Notification Center while Upkeep is in the background.
struct UpdateNotifier: Sendable {
    var prepare: @MainActor @Sendable () -> Void
    var notify: @MainActor @Sendable (_ title: String, _ body: String) -> Void

    static let disabled = UpdateNotifier(prepare: {}, notify: { _, _ in })

    static var live: UpdateNotifier {
        // Notification Center needs an app bundle; `swift test` and `swift run` have none.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .disabled }
        return UpdateNotifier(
            prepare: {
                // Asks only once; later calls return the stored decision without a prompt.
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
                    _, _ in
                }
            },
            notify: { title, body in
                guard !NSApplication.shared.isActive else { return }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString, content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request) { _ in }
            }
        )
    }
}
