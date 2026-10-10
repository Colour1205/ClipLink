import SwiftUI
import UIKit

// What the Devices tab and the device detail screen share: the one wording of
// a device's state, the blocked-card colours, the actions every surface
// (⋯ menu, long-press menu, swipe actions, detail screen) offers, and the
// confirmations those actions ask for.

// MARK: - Status

/// A device's state in one word-for-word wording, so the card, the detail
/// screen and VoiceOver can't drift apart.
enum DeviceStatus: Equatable {
    case connected
    /// Paired and heard from recently, but no connection is up.
    case pairedNearby
    /// Paired, and not heard from recently.
    case pairedOffline
    case nearby
    /// Nearby, with its own pairing screen open.
    case pairingOpen
    /// Not paired, and not heard from recently.
    case away
    case blocked

    init(_ row: DeviceRow) {
        if row.blocked {
            self = .blocked
        } else if row.connected {
            self = .connected
        } else if row.trusted {
            self = row.nearby ? .pairedNearby : .pairedOffline
        } else if !row.nearby {
            self = .away
        } else {
            self = row.pairing ? .pairingOpen : .nearby
        }
    }

    var text: String {
        switch self {
        case .connected: return "Connected"
        case .pairedNearby: return "Paired · Nearby"
        case .pairedOffline: return "Paired · Offline"
        case .nearby: return "Nearby"
        case .pairingOpen: return "Nearby — pairing mode open"
        case .away: return "Not nearby"
        case .blocked: return "Blocked"
        }
    }

    /// For VoiceOver: no "middle dot" or "em dash" read aloud.
    var spokenText: String {
        switch self {
        case .pairedNearby: return "Paired, nearby"
        case .pairedOffline: return "Paired, offline"
        case .pairingOpen: return "Nearby, pairing mode open"
        default: return text
        }
    }

    /// The colour of the status pill and (for connected) the card's status line.
    func tint(accent: Color) -> Color {
        switch self {
        case .connected: return Theme.connected
        case .pairedNearby, .nearby, .pairingOpen: return accent
        case .pairedOffline, .away: return Color(UIColor.secondaryLabel)
        case .blocked: return DevicesBlockedStyle.primary
        }
    }
}

extension DeviceRow {
    var status: DeviceStatus { DeviceStatus(self) }
}

// MARK: - Blocked style

/// The dark-gray treatment of a blocked device, the same in light and dark
/// mode: visibly lighter than a dark-mode card (~0.11), clearly dark in light
/// mode. Everything on it is light: white is 8:1 and the secondary grey 5:1
/// or better against either fill.
enum DevicesBlockedStyle {
    static let fillUIColor = UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(white: 0.26, alpha: 1) : UIColor(white: 0.30, alpha: 1)
    }
    static let fill = Color(fillUIColor)
    static let primary = Color.white
    static let secondary = Color(white: 0.82)
    /// Tile and pill fills on the dark gray.
    static let tileFill = Color.white.opacity(0.16)
    /// A swipe action's fill under a white label.
    static let swipeFill = Color(white: 0.28)
}

/// Content that sits on a blocked card is always drawn for a dark surface.
private struct DevicesBlockedAppearance: ViewModifier {
    let active: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.environment(\.colorScheme, active ? .dark : scheme)
    }
}

extension View {
    func devicesBlockedAppearance(_ active: Bool) -> some View {
        modifier(DevicesBlockedAppearance(active: active))
    }

    /// A list row that is a card of its own, like a Synced card: the row is
    /// clear and unseparated and the card draws its own fill. "Card
    /// transparency" then fades exactly that fill, the way it does on every
    /// Synced card, instead of relying on the list's row background.
    func devicesCardRow() -> some View {
        listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .meTableClear()
    }
}

// MARK: - Time

