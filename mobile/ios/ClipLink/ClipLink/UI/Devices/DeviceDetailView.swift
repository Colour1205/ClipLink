import SwiftUI
import UIKit

extension DeviceRow {
    /// One line on where this device stands, for its card and its detail screen.
    var statusText: String {
        if blocked { return "Blocked" }
        if connected { return "Connected" }
        if trusted { return "Paired · not connected" }
        if pairing { return "Nearby — pairing mode open" }
        return "Nearby"
    }
}

/// One device in full: every address it can be reached at (the one the live
/// connection uses marked), who it says it is, and what can be done with it.
/// The card on the Devices tab shows only the address in use; the rest are
/// here. The device is looked up live on every render, so the screen follows
/// it going online or offline, and closes itself once it is gone.
struct DeviceDetailView: View {
    let deviceId: String

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var renaming: DevicesRenameTarget?
    @State private var confirming: DevicesConfirmation?

    private var row: DeviceRow? { model.snapshot.devices.first { $0.deviceId == deviceId } }

    var body: some View {
        Group {
            if let row {
                content(for: row)
            } else {
                EmptyStateView(
                    systemImage: "laptopcomputer.and.iphone",
                    title: "Device Not Found",
                    message: "This device is no longer paired or nearby."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .pageBackground(glow: settings.bottomGlow, accent: settings.accentTheme.color)
            }
        }
        .navigationTitle(row.map { model.name(for: $0.deviceId) } ?? "Device")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $renaming) { target in
            DevicesRenameSheet(target: target) { name in
                model.rename(target.deviceId, to: name)
            }
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
                // A removed device may still be nearby, so the screen would
                // stay: leave it, as the person asked to be done with it.
                if case .remove = action { dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
    }

    // MARK: - Content

    private func content(for row: DeviceRow) -> some View {
        List {
            Section {
                header(row)
                    .meRow(transparency: settings.cardTransparency, fill: row.blocked ? Theme.blockedCard : nil)
            }

            let reachable = addresses(for: row)
            Section {
                if reachable.isEmpty {
                    Text("No address is known yet. One appears here once this device is heard on your network.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .meRow(transparency: settings.cardTransparency)
                }
                ForEach(reachable, id: \.self) { address in
                    addressRow(address, inUse: address == row.connectedAddress)
                        .meRow(transparency: settings.cardTransparency)
                }
            } header: {
                Text("Can connect at")
            } footer: {
                if !reachable.isEmpty {
                    Text("Tap an address to copy it.")
                }
            }

            Section {
                detailRows(for: row)
            } header: {
                Text("Details")
            }

            Section {
                actions(for: row)
            }
        }
        .mePage(glow: settings.bottomGlow, accent: settings.accentTheme.color)
        .onChange(of: self.row == nil) { gone in
            if gone { dismiss() }
        }
    }

    private func header(_ row: DeviceRow) -> some View {
        HStack(spacing: 14) {
            DevicesIconTile(trusted: row.trusted, connected: row.connected, blocked: row.blocked, accent: settings.accentTheme.fill)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name(for: row.deviceId))
                    .font(.headline)
                    .lineLimit(2)
                Text(row.statusText)
                    .font(.subheadline)
                    .foregroundColor(row.connected && !row.blocked ? Theme.connected : .secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .environment(\.colorScheme, row.blocked ? .dark : colorScheme)
        .accessibilityElement(children: .combine)
    }

    @Environment(\.colorScheme) private var colorScheme

    /// Every address it can be reached at, the one in use first. The
    /// connection's own address is included even if it was never heard from.
    private func addresses(for row: DeviceRow) -> [String] {
        var list = row.addresses
        if let inUse = row.connectedAddress {
            list.removeAll { $0 == inUse }
            list.insert(inUse, at: 0)
        }
        return list
    }

    private func addressRow(_ address: String, inUse: Bool) -> some View {
        Button {
            model.clipboard.copyText(address)
            model.showToast("Address copied.")
        } label: {
            HStack(spacing: 8) {
                Text(address)
                    .font(.body.monospacedDigit())
                    .foregroundColor(.primary)
                Spacer(minLength: 8)
                if inUse {
                    Text("In use")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.connected)
                }
            }
        }
        .accessibilityLabel(inUse ? "\(address), in use" : address)
        .accessibilityHint("Copies the address")
    }

    @ViewBuilder
    private func detailRows(for row: DeviceRow) -> some View {
        let id = row.deviceId
        let nickname = model.snapshot.nicknames[id]
        MeDetailRow(title: "Status", value: row.statusText)
            .meRow(transparency: settings.cardTransparency)
        if let nickname {
            MeDetailRow(title: "Nickname", value: nickname)
                .meRow(transparency: settings.cardTransparency)
        }
        MeDetailRow(title: "Name", value: model.snapshot.deviceNames[id] ?? "Not known yet")
            .meRow(transparency: settings.cardTransparency)
        MeDetailRow(title: "Fingerprint", value: DeviceLabel.fingerprint(id), monospaced: true)
            .meRow(transparency: settings.cardTransparency)
        if row.pairing {
            MeDetailRow(title: "Its pairing screen is open", value: "Yes")
                .meRow(transparency: settings.cardTransparency)
        }
        if !row.connected, !row.blocked, let lastSeen = row.lastSeen {
            MeDetailRow(title: "Last seen", value: DevicesRelativeTime.string(for: lastSeen))
                .meRow(transparency: settings.cardTransparency)
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Device ID")
            Text(id)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .meRow(transparency: settings.cardTransparency)
    }

    @ViewBuilder
    private func actions(for row: DeviceRow) -> some View {
        if !row.trusted && !row.blocked {
            Button {
                Haptics.success(settings.haptics)
                model.trust(row)
                model.showToast("Trusted \(model.name(for: row.deviceId)). It syncs once it trusts this \(ThisDeviceNoun.current) too.")
            } label: {
                Label("Trust", systemImage: "checkmark.shield")
            }
            .meRow(transparency: settings.cardTransparency)
        }
        if row.trusted {
            Button {
                renaming = DevicesRenameTarget(
                    deviceId: row.deviceId,
                    current: model.snapshot.nicknames[row.deviceId] ?? "",
                    fallback: model.snapshot.deviceNames[row.deviceId] ?? DeviceLabel.short(row.deviceId)
                )
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .meRow(transparency: settings.cardTransparency)
        }
        Button {
            model.copyDeviceID(of: row)
        } label: {
            Label("Copy Device ID", systemImage: "doc.on.doc")
        }
        .meRow(transparency: settings.cardTransparency)
        if row.blocked {
            Button {
                Haptics.tap(settings.haptics)
                model.unblock(row)
            } label: {
                Label("Unblock", systemImage: "lock.open")
            }
            .meRow(transparency: settings.cardTransparency)
        } else {
            Button(role: .destructive) {
                confirming = .block(row)
            } label: {
                Label("Block", systemImage: "nosign")
            }
            .meRow(transparency: settings.cardTransparency)
            if row.trusted {
                Button(role: .destructive) {
                    confirming = .remove(row)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .meRow(transparency: settings.cardTransparency)
            }
        }
    }
}
