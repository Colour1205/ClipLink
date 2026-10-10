import SwiftUI
import UIKit

/// The Devices tab: paired devices, devices discovered nearby, blocked
/// devices, and the state of the local network, in an inset-grouped list.
/// Pull to refresh re-runs discovery; "+" opens the pairing sheet (which is
/// pairing mode); a device opens its detail screen.
struct DevicesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var renaming: DevicesRenameTarget?
    /// One programmatic link for every card (as on the Synced tab): a link
    /// inside a row would pop the detail screen the moment its device moves
    /// to another section - trusting a nearby device does exactly that.
    @State private var detailID = ""
    @State private var detailActive = false

    private var actions: DeviceActions { DeviceActions(model: model, haptics: settings.haptics) }

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                list
                    #if DEBUG
                    .onAppear { applyDebugHooks(proxy) }
                    #endif
            }
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

    private var paired: [DeviceRow] { model.snapshot.devices.filter { $0.trusted && !$0.blocked } }
    private var nearby: [DeviceRow] { model.snapshot.devices.filter { !$0.trusted && !$0.blocked } }
    private var blocked: [DeviceRow] { model.snapshot.devices.filter(\.blocked) }

    private var list: some View {
        List {
            Section {
                DevicesStatusRow(snapshot: model.snapshot)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .cardBackground(transparency: settings.cardTransparency)
                    .devicesCardRow()
                if model.snapshot.network.localNetwork == .denied {
                    DevicesLocalNetworkWarning()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .cardBackground(transparency: settings.cardTransparency)
                        .devicesCardRow()
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
                    footer: Text("Trust lets this device accept it. The other device must also trust this \(ThisDeviceNoun.current) (same passcode, or its pairing screen open).")
                ) {
                    ForEach(nearby) { row in
                        cell(for: row)
                    }
                }
            }

            if !blocked.isEmpty {
                Section(
                    header: Text("Blocked"),
                    footer: Text("Blocked devices can't send pairing requests, and ClipLink never connects to them.")
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
        .background(
            NavigationLink(destination: DeviceDetailView(deviceId: detailID), isActive: $detailActive) {
                EmptyView()
            }
        )
        // A device appearing, disappearing, being blocked or trusted moves
        // its row with a spring; a status change (connected, offline) never
        // reorders anything - the engine's order is deliberate.
        .animation(
            reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.86),
            value: model.snapshot.devices.map { "\($0.deviceId)|\($0.trusted)|\($0.blocked)" }
        )
    }

    @ViewBuilder
    private func cell(for row: DeviceRow) -> some View {
        DevicesCard(
            row: row,
            actions: actions,
            accent: settings.accentTheme.fill,
            transparency: settings.cardTransparency,
            onOpen: { open(row) },
            onRename: { renaming = actions.renameTarget(row) }
        )
        .devicesCardRow()
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

    #if DEBUG
    private static var debugHandled = false

    /// Test hooks (Debug builds only), for looking at states a screenshot
    /// can't reach by tapping. Use them with `-ClipLinkDebugFixtures devices`;
    /// `<index>` counts `model.snapshot.devices`.
    ///   -ClipLinkDebugDeviceDetail <index>   opens that device's detail screen
    ///   -ClipLinkDebugDevicesScroll <index>  scrolls the list to that device
    private func applyDebugHooks(_ proxy: ScrollViewProxy) {
        guard !Self.debugHandled else { return }
        Self.debugHandled = true
        let defaults = UserDefaults.standard
        let devices = model.snapshot.devices
        func device(_ key: String) -> DeviceRow? {
            guard let raw = defaults.string(forKey: key), let index = Int(raw), devices.indices.contains(index) else { return nil }
            return devices[index]
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if let row = device("ClipLinkDebugDevicesScroll") {
                proxy.scrollTo(row.deviceId, anchor: .center)
            }
            if let row = device("ClipLinkDebugDeviceDetail") {
                detailID = row.deviceId
                detailActive = true
            }
        }
    }
    #endif
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
