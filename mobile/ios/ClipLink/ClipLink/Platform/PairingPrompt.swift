import UIKit

/// The prompt for a pairing request: a system alert, shown over whatever is
/// on screen - a tab, the pairing sheet, the QR scanner, Quick Look. UIKit's
/// alert is the OS-level modal for this; it needs no page of its own, and
/// (unlike a SwiftUI `.alert` on the root view) can be raised over a sheet.
///
/// Fed the current list of requests whenever it changes; it keeps exactly
/// one alert up, for the oldest, and takes it down again when that request
/// goes away (the other device gave up, or it was answered elsewhere).
@MainActor
final class PairingPromptPresenter {
    var onTrust: ((PairingRequest) -> Void)?
    var onIgnore: ((PairingRequest) -> Void)?
    var nameFor: (String) -> String = { DeviceLabel.short($0) }

    private var shownID: String?
    private weak var alert: UIAlertController?

    /// `active` is false while ClipLink isn't on screen: nothing can be shown
    /// then (a notification asks instead).
    func update(_ requests: [PairingRequest], active: Bool) {
        guard active, let request = requests.first else {
            dismiss()
            return
        }
        // Already up for this one.
        if shownID == request.id, alert != nil { return }
        dismiss()
        present(request)
    }

    private func present(_ request: PairingRequest) {
        let (title, message) = Self.text(for: request, name: nameFor(request.deviceId))
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        // Ignore is the bold default: the safe answer is the easy one.
        let ignore = UIAlertAction(title: "Ignore", style: .cancel) { [weak self] _ in
            self?.finish(request)
            self?.onIgnore?(request)
        }
        let trust = UIAlertAction(title: "Trust", style: .default) { [weak self] _ in
            self?.finish(request)
            self?.onTrust?(request)
        }
        alert.addAction(trust)
        alert.addAction(ignore)
        self.alert = alert
        shownID = request.id
        SyncedPresenter.present(alert)
    }

    private func finish(_ request: PairingRequest) {
        guard shownID == request.id else { return }
        shownID = nil
        alert = nil
    }

    private func dismiss() {
        shownID = nil
        guard let alert else { return }
        self.alert = nil
        if alert.presentingViewController != nil { alert.dismiss(animated: true) }
    }

    /// The name is whatever the other device chose, so its short code goes
    /// beside it - a copied name can't pass for a device you know - and the
    /// address when known. The code is the one in Me on that device.
    static func text(for request: PairingRequest, name: String) -> (title: String, message: String) {
        let code = DeviceLabel.short(request.deviceId)
        let who = name == code ? code : "\(name) (\(code))"
        let at = request.address.map { " at \($0)" } ?? ""
        let noun = ThisDeviceNoun.current
        if request.initiatedByUs {
            return ("Pair with \(name)?",
                    "You reached \(who)\(at). Trust it to sync clipboards with this \(noun). Only continue if it's the device you meant.")
        }
        return ("Pairing Request",
                "\(who)\(at) wants to pair with this \(noun).\n\nOnly trust it if you recognize it — its code should match the one in Me on that device.")
    }
}
