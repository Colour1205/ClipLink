import SwiftUI
import UIKit

/// The pairing sheet. Being on screen IS pairing mode (AppModel turns it on
/// and off with `pairingPresented`): this device's QR code, a scanner for the
/// other device's code, and pair-by-address for devices without a camera.
struct PairingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    @State private var address = ""
    @State private var scanning = false
    @FocusState private var addressFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL

    private var accent: Color { settings.accentTheme.color }
    private var payload: String { model.snapshot.pairingPayload }
    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        if let request = model.snapshot.pairingRequest {
                            requestCard(request)
                                .id(PairingAnchor.request)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        explainerCard
                        if model.snapshot.network.localNetwork == .denied {
                            localNetworkCard
                        }
                        qrCard
                        scanButton
                        addressCard
                        if let status = model.pairStatus {
                            statusCard(status)
                                .id(PairingAnchor.status)
                                .transition(.opacity)
                        }
                        Text("Devices on the same Wi-Fi pair automatically while both pairing screens are open — codes are only needed when they can't find each other. Devices with the same passcode (Me › Passcode) pair with no prompts at all.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.snapshot.pairingRequest)
                    .animation(.easeInOut(duration: 0.2), value: model.pairStatus)
                }
                .onChange(of: model.snapshot.pairingRequest) { request in
                    guard request != nil else { return }
                    Haptics.tap(settings.haptics)
                    // The scanner covers the request card (and nothing can
                    // present over it): close it so the request can be
                    // answered. Announce once it has gone, or its dismissal
                    // cuts the announcement off.
                    let wasScanning = scanning
                    scanning = false
                    withAnimation { proxy.scrollTo(PairingAnchor.request, anchor: .top) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + (wasScanning ? 0.6 : 0)) {
                        UIAccessibility.post(notification: .announcement, argument: "Pairing request received.")
                    }
                }
                .onChange(of: model.pairStatus) { status in
                    guard let status, !model.pairInProgress else { return }
                    withAnimation { proxy.scrollTo(PairingAnchor.status, anchor: .bottom) }
                    UIAccessibility.post(notification: .announcement, argument: status)
                }
            }
            .pageBackground(glow: settings.bottomGlow, accent: accent)
            .navigationTitle("Pair a Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.pairingPresented = false }
                }
            }
        }
        .navigationViewStyle(.stack)
        // Closing the sheet closes pairing mode, which rejects a pending
        // request: make that an explicit Reject or Done, never a stray swipe.
        .interactiveDismissDisabled(model.snapshot.pairingRequest != nil)
        .fullScreenCover(isPresented: $scanning) {
            PairingScannerView(onCode: scanned, onCancel: { scanning = false })
        }
    }

    // MARK: - Cards

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground(transparency: settings.cardTransparency)
    }

    /// Who's asking: the name is whatever that device chose, so its short id
    /// goes beside it (and the address, when known) - a copied name can't
    /// pass for a device you know.
    private func requester(_ request: PairingRequest) -> String {
        let id = DeviceLabel.short(request.deviceId)
        let name = model.name(for: request.deviceId)
        let who = name == id ? id : "\(name) (\(id))"
        return who + (request.address.map { " at \($0)" } ?? "")
    }

    /// Inline Accept / Reject, like Android's prompt card: the request only
    /// ever arrives while this sheet is up, and the root view can't present
    /// an alert over its own sheet.
    private func requestCard(_ request: PairingRequest) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("Pairing Request")
                        .font(.headline)
                } icon: {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .foregroundColor(accent)
                }
                Text("\(requester(request)) wants to pair with this \(ThisDeviceNoun.current). Only accept if you expect this.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button {
                        Haptics.tap(settings.haptics)
                        model.rejectPairing()
                    } label: {
                        Text("Reject").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        Haptics.success(settings.haptics)
                        model.acceptPairing()
                    } label: {
                        Text("Accept").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(accent, lineWidth: 1.5)
        )
    }

    private var explainerCard: some View {
        card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundColor(accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Keep this screen open on both devices.")
                        .font(.subheadline.weight(.semibold))
                    Text("A pairing request only reaches this \(ThisDeviceNoun.current) while it's open, and nothing is trusted until you accept it on both sides.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.snapshot.pairingOpen {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Theme.connected)
                                .frame(width: 8, height: 8)
                            Text("Pairing mode on")
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(Theme.connected)
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var localNetworkCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("Local Network access is off")
                        .font(.headline)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                }
                // Same path as the engine's pairing error (Open Settings lands
                // on Settings › ClipLink, which has the same switch).
                Text("ClipLink needs it to find your devices. Turn it on in Settings › Privacy & Security › Local Network.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var qrCard: some View {
        card {
            VStack(spacing: 14) {
                Text("This \(ThisDeviceNoun.current)'s Code")
                    .font(.headline)
                PairingQRCodeView(payload: payload)
                Text("Scan this on the other device with its pairing screen open.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                ownAddresses
                if !payload.isEmpty {
                    // Middle truncation keeps both ends readable, whichever
                    // key the JSON happens to start with.
                    Text(payload)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .accessibilityLabel("Pairing info")
                        .accessibilityValue(payload)
                }
                qrActions
                    .disabled(payload.isEmpty)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// This device's addresses in full - the raw pairing info can truncate,
    /// and a device without a camera (Windows) pairs by typing one of them.
    @ViewBuilder
    private var ownAddresses: some View {
        let rows: [(title: String, value: String)] = [
            ("Wi-Fi", model.snapshot.network.lanAddress ?? ""),
            ("Tailscale", model.snapshot.tailscaleIP),
        ].filter { !$0.value.isEmpty }
        if !rows.isEmpty {
            VStack(spacing: 6) {
                ForEach(rows, id: \.title) { row in
                    HStack {
                        Text(row.title)
                            .foregroundColor(.secondary)
                        Spacer(minLength: 12)
                        Text(row.value)
                            .font(.subheadline.monospacedDigit())
                            .textSelection(.enabled)
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private var qrActions: some View {
        let copy = Button {
            Haptics.tap(settings.haptics)
            model.copyPairingInfo()
        } label: {
            Label("Copy Pairing Info", systemImage: "doc.on.doc")
        }
        let share = Button {
            PairingShare.present([payload])
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .accessibilityLabel("Share Pairing Info")

        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                copy
                share
            }
            .buttonStyle(.bordered)
        } else {
            HStack(spacing: 10) {
                copy
                share
            }
            .buttonStyle(.bordered)
        }
    }

    private var scanButton: some View {
        Button {
            addressFocused = false
            Haptics.tap(settings.haptics)
            scanning = true
        } label: {
            Label("Scan a Device's QR Code", systemImage: "qrcode.viewfinder")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(model.pairInProgress)
    }

    private var addressCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pair by Address")
                    .font(.headline)
                Text("No camera on the other device (like Windows)? Enter its IP address or paste its pairing info.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField("192.168.1.20 or pairing info", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .submitLabel(.go)
                        .onSubmit(connect)
                        .focused($addressFocused)
                        .disabled(model.pairInProgress)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                                .fill(Color(UIColor.tertiarySystemFill))
                        )
                        .accessibilityLabel("Address or pairing info")
                    pasteButton
                        .disabled(model.pairInProgress)
                }
                Button(action: connect) {
                    HStack(spacing: 8) {
                        if model.pairInProgress {
                            ProgressView()
                            Text("Connecting…")
                        } else {
                            Text("Connect")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(trimmedAddress.isEmpty || model.pairInProgress)
            }
        }
    }

    @ViewBuilder
    private var pasteButton: some View {
        if #available(iOS 16.0, *) {
            // The system Paste button reads the pasteboard without iOS 16's
            // "Allow Paste" prompt.
            PasteButton(payloadType: String.self) { strings in
                let text = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                Task { @MainActor in
                    if !text.isEmpty { address = text }
                }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.roundedRectangle)
        } else {
            Button {
                if let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    address = text
                } else {
                    model.showToast("Nothing to paste.")
                }
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
                    .labelStyle(.iconOnly)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Paste")
        }
    }

    private func statusCard(_ status: String) -> some View {
        card {
            HStack(alignment: .top, spacing: 10) {
                if model.pairInProgress {
                    ProgressView()
                } else {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(accent)
                        .accessibilityHidden(true)
                }
                Text(status)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Actions

    private func connect() {
        let text = trimmedAddress
        guard !text.isEmpty, !model.pairInProgress else { return }
        addressFocused = false
        Haptics.tap(settings.haptics)
        model.pair(with: text)
    }

    private func scanned(_ code: String) {
        Haptics.success(settings.haptics)
        scanning = false
        model.pair(with: code)
    }
}

/// This device in user-facing copy: "iPad" or "iPhone", by idiom (the app
/// runs on both, and UIDevice.model can read "iPod touch").
enum ThisDeviceNoun {
    static var current: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
}

private enum PairingAnchor: Hashable {
    case request, status
}

/// Presents the system share sheet from the top-most view controller - a
/// SwiftUI sheet can't size UIActivityViewController properly on iOS 15.
@MainActor
enum PairingShare {
    static func present(_ items: [Any]) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first,
              var top = window.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }
}
