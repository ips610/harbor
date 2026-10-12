import Foundation
import UserNotifications

/// macOS notifications, for the one thing harbor tells its owner about unasked: a server
/// they chose to watch has stopped. The text is harbor's own (see Monitor.stoppedText).
/// A debug run, a test, and a copy that isn't an app say nothing.
enum Notifier {
    private static var isApp: Bool { !DebugCLI.isDebugRun && Bundle.main.bundleURL.pathExtension == "app" }

    /// Asks macOS once whether harbor may show notifications: when the first bell is set, so the question comes with its reason.
    static func ask() {
        guard isApp else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// What posts a notification (a test puts its own here).
    static var post: (String) -> Void = { text in
        guard isApp else { return }
        let content = UNMutableNotificationContent()
        content.title = AppInfo.name
        content.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
