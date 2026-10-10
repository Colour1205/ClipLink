import SwiftUI
import UIKit

/// One device in full: its state, every address we know for it and how we
/// know it, its identity, and the actions the card's menu offers. Looks the
/// device up live on every render, so addresses and status follow the engine,
/// and the screen closes itself if the device disappears (a removed device
/// nobody can hear any more, say).
struct DeviceDetailView: View {
    let deviceId: String

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var renaming: DevicesRenameTarget?
    // One confirmation per button (each on its own view): the dialog then
    // points at the button it is about.
    @State private var removing: DevicePending?
    @State private var blocking: DevicePending?

    private var row: DeviceRow? { model.snapshot.devices.first { $0.deviceId == deviceId } }
    private var actions: DeviceActions { DeviceActions(model: model, haptics: settings.haptics) }

    var body: some View {
        // The sheet sits on this wrapper and each confirmation dialog on its own
        // button: two presentations on one view is an iOS 15 bug.
        ZStack {
            if let row {
                content(for: row)
            } else {
                EmptyStateView(
                    systemImage: "laptopcomputer.slash",
                    title: "Device Gone",
                    message: "This device is no longer in your list."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .pageBackground(glow: settings.bottomGlow, accent: settings.accentTheme.color)
            }
        }
        .navigationTitle("Device")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $renaming) { target in
            DevicesRenameSheet(target: target) { name in
                model.rename(target.deviceId, to: name)
            }
        }
        .onChange(of: row == nil) { gone in
            if gone { dismiss() }
        }
    }

    // MARK: - Content

    private func content(for row: DeviceRow) -> some View {
        ScrollViewReader { proxy in
            list(for: row)
                #if DEBUG
                .onAppear { Self.applyDebugScroll(proxy) }
                #endif
        }
    }

    private func list(for row: DeviceRow) -> some View {
        let transparency = settings.cardTransparency
        let status = row.status
        return List {
            Section {
                DeviceDetailHeader(row: row, name: actions.name(row), accent: settings.accentTheme.fill, tint: settings.accentTheme.color)
                    .modifier(DeviceHeaderBackground(blocked: row.blocked, transparency: transparency))
            }

            Section(header: Text("Connection")) {
                DeviceInfoRow(title: "Status", value: status.text, valueColor: status == .connected ? Theme.connected : .secondary)
                    .meRow(transparency: transparency)
                DeviceInfoRow(title: "Address in use", value: addressInUse(row) ?? "—", digits: .tabular)
                    .meRow(transparency: transparency)
                DeviceInfoRow(title: "Last seen", value: lastSeen(row))
                    .meRow(transparency: transparency)
            }

            Section(header: Text("Addresses")) {
                if row.addressDetails.isEmpty {
                    Text("No known addresses yet.")
                        .foregroundColor(.secondary)
                        .meRow(transparency: transparency)
                } else {
                    ForEach(row.addressDetails) { address in
                        DeviceAddressRow(address: address, actions: actions)
                            .meRow(transparency: transparency)
                    }
                }
            }

            Section(
                header: Text("Identity"),
                footer: Text("Compare the fingerprint on both devices to be sure it's the one you mean.")
            ) {
                DeviceInfoRow(title: "Fingerprint", value: DeviceLabel.short(row.deviceId), digits: .monospaced)
                    .meRow(transparency: transparency)
                    .debugScrollID("debug.identity")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Device ID")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(row.deviceId)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .meRow(transparency: transparency)
                Button {
                    actions.copyDeviceID(row)
                } label: {
                    Label("Copy Device ID", systemImage: "doc.on.doc")
                }
                .meRow(transparency: transparency)
            }

            Section(header: Text("Actions"), footer: actionsFooter(row)) {
                actionRows(for: row)
                    .meRow(transparency: transparency)
            }
        }
        .mePage(glow: settings.bottomGlow, accent: settings.accentTheme.color)
    }

