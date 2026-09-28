import Combine
import SwiftUI
import UIKit
import UserNotifications

/// The Me tab: this iPhone's identity, every setting, pairing extras,
/// network status, support screens and data - Settings-app style.
struct MeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    @State private var refreshStatus: UIBackgroundRefreshStatus = .available
    @State private var lowPowerMode = false
    @State private var notificationsDenied = false
    /// "Notify about new items" was switched on here, so a denial (which
    /// snaps the switch back off) can still point the way to Settings.
    @State private var notifyRequested = false
    @State private var confirmingClear = false

    var body: some View {
        NavigationView {
            List {
                thisIPhoneSection
                syncSection
                backgroundSection
                appearanceSection
                pairingSection
                networkSection
                supportSection
                dataSection
            }
            .mePage(glow: settings.bottomGlow, accent: settings.accentTheme.color)
            .tint(settings.accentTheme.color)
            .navigationTitle("Me")
            .navigationBarTitleDisplayMode(.large)
        }
        .navigationViewStyle(.stack)
        .onAppear(perform: refreshSystemStatus)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshSystemStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.backgroundRefreshStatusDidChangeNotification)) { _ in
            refreshSystemStatus()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
                .receive(on: DispatchQueue.main)
        ) { _ in
            refreshSystemStatus()
        }
    }

    private var ownId: String { model.snapshot.ownDeviceId }
    private var network: NetworkStatus { model.snapshot.network }
    /// Icon tiles carry white glyphs, so they use the accent's fill shade.
    private var accentFill: Color { settings.accentTheme.fill }
    private var transparency: Double { settings.cardTransparency }

    // MARK: - This iPhone

    private var thisIPhoneSection: some View {
        Section {
            Group {
                HStack(spacing: 14) {
                    MeIconTile(systemImage: "iphone", color: accentFill, baseSize: 50)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This iPhone")
                            .font(.title3.weight(.semibold))
                        Text(ownId.isEmpty ? "Generating identity…" : DeviceLabel.short(ownId))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)

                NavigationLink(destination: MeDeviceNameView()) {
                    HStack(spacing: 12) {
                        MeRowLabel(title: "Device Name", systemImage: "textformat", tint: .orange)
                        Spacer(minLength: 8)
                        Text(model.snapshot.deviceName.isEmpty ? "Not set" : model.snapshot.deviceName)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Device ID")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(ownId.isEmpty ? "Generating identity…" : ownId)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityLabel("Device ID")
                        .accessibilityValue(ownId.isEmpty ? "Generating identity" : ownId)
                    if !model.snapshot.localAddresses.isEmpty {
                        Text(model.snapshot.localAddresses.joined(separator: "  •  "))
                            .font(.footnote.monospacedDigit())
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 2)
                            .accessibilityLabel("Local addresses: \(model.snapshot.localAddresses.joined(separator: ", "))")
                    }
                }
                .padding(.vertical, 4)

                Button {
                    model.copyDeviceID()
                    Haptics.tap(settings.haptics)
                } label: {
                    Label("Copy Device ID", systemImage: "doc.on.doc")
                }
                .disabled(ownId.isEmpty)
            }
            .meRow(transparency: transparency)
        } footer: {
            Label(
                model.identityIsHardwareBacked
                    ? "Identity key stored in the Secure Enclave"
                    : "Identity key stored in the Keychain",
                systemImage: model.identityIsHardwareBacked ? "lock.shield.fill" : "key.fill"
            )
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section {
            Group {
                Toggle(isOn: $settings.autoApply) {
                    MeRowLabel(
                        title: "Copy received items automatically",
                        subtitle: "Puts whatever arrives straight onto this iPhone's clipboard.",
                        systemImage: "arrow.down.doc.fill",
                        tint: .blue
                    )
                }
                Toggle(isOn: $settings.autoCapture) {
                    MeRowLabel(
                        title: "Send clipboard when ClipLink opens",
                        subtitle: "iOS only lets apps read the clipboard while they're open, so ClipLink sends it the moment you open the app.",
                        systemImage: "arrow.up.doc.fill",
                        tint: .green
                    )
                }
                if settings.autoCapture, Self.pasteAsksPermission {
                    MeSettingsNoticeRow(
                        message: "iOS asks before each paste unless you set Paste from Other Apps to Allow in Settings.",
                        systemImage: "info.circle.fill",
                        tint: .blue
                    )
                }
                Toggle(isOn: noticeNewCopiesBinding) {
                    MeRowLabel(
                        title: "Point out new copies",
                        subtitle: "Highlights the Paste button when you've copied something new.",
                        systemImage: "app.badge.fill",
                        tint: .orange
                    )
                }
            }
            .meRow(transparency: transparency)
        } header: {
            Text("Sync")
        }
    }

    /// The iOS 16+ paste-permission prompt (iOS 15 only shows a banner).
    private static var pasteAsksPermission: Bool {
        if #available(iOS 16, *) { return true }
        return false
    }

    private var noticeNewCopiesBinding: Binding<Bool> {
        Binding(
            get: { settings.noticeNewCopies },
            set: { newValue in
                settings.noticeNewCopies = newValue
                model.refreshClipboardHint()
            }
        )
    }

    // MARK: - Background (iOS only)

    private var backgroundSection: some View {
        Section {
            Group {
                Toggle(isOn: backgroundRefreshBinding) {
                    MeRowLabel(title: "Background refresh", systemImage: "arrow.triangle.2.circlepath", tint: .teal)
                }
                if let notice = backgroundRefreshNotice {
                    MeSettingsNoticeRow(message: notice.message, showsButton: notice.canFixInSettings)
                }
                Toggle(isOn: notifyBinding) {
                    MeRowLabel(
                        title: "Notify about new items",
                        subtitle: "Shows a notification when a background refresh brings something new.",
                        systemImage: "bell.badge.fill",
                        tint: .red
                    )
                }
                .disabled(!settings.backgroundRefresh)
                if settings.backgroundRefresh, notificationsDenied, settings.notifyBackgroundItems || notifyRequested {
                    MeSettingsNoticeRow(message: "Notifications are turned off for ClipLink in Settings.")
                }
            }
            .meRow(transparency: transparency)
        } header: {
            Text("Background")
        } footer: {
            Text("iOS wakes ClipLink a few times a day to catch up with your paired devices, so new items are waiting when you open it. iOS decides when this happens.")
        }
    }

    private var backgroundRefreshBinding: Binding<Bool> {
        Binding(
            get: { settings.backgroundRefresh },
            set: { model.setBackgroundRefresh($0) }
        )
    }

    private var notifyBinding: Binding<Bool> {
        Binding(
            get: { settings.notifyBackgroundItems },
            // Turning it on asks for notification permission first; the
            // switch follows once the answer is in.
            set: { enabled in
                notifyRequested = enabled
                model.setNotifyBackgroundItems(enabled)
            }
        )
    }

    private var backgroundRefreshNotice: (message: String, canFixInSettings: Bool)? {
        guard settings.backgroundRefresh else { return nil }
        if lowPowerMode {
            return ("Low Power Mode pauses background refresh until you turn it off.", false)
        }
        switch refreshStatus {
        case .available:
            return nil
        case .restricted:
            return ("Background App Refresh is restricted on this iPhone.", false)
        default:
            return ("Background App Refresh is turned off for ClipLink in Settings.", true)
        }
    }

    private func refreshSystemStatus() {
        refreshStatus = UIApplication.shared.backgroundRefreshStatus
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        Task { @MainActor in
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            notificationsDenied = status == .denied
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section {
            Group {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        MeRowLabel(title: "Theme", systemImage: "paintpalette.fill", tint: accentFill)
                        Spacer(minLength: 8)
                        Text(settings.accentTheme.name)
                            .foregroundColor(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    HStack(spacing: 0) {
                        ForEach(AccentTheme.allCases) { theme in
                            MeThemeSwatch(theme: theme, isSelected: theme == settings.accentTheme) {
                                select(theme)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.vertical, 6)

                Toggle(isOn: $settings.bottomGlow) {
                    MeRowLabel(
                        title: "Bottom glow",
                        subtitle: "A soft wash of your theme colour along the bottom of each page.",
                        systemImage: "rectangle.bottomthird.inset.filled",
                        tint: .purple
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        MeRowLabel(title: "Card transparency", systemImage: "square.on.square.dashed", tint: .cyan)
                        Spacer(minLength: 8)
                        Text("\(Int(settings.cardTransparency.rounded()))%")
                            .font(.body.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    .accessibilityHidden(true)
                    Slider(value: $settings.cardTransparency, in: 0...100, step: 5) {
                        Text("Card transparency")
                    }
                    .accessibilityValue("\(Int(settings.cardTransparency.rounded())) percent")
                }
                .padding(.vertical, 4)

                Toggle(isOn: hapticsBinding) {
                    MeRowLabel(title: "Haptics", systemImage: "hand.tap.fill", tint: .pink)
                }
            }
            .meRow(transparency: transparency)
        } header: {
            Text("Appearance")
        }
    }

    private func select(_ theme: AccentTheme) {
        guard theme != settings.accentTheme else { return }
        Haptics.tap(settings.haptics)
        withAnimation(.easeInOut(duration: 0.25)) {
            settings.accentTheme = theme
        }
    }

    private var hapticsBinding: Binding<Bool> {
        Binding(
            get: { settings.haptics },
            set: { newValue in
                settings.haptics = newValue
                Haptics.tap(newValue)
            }
        )
    }

    // MARK: - Pairing

    private var pairingSection: some View {
        Section {
            Group {
                Button {
                    model.pairingPresented = true
                } label: {
                    HStack(spacing: 12) {
                        MeRowLabel(title: "QR Code & Scan", systemImage: "qrcode.viewfinder", tint: .blue, titleColor: .primary)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(Color(UIColor.tertiaryLabel))
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityHint("Opens the pairing screen.")

                NavigationLink(destination: MePasscodeView()) {
                    HStack(spacing: 12) {
                        MeRowLabel(title: "Passcode", systemImage: "ellipsis.rectangle.fill", tint: .green)
                        Spacer(minLength: 8)
                        Text(model.snapshot.hasPassphrase ? "On" : "Off")
                            .foregroundColor(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }

                NavigationLink(destination: MeTailscaleView()) {
                    HStack(spacing: 12) {
                        MeRowLabel(title: "Tailscale IP", systemImage: "globe", tint: .indigo)
                        Spacer(minLength: 8)
                        Text(model.snapshot.tailscaleIP.isEmpty ? "Not set" : model.snapshot.tailscaleIP)
                            .font(.body.monospacedDigit())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .meRow(transparency: transparency)
        } header: {
            Text("Pairing")
        }
    }

    // MARK: - Network

    private var networkSection: some View {
        Section {
            Group {
                MeValueRow(
                    title: "Local Network",
                    systemImage: "network",
                    tint: .blue,
                    value: localNetworkValue,
                    valueColor: network.localNetwork == .denied ? .orange : .secondary
                )
                if network.localNetwork == .denied {
                    MeSettingsNoticeRow(message: "Turn on Local Network for ClipLink so it can reach devices on this Wi-Fi.")
                }
                MeValueRow(title: "Discovery", systemImage: "dot.radiowaves.left.and.right", tint: .green, value: discoveryValue)
                MeValueRow(
                    title: "Listening",
                    systemImage: "antenna.radiowaves.left.and.right",
                    tint: .orange,
                    value: network.listening ? "Port \(Wire.port)" : "Not listening"
                )
                MeValueRow(title: "Wi-Fi Address", systemImage: "wifi", tint: .blue, value: network.lanAddress ?? "Not on Wi-Fi")
                Button {
                    model.refreshNetwork()
                    model.showToast("Looking for devices on this network…")
                    Haptics.tap(settings.haptics)
                } label: {
                    MeRowLabel(title: "Find Devices Now", systemImage: "magnifyingglass", tint: accentFill, titleColor: .accentColor)
                }
            }
            .meRow(transparency: transparency)
        } header: {
            Text("Network")
        } footer: {
            networkFooter
        }
    }

    @ViewBuilder
    private var networkFooter: some View {
        if network.broadcast == .unavailable || network.lastError != nil {
            VStack(alignment: .leading, spacing: 6) {
                if network.broadcast == .unavailable {
                    Text("This network doesn't allow ClipLink to broadcast, so it contacts your devices directly instead.")
                }
                if let error = network.lastError {
                    Text(error)
                        .foregroundColor(.orange)
                }
            }
        }
    }

    private var localNetworkValue: String {
        switch network.localNetwork {
        case .allowed: return "Allowed"
        case .denied: return "Off"
        case .unknown: return "Checking…"
        }
    }

    private var discoveryValue: String {
        switch network.broadcast {
        case .available: return "Broadcast"
        case .unavailable: return "Direct"
        case .unknown: return "Starting…"
        }
    }

    // MARK: - Support

    private var supportSection: some View {
        Section {
            Group {
                NavigationLink(destination: MeDiagnosticsView()) {
                    MeRowLabel(title: "Diagnostics", systemImage: "waveform.path.ecg", tint: Color(UIColor.systemGray))
                }
                NavigationLink(destination: MeActivityLogView()) {
                    HStack(spacing: 12) {
                        MeRowLabel(title: "Activity Log", systemImage: "list.bullet.rectangle.fill", tint: Color(UIColor.systemGray))
                        Spacer(minLength: 8)
                        Text("\(model.snapshot.log.count)")
                            .font(.body.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .meRow(transparency: transparency)
        } header: {
            Text("Support")
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        Section {
            Button(role: .destructive) {
                confirmingClear = true
            } label: {
                MeRowLabel(title: "Clear Synced History", systemImage: "trash.fill", tint: .red)
            }
            .disabled(model.snapshot.items.isEmpty)
            .confirmationDialog("Clear synced history?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) {
                    model.clearHistory()
                    Haptics.success(settings.haptics)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes every synced item and any files saved for them from this iPhone. Paired devices keep their own copies, and may send them back when they next reconnect.")
            }
            .meRow(transparency: transparency)
        } header: {
            Text("Data")
        } footer: {
            VStack(spacing: 4) {
                Text("ClipLink — end-to-end encrypted, no servers.")
                Text(MeFormat.appVersion)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 28)
            .padding(.bottom, 8)
            .accessibilityElement(children: .combine)
        }
    }
}

/// One accent-theme swatch: a filled circle; the selected one gets a ring in
/// its own colour and a white checkmark. The whole cell is the tap target.
struct MeThemeSwatch: View {
    let theme: AccentTheme
    let isSelected: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 30

    var body: some View {
        let size = min(diameter, 40)
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(theme.fill)
                    .frame(width: size, height: size)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundColor(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(4)
            .overlay(
                Circle()
                    .strokeBorder(theme.color, lineWidth: 2)
                    .opacity(isSelected ? 1 : 0)
            )
            // Fills its sixth of the row and is at least 44pt tall, so the
            // gaps between swatches hit too (a fixed 44pt width wouldn't fit
            // six across a 320pt screen).
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        // Borderless: each swatch is its own tap target inside the row.
        .buttonStyle(.borderless)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