enum DevicesRelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        return f
    }()

    static func string(for date: Date) -> String {
        let now = Date()
        if now.timeIntervalSince(date) < 10 { return "just now" }
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    /// The same, for a value on its own ("Just now", "3 hours ago").
    static func sentence(for date: Date) -> String {
        let text = string(for: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

// MARK: - Rename

struct DevicesRenameTarget: Identifiable {
    var id: String { deviceId }
    let deviceId: String
    let current: String
    /// What the row shows without a nickname: the device's own name, else
    /// its short label.
    let fallback: String
}

/// iOS 15 alerts can't host text fields, so renaming is a small sheet.
struct DevicesRenameSheet: View {
    let target: DevicesRenameTarget
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var focused: Bool

    init(target: DevicesRenameTarget, onSave: @escaping (String) -> Void) {
        self.target = target
        self.onSave = onSave
        _name = State(initialValue: target.current)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(
                    footer: Text("Only this \(ThisDeviceNoun.current) uses this name. Leave it empty to show \(target.fallback).")
                ) {
                    TextField(target.fallback, text: $name)
                        .focused($focused)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                        .submitLabel(.done)
                        .onSubmit(save)
                }
            }
            .navigationTitle("Rename Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
            .onAppear {
                // Sheets on iOS 15 ignore focus set before they finish presenting.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { focused = true }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func save() {
        onSave(name)
        dismiss()
    }
}

// MARK: - Actions

/// What the user can do to a device, in one place: the ⋯ menu, the long-press
/// menu, the swipe actions and the detail screen all call these, so haptics,
/// toasts and wording are the same everywhere.
@MainActor
struct DeviceActions {
    let model: AppModel
    let haptics: Bool

    func name(_ row: DeviceRow) -> String { model.name(for: row.deviceId) }

    func tap() { Haptics.tap(haptics) }

    func trust(_ row: DeviceRow) {
        Haptics.success(haptics)
        model.trust(row)
        model.showToast("Trusted \(name(row)). It syncs once it trusts this \(ThisDeviceNoun.current) too.")
    }

    func remove(_ row: DeviceRow) {
        Haptics.tap(haptics)
        model.untrust(row)
    }

    // No toasts for these two: the card itself moves into (or out of) the
    // dark-gray Blocked section.
    func block(_ row: DeviceRow) {
        Haptics.tap(haptics)
        model.block(row)
    }

    func unblock(_ row: DeviceRow) {
        Haptics.tap(haptics)
        model.unblock(row)
    }

    func copyDeviceID(_ row: DeviceRow) {
        Haptics.tap(haptics)
        model.clipboard.copyText(row.deviceId)
        model.showToast("Device ID copied.")
    }

    func copyAddress(_ address: String) {
        Haptics.tap(haptics)
        model.clipboard.copyText(address)
        model.showToast("Address copied.")
    }

    func renameTarget(_ row: DeviceRow) -> DevicesRenameTarget {
        DevicesRenameTarget(
            deviceId: row.deviceId,
            current: model.snapshot.nicknames[row.deviceId] ?? "",
            fallback: model.snapshot.deviceNames[row.deviceId] ?? DeviceLabel.short(row.deviceId)
        )
    }
}

// MARK: - Menu items

/// The one set of actions a device offers, for the ⋯ menu and the long-press
/// menu alike. Remove and Block ask for confirmation through `onRemove` /
/// `onBlock`; the owner of the confirmation dialog handles those.
struct DeviceMenuItems: View {
    let row: DeviceRow
    let actions: DeviceActions
    let onRename: () -> Void
    let onRemove: () -> Void
    let onBlock: () -> Void

    var body: some View {
        if row.blocked {
            Button {
                actions.unblock(row)
            } label: {
                Label("Unblock", systemImage: "hand.raised.slash")
            }
        } else {
            Button {
                actions.tap()
                onRename()
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
        }
        if !row.trusted && !row.blocked {
            Button {
                actions.trust(row)
            } label: {
                Label("Trust", systemImage: "checkmark.shield")
            }
        }
        Button {
            actions.copyDeviceID(row)
        } label: {
            Label("Copy Device ID", systemImage: "doc.on.doc")
        }
        if row.connected, let address = row.connectionAddress {
            Button {
                actions.copyAddress(address)
            } label: {
                Label("Copy Address", systemImage: "network")
            }
        }
        if row.trusted {
            Divider()
            Button(role: .destructive) {
                actions.tap()
                onRemove()
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        if !row.blocked {
            if !row.trusted { Divider() }
            Button(role: .destructive) {
                actions.tap()
                onBlock()
            } label: {
                Label("Block Device", systemImage: "hand.raised")
            }
        }
    }
}

// MARK: - Confirmations

/// A Remove or Block waiting for the user's answer.
struct DevicePending: Identifiable, Equatable {
    enum Kind: Equatable { case remove, block }

    let kind: Kind
    let row: DeviceRow

    var id: String { "\(kind)-\(row.deviceId)" }
}

private struct DeviceConfirmation: ViewModifier {
    @Binding var pending: DevicePending?
    let actions: DeviceActions

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            titleVisibility: .visible,
            presenting: pending
        ) { item in
            switch item.kind {
            case .remove:
                Button("Remove", role: .destructive) { actions.remove(item.row) }
            case .block:
                Button("Block", role: .destructive) { actions.block(item.row) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            switch item.kind {
            case .remove:
                Text("It will no longer be able to sync with this \(ThisDeviceNoun.current). You can pair again later.")
            case .block:
                Text("It won't be able to send pairing requests, and ClipLink will never connect to it. You can unblock it here at any time.")
            }
        }
    }

    private var title: String {
        guard let pending else { return "Are You Sure?" }
        let name = actions.name(pending.row)
        switch pending.kind {
        case .remove: return "Remove \(name)?"
        case .block: return "Block \(name)?"
        }
    }
}

extension View {
    /// The Remove / Block confirmations. One dialog per view; keep it off the
    /// view that carries a `.sheet` (several presentations on one view is an
    /// iOS 15 bug).
    func deviceConfirmation(_ pending: Binding<DevicePending?>, actions: DeviceActions) -> some View {
        modifier(DeviceConfirmation(pending: pending, actions: actions))
    }
}

// MARK: - Icon tile

/// Rounded tile with the device glyph and a status dot in its corner. There
/// is no device type on the wire, so every peer gets the desktop glyph.
struct DevicesIconTile: View {
    let status: DeviceStatus
    let trusted: Bool
    /// The accent fill (AccentTheme.fill): it sits under a white glyph.
    let accent: Color
    var baseSize: CGFloat = 40

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let size = baseSize * min(scale, 1.7)
        let blocked = status == .blocked
        Image(systemName: "desktopcomputer")
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundColor(blocked ? DevicesBlockedStyle.secondary : (trusted ? .white : Color(UIColor.secondaryLabel)))
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(blocked ? DevicesBlockedStyle.tileFill : (trusted ? accent : Color(UIColor.tertiarySystemFill)))
            )
            .overlay(alignment: .bottomTrailing) { badge(size: size, blocked: blocked) }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func badge(size: CGFloat, blocked: Bool) -> some View {
        let dot = max(12, size * 0.3)
        if blocked {
            Image(systemName: "nosign")
                .font(.system(size: dot, weight: .bold))
                .foregroundColor(Color(red: 1.0, green: 0.56, blue: 0.52))
                .background(Circle().fill(DevicesBlockedStyle.fill).padding(1))
                .offset(x: 3, y: 3)
        } else {
            Circle()
                .fill(status == .connected ? Theme.connected : Color(UIColor.systemGray3))
                .frame(width: dot, height: dot)
                .overlay(Circle().strokeBorder(Color(Theme.card), lineWidth: 2))
                .offset(x: 3, y: 3)
                .animation(.easeInOut(duration: 0.25), value: status == .connected)
        }
    }
}
