#if DEBUG
import Foundation

/// A made-up engine snapshot, for looking at UI states that need other
/// devices (the Simulator has none): launch a Debug build with
/// `-ClipLinkDebugFixtures <kind>` - `devices`, `request` (devices plus a
/// pairing request), `stack` (devices plus a stack of synced items) or `empty`. The engine's own updates are then ignored.
/// Compiled out of Release builds.
enum DebugFixtures {
    static func snapshot(_ kind: String) -> EngineSnapshot {
        var s = EngineSnapshot()
        s.ownDeviceId = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEfixtureOwnDeviceIdAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
        s.network.running = true
        s.network.listening = true
        s.network.lanAddress = "192.168.1.77"
        s.localAddresses = ["192.168.1.77"]
        guard kind != "empty" else { return s }

        let now = Date()
        func id(_ n: String) -> String { "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE\(n)fixtureDeviceId\(String(repeating: "A", count: 40))==" }
        let office = id("Office"), phone = id("Phone"), laptop = id("Laptop"), stranger = id("Stranger"), spam = id("Spam")

        s.devices = [
            DeviceRow(
                deviceId: office, name: "Office PC", trusted: true, connected: true,
                addresses: ["192.168.1.20", "100.101.102.103"], lastSeen: now, nearby: true,
                blocked: false, connectionAddress: "192.168.1.20",
                addressDetails: [
                    DeviceAddress(ip: "192.168.1.20", inUse: true, sources: [.heard, .reached, .stored], lastSeen: now),
                    DeviceAddress(ip: "100.101.102.103", inUse: false, sources: [.advertised], lastSeen: nil),
                ]
            ),
            DeviceRow(
                deviceId: phone, name: "Pixel 9", trusted: true, connected: false,
                addresses: ["192.168.1.34"], lastSeen: now.addingTimeInterval(-12), nearby: true,
                blocked: false, connectionAddress: nil,
                addressDetails: [DeviceAddress(ip: "192.168.1.34", inUse: false, sources: [.heard, .stored], lastSeen: now.addingTimeInterval(-12))]
            ),
            DeviceRow(
                deviceId: laptop, name: "Old Laptop", trusted: true, connected: false,
                addresses: ["192.168.1.51"], lastSeen: now.addingTimeInterval(-3 * 3600), nearby: false,
                blocked: false, connectionAddress: nil,
                addressDetails: [DeviceAddress(ip: "192.168.1.51", inUse: false, sources: [.stored], lastSeen: nil)]
            ),
            DeviceRow(
                deviceId: stranger, name: "Guest Tablet", trusted: false, connected: false,
                addresses: ["192.168.1.88"], lastSeen: now, nearby: true,
                blocked: false, connectionAddress: nil,
                addressDetails: [DeviceAddress(ip: "192.168.1.88", inUse: false, sources: [.heard], lastSeen: now)]
            ),
            DeviceRow(
                deviceId: spam, name: "Spammy Phone", trusted: false, connected: false,
                addresses: [], lastSeen: nil, nearby: false,
                blocked: true, connectionAddress: nil, addressDetails: []
            ),
        ]
        s.connectedCount = 1
        s.deviceNames = [office: "Office PC", phone: "Pixel 9", laptop: "Old Laptop", stranger: "Guest Tablet", spam: "Spammy Phone"]
        s.deviceName = "Chuck's iPhone"
        if kind == "request" {
            s.pairingRequests = [PairingRequest(deviceId: stranger, address: "192.168.1.88", name: "Guest Tablet")]
        }
        if kind == "stack" {
            // One batch from one device: a stack card (the newest in front,
            // "+6" behind it) over an ordinary card.
            let texts = [
                "Pixel_7_Pro_API_31",
                "& \"$env:LOCALAPPDATA\\Android\\Sdk\\emulator\\emulator.exe\" -list-avds",
                "Skip to main content Honest and experienced BMW mechanic in Toronto? : r/askTO",
                "https://www.reddit.com/r/askTO/comments/17krowf/",
                "Hi, this is Chuck. Can I get a quote for parts and labour on a 2016 BMW 328i xDrive?",
                "Toronto folks with a 100k km BMW, where's the best place in the city for a change?",
                "A short one",
            ]
            let iso = ISO8601DateFormatter()
            var items: [SyncedItem] = []
            for (index, text) in texts.enumerated() {
                let date = now.addingTimeInterval(-Double(index) * 90 - 20)
                let entry = ClipboardEntry(content: text, type: Wire.EntryType.text, deviceId: office, timestamp: iso.string(from: date))
                items.append(SyncedItem(
                    id: HistoryStore.identity(of: entry), entry: entry, isOwn: false, kind: text.hasPrefix("http") ? .link : .text,
                    filePayload: nil, fileAvailable: true, date: date, sourceLabel: "Office PC"
                ))
            }
            let own = ClipboardEntry(content: "Copied on this iPhone", type: Wire.EntryType.text, deviceId: s.ownDeviceId, timestamp: iso.string(from: now.addingTimeInterval(-3600)))
            items.append(SyncedItem(
                id: HistoryStore.identity(of: own), entry: own, isOwn: true, kind: .text,
                filePayload: nil, fileAvailable: true, date: now.addingTimeInterval(-3600), sourceLabel: "This device"
            ))
            s.items = items
            s.blocks = [BatchGroup(id: "fixture-batch", memberIDs: Array(items.prefix(texts.count).map(\.id)), frontID: items[0].id)]
        }
        return s
    }

    // The fake snapshot reacts to the same actions the real engine would
    // take, so the UI can be exercised without it (and without writing fake
    // devices into the app's real trust store).

    static func rebuild(_ id: String, in s: inout EngineSnapshot, _ change: (DeviceRow) -> DeviceRow?) {
        s.devices = s.devices.compactMap { $0.deviceId == id ? change($0) : $0 }
        s.connectedCount = s.devices.filter(\.connected).count
    }

    private static func copy(_ r: DeviceRow, trusted: Bool? = nil, connected: Bool? = nil, blocked: Bool? = nil) -> DeviceRow {
        let isConnected = connected ?? r.connected
        return DeviceRow(
            deviceId: r.deviceId, name: r.name, trusted: trusted ?? r.trusted, connected: isConnected,
            addresses: r.addresses, lastSeen: r.lastSeen, nearby: r.nearby,
            blocked: blocked ?? r.blocked, connectionAddress: isConnected ? r.connectionAddress : nil,
            addressDetails: r.addressDetails.map { DeviceAddress(ip: $0.ip, inUse: isConnected && $0.inUse, sources: $0.sources, lastSeen: $0.lastSeen) }
        )
    }

    static func trust(_ id: String, in s: inout EngineSnapshot) { rebuild(id, in: &s) { copy($0, trusted: true) } }
    static func untrust(_ id: String, in s: inout EngineSnapshot) { rebuild(id, in: &s) { $0.nearby ? copy($0, trusted: false, connected: false) : nil } }
    static func block(_ id: String, in s: inout EngineSnapshot) { rebuild(id, in: &s) { copy($0, trusted: false, connected: false, blocked: true) } }
    static func unblock(_ id: String, in s: inout EngineSnapshot) { rebuild(id, in: &s) { $0.nearby ? copy($0, blocked: false) : nil } }
    static func answer(_ id: String, in s: inout EngineSnapshot) { s.pairingRequests.removeAll { $0.deviceId == id } }
}
#endif
