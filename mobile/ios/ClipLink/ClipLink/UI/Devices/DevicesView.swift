import SwiftUI
import UIKit

/// The Devices tab: paired devices, devices discovered nearby, and the state
/// of the local network, in an inset-grouped list. Pull to refresh re-runs
/// discovery; "+" opens the pairing sheet (which is pairing mode).
struct DevicesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    @State private var renaming: DevicesRenameTarget?
    /// A Remove or Block waiting for its confirmation.
    @State private var confirming: DevicesConfirmation?
    /// One programmatic link for every card, like the Synced tab's: a link
    /// inside a row is torn down with it whenever the list reorders.
    @State private var detailID = ""
    @State private var detailActive = false

    var body: some View {
        NavigationView {
            list
                .navigationTitle("Devices")
                .background(
                    NavigationLink(destination: DeviceDetailView(deviceId: detailID), isActive: $detailActive) {
                        EmptyView()
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: openPairing) {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Pair a Device")
                    }
                }
        }
        .navigationViewStyle(.stack)
        .sheet(item: $renaming) { target in
            DevicesRenameSheet(target: target) { name in
                model.rename(target.deviceId, to: name)
            }
        }
    }

    // MARK: - List

    private var paired: [DeviceRow] { model.snapshot.devices.filter { $0.trusted && !$0.blocked } }
    private var nearby: [DeviceRow] { model.snapshot.devices.filter { !$0.trusted && !$0.blocked } }
    private var blocked: [DeviceRow] { model.snapshot.devices.filter(\.blocked) }

    private var list: some View {
        List {
            Section {
                DevicesStatusRow(snapshot: model.snapshot)
                    .meRow(transparency: settings.cardTransparency)
                if model.snapshot.network.localNetwork == .denied {
                    DevicesLocalNetworkWarning()
                        .meRow(transparency: settings.cardTransparency)
                }
            }

            if paired.isEmpty && nearby.isEmpty && blocked.isEmpty {
                Section {
                    VStack(spacing: 4) {
                        EmptyStateView(
                            systemImage: "laptopcomputer.and.iphone",
                            title: "No Devices Yet",
                            message: "Devices on the same Wi-Fi show up here. Tap + to pair one by QR code or address, or set the same passcode on both."
                        )
                        .padding(.bottom, -24)
                        Button(action: openPairing) {
                            Label("Pair a Device", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.bottom, 24)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            }

            if !paired.isEmpty {
                Section(header: Text("Paired")) {
                    ForEach(paired) { row in
                        cell(for: row)
                    }
                }
            }

            if !nearby.isEmpty {
                Section(
                    header: Text("Nearby"),
                    footer: Text("Trust lets this \(ThisDeviceNoun.current) accept it. The other device then asks whether to trust this \(ThisDeviceNoun.current) too - or use the same passcode on both.")
                ) {
                    ForEach(nearby) { row in
                        cell(for: row)
                    }
                }
            }

            if !blocked.isEmpty {
                Section(
                    header: Text("Blocked"),
                    footer: Text("A blocked device can't ask to pair, and nothing from it is shown. Unblock it to hear from it again.")
                ) {
                    ForEach(blocked) { row in
                        cell(for: row)
                    }
                }
            }

            DevicesNetworkSection(snapshot: model.snapshot, transparency: settings.cardTransparency)
        }
        .mePage(glow: settings.bottomGlow, accent: settings.accentTheme.color)
        .refreshable {
            await DevicesRefresh.run(model)
        }
        .confirmationDialog(
            confirming.map { $0.title(name: model.name(for: $0.row.deviceId)) } ?? "Are you sure?",
            isPresented: Binding(
                get: { confirming != nil },
                set: { if !$0 { confirming = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirming
        ) { action in
            Button(action.confirmLabel, role: .destructive) {
                Haptics.tap(settings.haptics)
                action.perform(on: model)
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
        .animation(.default, value: model.snapshot.devices.map { "\($0.deviceId)|\($0.trusted)|\($0.blocked)" })
    }

    @ViewBuilder
    private func cell(for row: DeviceRow) -> some View {
        let name = model.name(for: row.deviceId)
        DevicesRowView(
            row: row,
            name: name,
            accent: settings.accentTheme.fill,
            onOpen: { open(row) },
            onTrust: { trust(row) }
        ) {
            menuItems(for: row)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if row.blocked {
                Button {
                    unblock(row)
                } label: {
                    Label("Unblock", systemImage: "lock.open")
                }
                .tint(settings.accentTheme.fill)
            } else if row.trusted {
                // Not role: .destructive - on iOS 15 that animates the row
                // away before the confirmation dialog has been answered.
                Button {
                    confirming = .remove(row)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .tint(.red)
                Button {
                    renaming = renameTarget(for: row)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(.gray)
            } else {
                Button {
                    trust(row)
                } label: {
                    Label("Trust", systemImage: "checkmark.shield")
                }
                // White label on it: the high-contrast fill, not the tint.
                .tint(settings.accentTheme.fill)
            }
        }
        .contextMenu { menuItems(for: row) }
        // A blocked device's card is dark gray in either theme.
        .meRow(transparency: settings.cardTransparency, fill: row.blocked ? Theme.blockedCard : nil)
    }

    /// The card's ... menu and its long-press menu: the same items.
    @ViewBuilder
    private func menuItems(for row: DeviceRow) -> some View {
        Button {
            open(row)
        } label: {
            Label("Details", systemImage: "info.circle")
        }
        if row.trusted {
            Button {
                renaming = renameTarget(for: row)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        } else if !row.blocked {
            Button {
                trust(row)
            } label: {
                Label("Trust", systemImage: "checkmark.shield")
            }
        }
        Button {
            model.copyDeviceID(of: row)
        } label: {
            Label("Copy Device ID", systemImage: "doc.on.doc")
        }
        if let address = row.connectedAddress ?? row.addresses.first {
            Button {
                model.clipboard.copyText(address)
                model.showToast("Address copied.")
            } label: {
                Label("Copy Address", systemImage: "network")
            }
        }
        Divider()
        if row.blocked {
            Button {
                unblock(row)
            } label: {
                Label("Unblock", systemImage: "lock.open")
            }
        } else {
            Button(role: .destructive) {
                confirming = .block(row)
            } label: {
                Label("Block", systemImage: "nosign")
            }
            if row.trusted {
                Button(role: .destructive) {
                    confirming = .remove(row)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Actions

    private func openPairing() {
        Haptics.tap(settings.haptics)
        model.pairingPresented = true
    }

    private func open(_ row: DeviceRow) {
        Haptics.tap(settings.haptics)
        detailID = row.deviceId
        detailActive = true
    }

    private func unblock(_ row: DeviceRow) {
        Haptics.tap(settings.haptics)
        model.unblock(row)
    }

    private func trust(_ row: DeviceRow) {
        Haptics.success(settings.haptics)
        model.trust(row)
        model.showToast("Trusted \(model.name(for: row.deviceId)). It syncs once it trusts this \(ThisDeviceNoun.current) too.")
    }

    private func renameTarget(for row: DeviceRow) -> DevicesRenameTarget {
        DevicesRenameTarget(
            deviceId: row.deviceId,
            current: model.snapshot.nicknames[row.deviceId] ?? "",
            fallback: model.snapshot.deviceNames[row.deviceId] ?? DeviceLabel.short(row.deviceId)
        )
    }
}

// MARK: - Refresh

@MainActor
private enum DevicesRefresh {
    /// Kicks off discovery and keeps the refresh spinner up while the sweep
    /// runs (at least briefly, at most a few seconds).
    static func run(_ model: AppModel) async {
        model.refreshNetwork()
        let start = Date()
        try? await Task.sleep(nanoseconds: 900_000_000)
        while model.snapshot.sweeping, Date().timeIntervalSince(start) < 6 {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}

// MARK: - Status

private struct DevicesStatusRow: View {
    let snapshot: EngineSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: connected > 0 ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                .font(.title3)
                .foregroundColor(connected > 0 ? Theme.connected : .secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary)
                    .font(.headline)
                    .foregroundColor(connected > 0 ? Theme.connected : .secondary)
                if snapshot.sweeping {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.8, anchor: .leading)
                            .frame(width: 16, height: 16)
                        Text("Looking for devices…")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .animation(.easeInOut(duration: 0.2), value: snapshot.sweeping)
        .accessibilityElement(children: .combine)
    }

    private var connected: Int { snapshot.connectedCount }

    private var summary: String {
        switch connected {
        case 0: return "No devices connected"
        case 1: return "1 device connected"
        default: return "\(connected) devices connected"
        }
    }
}

private struct DevicesLocalNetworkWarning: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Local Network access is off")
                    .font(.headline)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
            // Same path as the engine's pairing error (Open Settings lands on
            // Settings › ClipLink, which has the same switch).
            Text("ClipLink needs it to find your devices. Turn it on in Settings › Privacy & Security › Local Network.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.bordered)
            .padding(.top, 2)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Network

private struct DevicesNetworkSection: View {
    let snapshot: EngineSnapshot
    let transparency: Double

    var body: some View {
        Section(header: Text("Network"), footer: footer) {
            DevicesValueRow(
                title: "This \(ThisDeviceNoun.current)",
                systemImage: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone",
                value: snapshot.network.lanAddress ?? "Not on Wi-Fi",
                copyable: snapshot.network.lanAddress != nil
            )
            .meRow(transparency: transparency)
            if !snapshot.tailscaleIP.isEmpty {
                DevicesValueRow(title: "Tailscale", systemImage: "network", value: snapshot.tailscaleIP)
                    .meRow(transparency: transparency)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch snapshot.network.broadcast {
        case .unavailable:
            Text("iOS limits network broadcasts, so ClipLink finds devices by contacting them directly.")
        case .available:
            Text("Broadcast discovery active.")
        case .unknown:
            EmptyView()
        }
    }
}

private struct DevicesValueRow: View {
    let title: String
    let systemImage: String
    let value: String
    var copyable = true

    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 12)
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            if copyable {
                Button {
                    model.clipboard.copyText(value)
                    model.showToast("Address copied.")
                } label: {
                    Label("Copy Address", systemImage: "doc.on.doc")
                }
            }
        }
    }
}

// MARK: - Device row

/// A Remove or Block waiting for its answer. Shared with the detail screen.
enum DevicesConfirmation {
    case remove(DeviceRow)
    case block(DeviceRow)

    var row: DeviceRow {
        switch self {
        case .remove(let row), .block(let row): return row
        }
    }

    func title(name: String) -> String {
        switch self {
        case .remove: return "Remove \(name)?"
        case .block: return "Block \(name)?"
        }
    }

    var confirmLabel: String {
        switch self {
        case .remove: return "Remove"
        case .block: return "Block"
        }
    }

    var message: String {
        switch self {
        case .remove:
            return "It will no longer be able to sync with this \(ThisDeviceNoun.current). You can pair again later."
        case .block:
            return "It is removed from your paired devices and stops syncing. It can't ask to pair again, and nothing from it is shown, until you unblock it."
        }
    }

    @MainActor
    func perform(on model: AppModel) {
        switch self {
        case .remove(let row): model.untrust(row)
        case .block(let row): model.block(row)
        }
    }
}

/// One device card: tap it for the detail screen, ... for the menu. Only the
/// address the live connection uses is shown here; the rest are in the detail.
private struct DevicesRowView<MenuItems: View>: View {
    let row: DeviceRow
    let name: String
    /// The accent fill (AccentTheme.fill): it sits under a white glyph.
    let accent: Color
    let onOpen: () -> Void
    let onTrust: () -> Void
    let menuItems: () -> MenuItems

    @Environment(\.colorScheme) private var colorScheme

    init(
        row: DeviceRow,
        name: String,
        accent: Color,
        onOpen: @escaping () -> Void,
        onTrust: @escaping () -> Void,
        @ViewBuilder menuItems: @escaping () -> MenuItems
    ) {
        self.row = row
        self.name = name
        self.accent = accent
        self.onOpen = onOpen
        self.onTrust = onTrust
        self.menuItems = menuItems
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    DevicesIconTile(trusted: row.trusted, connected: row.connected, blocked: row.blocked, accent: accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                            .font(.body.weight(.semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(status)
                            .font(.subheadline)
                            .foregroundColor(row.connected && !row.blocked ? Theme.connected : .secondary)
                        if row.connected, !row.blocked, let address = row.connectedAddress {
                            Text(address)
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        } else if !row.connected, !row.blocked, let lastSeen = row.lastSeen {
                            Text("Last seen \(DevicesRelativeTime.string(for: lastSeen))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(SyncedCardButtonStyle())
            .accessibilityElement(children: .combine)
            .accessibilityHint("Shows details")

            if !row.trusted && !row.blocked {
                Button("Trust", action: onTrust)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Trust \(name)")
            }

            Menu {
                menuItems()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More options for \(name)")
        }
        .padding(.vertical, 4)
        // The gray card is dark in either theme: light text on it.
        .environment(\.colorScheme, row.blocked ? .dark : colorScheme)
    }

    private var status: String { row.statusText }
}

/// Rounded tile with the device glyph and a status dot in its corner. There
/// is no device type on the wire, so every peer gets the desktop glyph.
struct DevicesIconTile: View {
    let trusted: Bool
    let connected: Bool
    var blocked = false
    let accent: Color

    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 40

    var body: some View {
        Image(systemName: blocked ? "nosign" : "desktopcomputer")
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundColor(blocked || trusted ? .white : .secondary)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(blocked ? Color(UIColor.systemGray) : trusted ? accent : Color(UIColor.tertiarySystemFill))
            )
            .overlay(alignment: .bottomTrailing) {
                if !blocked {
                    Circle()
                        .fill(connected ? Theme.connected : Color(UIColor.systemGray3))
                        .frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(Color(Theme.card), lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
            }
            .accessibilityHidden(true)
    }
}

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
