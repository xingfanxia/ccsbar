import Foundation
import UserNotifications

/// Local user notifications for the events the operator wants to learn about while
/// away (TECH-11): an UNATTENDED (scheduler) account switch, and a new auto-switch
/// error. A user's own tap is intentionally NOT notified — they just did it.
///
/// `UNUserNotificationCenter` requires a real app bundle; a bare `swift run`
/// executable has no bundle identifier and would crash on `.current()`, so every
/// entry point no-ops unless running inside the packaged `.app`. This makes it
/// operator-verifiable in the shipped app and a safe no-op in dev/tests.
enum Notifier {
    /// True only inside a real app bundle — the guard that keeps `swift run` safe.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Ask once; the decision is cached by the system thereafter.
    static func requestAuthorizationIfNeeded() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