    #if DEBUG
    /// Test hook (Debug builds only): `-ClipLinkDebugDeviceDetailScroll
    /// <identity|bottom>` scrolls this screen, for screenshots.
    private static func applyDebugScroll(_ proxy: ScrollViewProxy) {
        guard let target = UserDefaults.standard.string(forKey: "ClipLinkDebugDeviceDetailScroll") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if target == "identity" { proxy.scrollTo("debug.identity", anchor: .top) }
            if target == "bottom" { proxy.scrollTo("debug.last", anchor: .bottom) }
        }
    }
    #endif

    @ViewBuilder
    private func actionRows(for row: DeviceRow) -> some View {
        if row.blocked {
            Button {
                actions.unblock(row)
            } label: {
                Label("Unblock", systemImage: "hand.raised.slash")
            }
            .debugScrollID("debug.last")
        } else {
            Button {
                actions.tap()
                renaming = actions.renameTarget(row)
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            if row.trusted {
                Button(role: .destructive) {
                    actions.tap()
                    removing = DevicePending(kind: .remove, row: row)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .deviceConfirmation($removing, actions: actions)
            } else {
                Button {
                    actions.trust(row)
                } label: {
                    Label("Trust", systemImage: "checkmark.shield")
                }
            }
            Button(role: .destructive) {
                actions.tap()
                blocking = DevicePending(kind: .block, row: row)
            } label: {
                Label("Block Device", systemImage: "hand.raised")
            }
            .deviceConfirmation($blocking, actions: actions)
            .debugScrollID("debug.last")
        }
    }

    @ViewBuilder
    private func actionsFooter(_ row: DeviceRow) -> some View {
        if row.blocked {
            Text("Blocked devices can't send pairing requests, and ClipLink never connects to them. Unblock it to let it ask to pair again.")
        } else if !row.trusted {
            Text("Trust lets this device accept it. The other device must also trust this \(ThisDeviceNoun.current) (same passcode, or its pairing screen open).")
        }
    }

    // MARK: - Values

    private func addressInUse(_ row: DeviceRow) -> String? {
        guard row.connected else { return nil }
        return row.connectionAddress ?? row.addressDetails.first(where: \.inUse)?.ip
    }

    private func lastSeen(_ row: DeviceRow) -> String {
        if row.connected { return "Now" }
        guard let date = row.lastSeen else { return "—" }
        return DevicesRelativeTime.sentence(for: date)
    }
}

// MARK: - Header

private struct DeviceDetailHeader: View {
    let row: DeviceRow
    let name: String
    let accent: Color
    let tint: Color

    var body: some View {
        let status = row.status
        let blocked = row.blocked
        VStack(spacing: 10) {
            DevicesIconTile(status: status, trusted: row.trusted, accent: accent, baseSize: 64)
            Text(name)
                .font(.title2.weight(.bold))
                .foregroundColor(blocked ? DevicesBlockedStyle.primary : .primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            DeviceStatusPill(status: status, tint: tint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .devicesBlockedAppearance(blocked)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(status.spokenText)")
    }
}

/// A coloured capsule with the status in words (colour is never the only cue).
private struct DeviceStatusPill: View {
    let status: DeviceStatus
    let tint: Color

    @ScaledMetric(relativeTo: .subheadline) private var dotSize: CGFloat = 8

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dot)
                .frame(width: dotSize, height: dotSize)
            Text(status.text)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(textColor)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(fill))
        .animation(.easeInOut(duration: 0.2), value: status)
    }

    private var dot: Color {
        switch status {
        case .blocked: return Color(red: 1.0, green: 0.56, blue: 0.52)
        default: return status.tint(accent: tint)
        }
    }

    /// Text on the tinted capsule: green is dark enough on its own; the accent
    /// colours are not (orange is ~3.6:1), so those stay primary.
    private var textColor: Color {
        switch status {
        case .connected: return Theme.connected
        case .blocked: return DevicesBlockedStyle.primary
        case .pairedOffline, .away: return .secondary
        default: return .primary
        }
    }

    private var fill: Color {
        status == .blocked ? DevicesBlockedStyle.tileFill : status.tint(accent: tint).opacity(0.15)
    }
}

/// The header row's surface: the normal card, or the blocked dark gray.
private struct DeviceHeaderBackground: ViewModifier {
    let blocked: Bool
    let transparency: Double

    func body(content: Content) -> some View {
        if blocked {
            content.listRowBackground(DevicesBlockedStyle.fill)
        } else {
            content.meRow(transparency: transparency)
        }
    }
}

// MARK: - Rows

/// Title on the left, value on the right (stacked at accessibility text sizes).
private struct DeviceInfoRow: View {
    let title: String
    let value: String
    var digits: Digits = .proportional
    var valueColor: Color = .secondary

    enum Digits {
        case proportional
        /// Equal-width digits (addresses).
        case tabular
        /// A monospaced face (fingerprints).
        case monospaced
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    valueText
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title)
                    Spacer(minLength: 8)
                    valueText.multilineTextAlignment(.trailing)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var valueText: some View {
        Text(value)
            .font(font)
            .foregroundColor(valueColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var font: Font {
        switch digits {
        case .proportional: return .body
        case .tabular: return .body.monospacedDigit()
        case .monospaced: return .system(.body, design: .monospaced)
        }
    }
}

/// One known address: tap to copy it.
private struct DeviceAddressRow: View {
    let address: DeviceAddress
    let actions: DeviceActions

    var body: some View {
        Button {
            actions.copyAddress(address.ip)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(address.ip)
                        .font(.body.monospacedDigit())
                        .foregroundColor(.primary)
                    Label(kindTitle, systemImage: kindSymbol)
                        .labelStyle(DeviceKindLabelStyle())
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.secondary)
                    Text(provenance)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if address.inUse {
                    Text("In use")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.connected)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.connected.opacity(0.15)))
                }
                Image(systemName: "doc.on.doc")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Copies the address.")
        .contextMenu {
            Button {
                actions.copyAddress(address.ip)
            } label: {
                Label("Copy Address", systemImage: "doc.on.doc")
            }
        }
    }

    private var kindTitle: String {
        switch address.kind {
        case .lan: return "Wi‑Fi"
        case .tailscale: return "Tailscale"
        case .other: return "Other"
        }
    }

    private var kindSymbol: String {
        switch address.kind {
        case .lan: return "wifi"
        case .tailscale: return "point.3.connected.trianglepath.dotted"
        case .other: return "globe"
        }
    }

    /// How we know it, then when it was last seen there.
    private var provenance: String {
        var parts = address.sources.map(Self.sourceText)
        if let date = address.lastSeen, !address.inUse {
            parts.append("Last seen \(DevicesRelativeTime.string(for: date))")
        }
        return parts.isEmpty ? "Not seen yet" : parts.joined(separator: " · ")
    }

    private static func sourceText(_ source: DeviceAddress.Source) -> String {
        switch source {
        case .heard: return "Heard on this network"
        case .reached: return "Connected"
        case .stored: return "Saved with the pairing"
        case .advertised: return "Advertised by the device"
        }
    }

    private var accessibilityLabel: String {
        var text = "\(address.ip), \(kindTitle.replacingOccurrences(of: "\u{2011}", with: "-"))"
        if address.inUse { text += ", in use" }
        return "\(text). \(provenance.replacingOccurrences(of: " · ", with: ", "))"
    }
}

/// Glyph and title on one line, the glyph in a fixed-width column.
private struct DeviceKindLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}

private extension View {
    /// A scroll target for the Debug-only `-ClipLinkDebugDeviceDetailScroll`
    /// hook; a no-op in Release builds.
    func debugScrollID(_ id: String) -> some View {
        #if DEBUG
        self.id(id)
        #else
        self
        #endif
    }
}
