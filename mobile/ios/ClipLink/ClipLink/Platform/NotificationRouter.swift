import UIKit
import UserNotifications

/// Receives notification events: decides how one is shown while ClipLink is
/// open, and runs a notification's Trust / Ignore buttons.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    /// While ClipLink is open a pairing request is asked in a modal on screen
    /// (see PairingPromptPresenter), not as a banner on top of it.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.content.categoryIdentifier == Notifier.pairingCategory {
            completionHandler([])
        } else {
            completionHandler([.banner])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        Task { @MainActor in
            await AppModel.shared.handleNotificationResponse(actionIdentifier: action, userInfo: info)
            completionHandler()
        }
    }
}
