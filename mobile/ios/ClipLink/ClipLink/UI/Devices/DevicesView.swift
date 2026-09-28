import SwiftUI
import UIKit

/// The Devices tab: paired devices, devices discovered nearby, and the state
/// of the local network, in an inset-grouped list. Pull to refresh re-runs
/// discovery; "+" opens the pairing sheet (which is pairing mode).
struct DevicesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    @State private var renaming: DevicesRenameTarget?
    @State private var removing: DeviceRow?

    var body: some View {
        NavigationView {
            list
                .navigationTitle("Devices")
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

    private var paired: [DeviceRow] { model.snapshot.devices.filter(\.trusted) }
    private var nearby: [DeviceRow] { model.snapshot.devices.filter { !$0.trusted } }

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

            if paired.isEmpty && nearby.isEmpty {
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
                    footer: Text("Trust lets this device accept it. The other device must also trust this \(ThisDeviceNoun.current) (same passcode, or its pairing screen open).")
                ) {
                    ForEach(nearby) { row in
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
            removing.map { "Remove \(model.name(for: $0.deviceId))?" } ?? "Remove Device?",
            isPresented: Binding(
                get: { removing != nil },
                set: { if !$0 { removing = nil } }
            ),
            titleVisibility: .visible,
            presenting: removing
        ) { row in
            Button("Remove", role: .destructive) {
                Haptics.tap(settings.haptics)
                model.untrust(row)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It will no longer be able to sync with this \(ThisDeviceNoun.current). You can pair again later.")
        }
        .animation(.default, value: model.snapshot.devices.map { "\($0.deviceId)|\($0.trusted)" })
    }

    @ViewBuilder
    private func cell(for row: DeviceRow) -> some View {
        let name = model.name(for: row.deviceId)
        DevicesRowView(row: row, name: name, accent: settings.accentTheme.fill) {
            trust(row)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if row.trusted {
                // Not role: .destructive - on iOS 15 that animates the row
                // away before the confirmation dialog has been answered.
                Button {
                    removing = row
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
        .contextMenu {
            if row.trusted {
                Button {
                    renaming = renameTarget(for: row)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            } else {
                Button {
                    trust(row)
                } label: {
                    Label("Trust", systemImage: "checkmark.shield")
                }
            }
            Button {
                model.clipboard.copyText(row.deviceId)
                model.showToast("Device ID copied.")
            } label: {
                Label("Copy Device ID", systemImage: "doc.on.doc")
            }
            if let address = row.addresses.first {
                Button {
                    model.clipboard.copyText(address)
                    model.showToast("Address copied.")
                } label: {
                    Label("Copy Address", systemImage: "network")
                }
            }
            if row.trusted {
                Divider()
                Button(role: .destructive) {
                    removing = row
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
        .meRow(transparency: settings.cardTransparency)
    }

    // MARK: - Actions

    private func openPairing() {
        Haptics.tap(settings.haptics)
        model.pairingPresented = true
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

private struct DevicesRowView: View {
    let row: DeviceRow
    let name: String
    /// The accent fill (AccentTheme.fill): it sits under a white glyph.
    let accent: Color
    let onTrust: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                DevicesIconTile(trusted: row.trusted, connected: row.connected, accent: accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(status)
                        .font(.subheadline)
                        .foregroundColor(row.connected ? Theme.connected : .secondary)
                    if !row.addresses.isEmpty {
                        Text(row.addresses.joined(separator: " · "))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    if !row.connected, let lastSeen = row.lastSeen {
                        Text("Last seen \(DevicesRelativeTime.string(for: lastSeen))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 4)

            if !row.trusted {
                Button("Trust", action: onTrust)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Trust \(name)")
            }
        }
        .padding(.vertical, 4)
    }

    private var status: String {
        if row.connected { return "Connected" }
        if row.trusted { return "Paired · not connected" }
        if row.pairing { return "Nearby — pairing mode open" }
        return "Nearby"
    }
}

/// Rounded tile with the device glyph and a status dot in its corner. There
/// is no device type on the wire, so every peer gets the desktop glyph.
private struct DevicesIconTile: View {
    let trusted: Bool
    let connected: Bool
    let accent: Color

    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 40

    var body: some View {
        Image(systemName: "desktopcomputer")
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundColor(trusted ? .white : .secondary)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(trusted ? accent : Color(UIColor.tertiarySystemFill))
            )
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(connected ? Theme.connected : Color(UIColor.systemGray3))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Color(Theme.card), lineWidth: 2))
                    .offset(x: 3, y: 3)
            }
            .accessibilityHidden(true)
    }
}

private enum DevicesRelativeTime {
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
private struct DevicesRenameSheet: View {
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
