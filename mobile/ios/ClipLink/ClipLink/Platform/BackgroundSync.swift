import BackgroundTasks
import UIKit
import UserNotifications

/// Background App Refresh for ClipLink - something neither the Android nor the
/// HarmonyOS port can do (Android only with a foreground service; HarmonyOS
/// not at all).
///
/// iOS decides WHEN these run (typically a few times a day, weighted by how
/// often the app is used); each run gets roughly 30 s for a refresh task and
/// longer for a processing task. In that window the engine comes up, reaches
/// paired devices, pulls their history (and any pending file bytes), and
/// shuts down again. Nothing keeps a socket open in the background - iOS
/// doesn't allow that.
enum BackgroundSync {
    static let refreshTaskID = "io.uaena.ClipLink.refresh"
    static let processingTaskID = "io.uaena.ClipLink.sync"

    /// Must run before application(_:didFinishLaunchingWithOptions:) returns.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            handle(task, budget: 25)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingTaskID, using: nil) { task in
            handle(task, budget: 170)
        }
    }

    /// Called whenever the app goes to the background.
    static func schedule(enabled: Bool, hasPendingFiles: Bool) {
        guard enabled else {
            BGTaskScheduler.shared.cancelAllTaskRequests()
            return
        }
        let refresh = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(refresh)

        // A longer window (usually while charging, on Wi-Fi) to finish file
        // downloads that didn't complete while the app was open.
        if hasPendingFiles {
            let processing = BGProcessingTaskRequest(identifier: processingTaskID)
            processing.requiresNetworkConnectivity = true
            processing.requiresExternalPower = false
            processing.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
            try? BGTaskScheduler.shared.submit(processing)
        }
    }

    private static func handle(_ task: BGTask, budget: TimeInterval) {
        DispatchQueue.main.async {
            let model = AppModel.shared
            // Keep the chain going: the next refresh is scheduled now, not
            // only when the app is next backgrounded.
            schedule(enabled: model.settings.backgroundRefresh, hasPendingFiles: false)
            // Launched into the background before the first unlock, the
            // Keychain was locked; it may not be any more.
            model.retryStartup()
            guard model.settings.backgroundRefresh, let engine = model.engine else {
                task.setTaskCompleted(success: true)
                return
            }
            // Main queue only. The task is completed exactly once: by the
            // round's own completion, or by the backstop after expiry.
            var finished = false
            var expired = false
            task.expirationHandler = {
                DispatchQueue.main.async {
                    guard !finished else { return }
                    expired = true
                    // Opened meanwhile: the round has handed the node to the
                    // foreground app (its poll ends without tearing down).
                    if !model.isActive { engine.enterBackground(grace: 0) }
                    // The teardown lets the poll complete the task within about
                    // half a second; don't let a busy engine queue stretch that.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        guard !finished else { return }
                        finished = true
                        task.setTaskCompleted(success: false)
                    }
                }
            }
            engine.runBackgroundSync(budget: budget) { received in
                guard !finished else { return }
                finished = true
                model.backgroundSyncFinished(received: received)
                task.setTaskCompleted(success: !expired)
            }
        }
    }
}

/// Local notifications: items that arrive while ClipLink is in the
/// background (opt-in), and pairing requests that can't be asked on screen.
enum Notifier {
    static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: Pairing requests

    static let pairingCategory = "io.uaena.ClipLink.pairingRequest"
    static let trustAction = "io.uaena.ClipLink.trust"
    static let ignoreAction = "io.uaena.ClipLink.ignore"
    static let requestIdKey = "deviceId"
    static let requestAddressKey = "address"
    static let requestNameKey = "name"

    /// Trust or Ignore - never "deny": the device may still ask again later
    /// (blocking it is a deliberate step in the Devices tab). Trust needs
    /// the phone unlocked: it's a security decision.
    static func registerCategories() {
        let trust = UNNotificationAction(identifier: trustAction, title: "Trust", options: [.authenticationRequired])
        let ignore = UNNotificationAction(identifier: ignoreAction, title: "Ignore", options: [])
        let category = UNNotificationCategory(
            identifier: pairingCategory,
            actions: [trust, ignore],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "Pairing request",
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Asks permission the first time someone opens the pairing screen - the
    /// moment they expect a request - and never again if they said no.
    static func requestPairingAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    static func notifyPairingRequest(_ request: PairingRequest, name: String) {
        let code = DeviceLabel.short(request.deviceId)
        let content = UNMutableNotificationContent()
        content.title = "Pairing Request"
        content.body = name == code
            ? "\(code) wants to pair with this \(ThisDeviceNoun.current)."
            : "\(name) (\(code)) wants to pair with this \(ThisDeviceNoun.current)."
        content.categoryIdentifier = pairingCategory
        content.threadIdentifier = "pairing"
        content.sound = .default
        // What the Trust button needs once the connection is long gone.
        content.userInfo = [requestIdKey: request.deviceId, requestAddressKey: request.address ?? "", requestNameKey: request.name ?? ""]
        // One per device: a repeat replaces the earlier one.
        let notification = UNNotificationRequest(identifier: "pairing-\(request.deviceId)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(notification)
    }

    static func removePairingNotification(deviceId: String) {
        let identifier = "pairing-\(deviceId)"
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    // MARK: Synced items

    static func notify(_ entries: [ClipboardEntry], name: (String) -> String) {
        guard let newest = entries.first else { return }
        let content = UNMutableNotificationContent()
        content.title = entries.count == 1 ? "New from \(name(newest.deviceId))" : "\(entries.count) new items synced"
        // The body can end up on the lock screen, in Notification Center and
        // on a paired Watch: no keys or tokens, no full links, and only a
        // short first line of text.
        switch SyncedItem.kind(for: newest) {
        case .opaque: content.body = "Key or token"
        case .link: content.body = URL(string: newest.content.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "Link"
        case .text:
            let firstLine = newest.content.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            content.body = firstLine.isEmpty ? "Text" : firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
        case .image: content.body = "Image"
        case .file: content.body = FilePayload.parse(newest.content)?.fileName ?? "File"
        }
        content.sound = nil
        content.threadIdentifier = "synced"
        let request = UNNotificationRequest(identifier: "synced-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
