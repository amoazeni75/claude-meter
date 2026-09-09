import Foundation
import UserNotifications

/// Threshold alerts.
///
/// The app exists so you don't have to keep looking at it, and a readout you
/// have to look at doesn't achieve that. This is the part that does.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {

    static let shared = Notifier()

    private var authorized = false
    private var asked = false

    /// Asked for once, the first time there is something to say — permission
    /// prompts out of nowhere on first launch are their own annoyance.
    func requestAuthorizationIfNeeded() {
        guard !asked else { return }
        asked = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async { self?.authorized = granted }
        }
    }

    func post(title: String, body: String, id: String) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// An accessory app is never "frontmost" in the usual sense, but say so
    /// explicitly rather than relying on that.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
