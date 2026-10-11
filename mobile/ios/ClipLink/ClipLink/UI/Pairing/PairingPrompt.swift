import UIKit

/// The pairing request as a system alert - a modal over whatever is on
/// screen (a tab, the pairing sheet, the scanner, a rename sheet), not a page
/// of its own. UIKit's alert rather than SwiftUI's `.alert`, because a
/// SwiftUI alert can't be shown over a sheet its own view presented, and a
/// request can arrive at any moment now, not just while a sheet is up.
///
/// Trust or Ignore, and only those: Ignore closes this one request and
/// remembers nothing, so the device can ask again. Blocking is a deliberate
/// act on the Devices tab, not something to do by accident from a prompt.
@MainActor
enum PairingPrompt {
    private static var current: UIAlertController?

    static var isShowing: Bool { current != nil }

    /// Replaces any prompt already up. `onTrust` / `onIgnore` run once the
    /// person has answered; dismissing the prompt from code runs neither.
    static func show(title: String, message: String, onTrust: @escaping () -> Void, onIgnore: @escaping () -> Void) {
        dismiss()
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Ignore", style: .cancel) { _ in
            current = nil
            onIgnore()
        })
        let trust = UIAlertAction(title: "Trust", style: .default) { _ in
            current = nil
            onTrust()
        }
        alert.addAction(trust)
        alert.preferredAction = trust
        current = alert
        present(alert, attemptsLeft: 8)
    }

    /// The request is over (answered elsewhere, withdrawn, timed out, or the
    /// app is leaving the foreground).
    static func dismiss() {
        guard let alert = current else { return }
        current = nil
        if alert.presentingViewController != nil { alert.dismiss(animated: true) }
    }

    /// The top-most view controller can be mid-transition (a sheet closing as
    /// the request arrives); presenting then fails silently, so try again.
    private static func present(_ alert: UIAlertController, attemptsLeft: Int) {
        guard current === alert else { return } // answered or replaced meanwhile
        guard let top = topViewController(), !top.isBeingPresented, !top.isBeingDismissed else {
            guard attemptsLeft > 0 else {
                current = nil
                return
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                present(alert, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        top.present(alert, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first,
              var top = window.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
