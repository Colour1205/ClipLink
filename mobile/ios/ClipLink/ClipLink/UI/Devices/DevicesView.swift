import SwiftUI
import UIKit

/// The Devices tab: paired devices, devices discovered nearby, blocked
/// devices, and the state of the local network, in an inset-grouped list.
/// Pull to refresh re-runs discovery; "+" opens the pairing sheet; a device
/// opens its detail screen.
struct DevicesView: View {
    /// What the tab shows; it redraws only when that changes (see DevicesStore).
    @ObservedObject private var store = AppModel.shared.devices
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var renaming: DevicesRenameTarget?
    /// One programmatic link for every card (as on the Synced tab): a link
    /// inside a row would pop the detail screen the moment its device moves
    /// to another section - trusting a nearby device does exactly that.
    @State private var detailID = ""
    @State private var detailActive = false
    /// A device card zooms into its screen like a Synced card (see
    /// SyncedZoomSource), with the list blurred and dimmed behind it.
    @Namespace private var deviceZoom
    /// The device's screen has started to close (see SyncedScreenWatcher).
    @State private var detailLeaving = false
    /// A card tapped while a device's screen is still closing: it opens as
    /// soon as that screen is gone (as on the Synced tab).
    @State private var queuedID: String?

    /// For the actions only, not watched.
    private var model: AppModel { AppModel.shared }
    private var actions: DeviceActions { DeviceActions(model: model, haptics: settings.haptics) }
    /// The list goes soft behind a device's screen while it is open, as the
    /// Synced list does behind an item's (see SyncedZoom).
    private var zoomBackdrop: Bool { detailActive && !detailLeaving && SyncedZoom.available }

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                list
                    #if DEBUG
                    .onAppear { applyDebugHooks(proxy) }
                    #endif
            }
            .modifier(SyncedZoomVeil(shown: zoomBackdrop, reduceMotion: reduceMotion))
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

    private var paired: [DeviceRow] { store.value.devices.filter { $0.trusted && !$0.blocked } }
    private var nearby: [DeviceRow] { store.value.devices.filter { !$0.trusted && !$0.blocked } }
    private var blocked: [DeviceRow] { store.value.devices.filter(\.blocked) }

    private var list: some View {
        List {
            Section {
                DevicesStatusRow(connectedCount: store.value.connectedCount, sweeping: store.value.sweeping)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .cardBackground(transparency: settings.cardTransparency)
                    .devicesCardRow()
                if store.value.network.localNetwork == .denied {
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
                    footer: Text("Trust lets this device accept it and sends it a request. It must also trust this \(ThisDeviceNoun.current): accept the request there, or use the same passcode.")
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

            DevicesNetworkSection(network: store.value.network, tailscaleIP: store.value.tailscaleIP, transparency: settings.cardTransparency)

            Section {
                GetClipLinkRow()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .cardBackground(transparency: settings.cardTransparency)
                    .devicesCardRow()
            }
        }
        // On the list, under the page's background (see SyncedZoomBlur).
        .modifier(SyncedZoomBlur(shown: zoomBackdrop, reduceMotion: reduceMotion))
        .mePage(glow: settings.bottomGlow, accent: settings.accentTheme.color)
        .refreshable {
            await DevicesRefresh.run(model)
        }
        .background(
            NavigationLink(
                destination: DeviceDetailView(deviceId: detailID)
                    .modifier(SyncedZoomDestination(id: detailID, namespace: deviceZoom) { shown in
                        detailLeaving = !shown
                        // A close given up (a drag let go): no card waits for it.
                        if shown { queuedID = nil }
                    }),
                isActive: $detailActive
            ) {
                EmptyView()
            }
        )
        .onChange(of: detailActive) { active in
            guard !active, let next = queuedID else { return }
            queuedID = nil
            // After this update: a push in the same one as the pop's end
            // can be lost.
            DispatchQueue.main.async { show(next) }
        }
        // A device appearing, disappearing, being blocked or trusted moves
        // its row with a spring; a status change (connected, offline) never
        // reorders anything - the engine's order is deliberate.
        .animation(
            reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.86),
            value: store.value.devices.map { "\($0.deviceId)|\($0.trusted)|\($0.blocked)" }
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
            onRename: { renaming = actions.renameTarget(row) },
            zoom: deviceZoom
        )
        .devicesCardRow()
    }

    // MARK: - Actions

    private func openPairing() {
        Haptics.tap(settings.haptics)
        model.pairingPresented = true
    }

    /// Nothing waits for an animation: a card tapped while the last screen is
    /// still closing opens the moment it has gone (see queuedID).
    private func open(_ row: DeviceRow) {
        Haptics.tap(settings.haptics)
        if detailActive && detailLeaving {
            queuedID = row.deviceId
            return
        }
        show(row.deviceId)
    }

    private func show(_ id: String) {
        detailID = id
        detailLeaving = false
        detailActive = true
    }

    #if DEBUG
    private static var debugHandled = false

    /// Test hooks (Debug builds only), for looking at states a screenshot
    /// can't reach by tapping. Use them with `-ClipLinkDebugFixtures devices`;
    /// `<index>` counts the snapshot's devices.
    ///   -ClipLinkDebugDeviceDetail <index>   opens that device's detail screen
    ///   -ClipLinkDebugDevicesScroll <index>  scrolls the list to that device
    private func applyDebugHooks(_ proxy: ScrollViewProxy) {
        guard !Self.debugHandled else { return }
        Self.debugHandled = true
        let defaults = UserDefaults.standard
        let devices = store.value.devices
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
    let connectedCount: Int
    let sweeping: Bool

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
                if sweeping {
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
        .animation(.easeInOut(duration: 0.2), value: sweeping)
        .accessibilityElement(children: .combine)
    }

    private var connected: Int { connectedCount }

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
    let network: NetworkStatus
    let tailscaleIP: String
    let transparency: Double

    var body: some View {
        Section(header: Text("Network"), footer: footer) {
            DevicesValueRow(
                title: "This \(ThisDeviceNoun.current)",
                systemImage: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone",
                value: network.lanAddress ?? "Not on Wi-Fi",
                copyable: network.lanAddress != nil
            )
            .meRow(transparency: transparency)
            if !tailscaleIP.isEmpty {
                DevicesValueRow(title: "Tailscale", systemImage: "network", value: tailscaleIP)
                    .meRow(transparency: transparency)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch network.broadcast {
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

    /// For the copy action only, not watched.
    private var model: AppModel { AppModel.shared }

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
