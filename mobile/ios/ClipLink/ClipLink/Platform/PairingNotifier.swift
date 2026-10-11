import UIKit
import UserNotifications

/// A pairing request as a notification, with Trust and Ignore on it, for when
/// the app is running but not the active scene - the app switcher, Control
/// Center, a system prompt over it. (In front, the request is a modal alert
/// instead: see PairingPrompt.)
///
/// This is as far as iOS lets it go. An app that is suspended has no sockets:
/// a device on the network can't reach it, so there is no request to be told
/// about until the app is open again - waking it for that would take a push
/// from a server, and this app has none. The same limit is why a request
/// can't be held across the app going to the background.
///
/// Trust needs the device unlocked (`authenticationRequired`): a stranger's
/// request must not be answerable from a lock screen by whoever picked the
/// phone up. Ignore turns the request away and remembers nothing - the
/// device can ask again; blocking it is a deliberate act on the Devices tab.
final class PairingNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PairingNotifier()

    private static let categoryID = "io.uaena.ClipLink.pairingRequest"
    private static let trustActionID = "io.uaena.ClipLink.pairing.trust"
    private static let ignoreActionID = "io.uaena.ClipLink.pairing.ignore"
    /// One request is held at a time, so one notification: a new one replaces it.
    private static let notificationID = "pairing-request"
    private static let deviceIDKey = "deviceId"

    /// Before launch finishes: the delegate has to be in place by then to
    /// receive the response to a notification's button.
    static func register() {
        let trust = UNNotificationAction(identifier: trustActionID, title: "Trust", options: [.authenticationRequired])
        let ignore = UNNotificationAction(identifier: ignoreActionID, title: "Ignore", options: [])
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [trust, ignore],
            intentIdentifiers: [],
            options: []
        )
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        center.delegate = shared
    }

    /// Asks for notification permission the first time pairing comes up -
    /// when the person is about to pair and can see why - instead of at launch.
    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// `who` is already worded for the person ("Name (Device AB12·CD34)").
    static func post(deviceId: String, who: String) {
        let content = UNMutableNotificationContent()
        content.title = "Pairing request"
        content.body = "\(who) wants to pair with this \(ThisDeviceNoun.current)."
        content.categoryIdentifier = categoryID
        content.threadIdentifier = "pairing"
        content.sound = .default
        content.userInfo = [deviceIDKey: deviceId]
        let request = UNNotificationRequest(identifier: notificationID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// The request was answered, withdrawn or timed out: whatever is on the
    /// lock screen or in Notification Center for it should go.
    static func clear() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [notificationID])
        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        DispatchQueue.main.async {
            // In front, the alert is the prompt (and "new item" notices stay
            // out of the way, as they always have); a banner is for an app
            // that is running but not the one being looked at.
            let isPairing = notification.request.content.categoryIdentifier == Self.categoryID
            let front = MainActor.assumeIsolated { AppModel.shared.isFrontmost }
            completionHandler(isPairing && !front ? [.banner, .list, .sound] : [])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let deviceId = response.notification.request.content.userInfo[Self.deviceIDKey] as? String
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            // Tapping the notification itself just opens the app, where the
            // prompt is waiting; only its two buttons answer it.
            switch action {
            case Self.trustActionID:
                MainActor.assumeIsolated { AppModel.shared.answerPairing(trust: true, expecting: deviceId) }
            case Self.ignoreActionID:
                MainActor.assumeIsolated { AppModel.shared.answerPairing(trust: false, expecting: deviceId) }
            default:
                break
            }
            completionHandler()
        }
    }
}
