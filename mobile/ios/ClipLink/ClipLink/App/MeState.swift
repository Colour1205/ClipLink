import Combine
import Foundation

/// The few engine fields the Me tab shows. The Me list watches this instead of
/// the whole app model: the engine's snapshot changes with every beacon,
/// transfer and activity-log line, and rebuilding every row of the Me list for
/// each of those made it stutter while scrolling on older phones (iPhone X).
struct MeSnapshot: Equatable {
    var ownDeviceId = ""
    var deviceName = ""
    var localAddresses: [String] = []
    var tailscaleIP = ""
    var network = NetworkStatus()
    var sweeping = false
    var hasPassphrase = false
    var hasItems = false
    var hardwareBacked = false
    /// Me › Device Name: the user's setting and the OS default.
    var deviceNameOverride = ""
    var systemDeviceName = ""
}

/// Republishes only when one of those fields actually changes.
@MainActor
final class MeStore: ObservableObject {
    @Published private(set) var value = MeSnapshot()

    func update(from snapshot: EngineSnapshot) {
        var next = value
        next.ownDeviceId = snapshot.ownDeviceId
        next.deviceName = snapshot.deviceName
        next.localAddresses = snapshot.localAddresses
        next.tailscaleIP = snapshot.tailscaleIP
        next.network = snapshot.network
        next.sweeping = snapshot.sweeping
        next.hasPassphrase = snapshot.hasPassphrase
        next.hasItems = !snapshot.items.isEmpty
        next.deviceNameOverride = snapshot.deviceNameOverride
        next.systemDeviceName = snapshot.systemDeviceName
        apply(next)
    }

    func setHardwareBacked(_ backed: Bool) {
        var next = value
        next.hardwareBacked = backed
        apply(next)
    }

    private func apply(_ next: MeSnapshot) {
        if next != value { value = next }
    }
}

/// The activity log's length, on its own: it grows with every engine event and
/// only a small badge in the Me list shows it, so only that badge redraws.
@MainActor
final class LogCountStore: ObservableObject {
    @Published private(set) var count = 0

    func update(_ count: Int) {
        if count != self.count { self.count = count }
    }
}

/// The activity log itself, for Me › Activity Log: republished only when a
/// line is added, not with every other change of the snapshot.
@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var lines: [LogLine] = []

    func update(_ lines: [LogLine]) {
        if lines != self.lines { self.lines = lines }
    }
}

/// What Me › Diagnostics shows of the engine.
struct DiagnosticsState: Equatable {
    var network = NetworkStatus()
    var connectedCount = 0
    var trustedCount = 0
    var itemCount = 0
    var hasPassphrase = false
}

@MainActor
final class DiagnosticsStore: ObservableObject {
    @Published private(set) var value = DiagnosticsState()

    func update(from snapshot: EngineSnapshot) {
        let next = DiagnosticsState(network: snapshot.network, connectedCount: snapshot.connectedCount,
                                    trustedCount: snapshot.devices.filter(\.trusted).count,
                                    itemCount: snapshot.items.count, hasPassphrase: snapshot.hasPassphrase)
        if next != value { value = next }
    }
}

/// What the pairing sheet shows of the engine: this device's code and
/// addresses, and whether Local Network access is off.
struct PairingState: Equatable {
    var payload = ""
    var localNetworkDenied = false
    var lanAddress: String?
    var tailscaleIP = ""
}

@MainActor
final class PairingStore: ObservableObject {
    @Published private(set) var value = PairingState()

    func update(from snapshot: EngineSnapshot) {
        let next = PairingState(payload: snapshot.pairingPayload, localNetworkDenied: snapshot.network.localNetwork == .denied,
                                lanAddress: snapshot.network.lanAddress, tailscaleIP: snapshot.tailscaleIP)
        if next != value { value = next }
    }
}

/// The app model's own progress flags (not the engine's): a pairing dial and
/// its outcome, and a passcode being set. The pairing sheet and Me › Passcode
/// watch this.
struct ProgressState: Equatable {
    var pairStatus: String?
    var pairInProgress = false
    var passcodeBusy = false
}

@MainActor
final class ProgressStore: ObservableObject {
    @Published private(set) var value = ProgressState()

    func update(_ change: (inout ProgressState) -> Void) {
        var next = value
        change(&next)
        if next != value { value = next }
    }
}

/// What the app's root view shows: the startup error, or the tabs and the
/// pairing sheet. The root watches this instead of the whole app model, so a
/// snapshot no longer re-runs the tab view, its tab items and the sheet.
struct RootState: Equatable {
    var startupError: String?
    var pairingPresented = false
}

@MainActor
final class RootStore: ObservableObject {
    @Published private(set) var value = RootState()

    func update(_ change: (inout RootState) -> Void) {
        var next = value
        change(&next)
        if next != value { value = next }
    }
}

/// What the Synced tab lists. The tab watches this instead of the whole app
/// model, as the Me tab does (see MeStore): a snapshot comes with every beacon
/// heard, every log line and four times a second during a transfer, and each
/// one worked out the whole list again - every card, stack and masonry
/// estimate - while it scrolled or animated.
struct SyncedState: Equatable {
    var items: [SyncedItem] = []
    var blocks: [BatchGroup] = []
    var connectedCount = 0
    var network = NetworkStatus()
}

@MainActor
final class SyncedStore: ObservableObject {
    @Published private(set) var value = SyncedState()

    func update(from snapshot: EngineSnapshot) {
        let next = SyncedState(items: snapshot.items, blocks: snapshot.blocks, connectedCount: snapshot.connectedCount, network: snapshot.network)
        if next != value { value = next }
    }
}

/// Incoming file transfers, keyed by lowercase hash: only the cards of files
/// still on their way watch it (see SyncedTransfersReader).
@MainActor
final class TransfersStore: ObservableObject {
    @Published private(set) var value: [String: TransferProgress] = [:]

    func update(_ transfers: [String: TransferProgress]) {
        if transfers != value { value = transfers }
    }
}

/// What the Devices tab lists. A tab stays alive behind the others, so while
/// it watched the whole model it redrew with every log line and four times a
/// second during a transfer, on screen or not.
struct DevicesState: Equatable {
    var devices: [DeviceRow] = []
    var connectedCount = 0
    var network = NetworkStatus()
    var sweeping = false
    var tailscaleIP = ""
}

@MainActor
final class DevicesStore: ObservableObject {
    @Published private(set) var value = DevicesState()

    func update(from snapshot: EngineSnapshot) {
        let next = DevicesState(devices: snapshot.devices, connectedCount: snapshot.connectedCount, network: snapshot.network,
                                sweeping: snapshot.sweeping, tailscaleIP: snapshot.tailscaleIP)
        if next != value { value = next }
    }
}

/// The "New item" hint, on its own: the dock watches it.
@MainActor
final class ClipboardHintStore: ObservableObject {
    @Published private(set) var visible = false

    func set(_ visible: Bool) {
        if visible != self.visible { self.visible = visible }
    }
}

/// The toast on screen, on its own: the toast window watches it.
@MainActor
final class ToastStore: ObservableObject {
    @Published var toast: Toast?
}
