import Foundation
import UserNotifications

/// Local notifications for sync failures — the thing that reaches someone who is
/// not currently looking at the app. The menu bar dot and the Status pane already
/// show a fatal error, but only to someone who happens to look; a scheduled
/// background sync spends nearly all its time with nobody looking.
@MainActor
final class UserNotifier {
    static let shared = UserNotifier()

    private var authorizationRequested = false

    /// Ask once per launch. Silent on denial — declining just means there is
    /// nothing to deliver a notification through; it never nags or blocks.
    func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyError(_ message: String) {
        post(title: "FindMySync+ — Sync Failed", body: message)
    }

    func notifyWarning(_ message: String) {
        post(title: "FindMySync+ — Sync Warning", body: message)
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // nil trigger delivers immediately; a fresh identifier each time means a
        // second error before the first notification is dismissed still shows up,
        // rather than being coalesced away as "the same" notification.
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
