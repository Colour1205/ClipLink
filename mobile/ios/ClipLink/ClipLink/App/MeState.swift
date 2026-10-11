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
