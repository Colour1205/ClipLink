import SwiftUI
import UIKit

/// Me › Diagnostics: a self-test (identity, signing, storage), the live engine
/// status, and the protocol facts every ClipLink shares.
struct MeDiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    @State private var result: String?
    @State private var running = false

    private var snapshot: EngineSnapshot { model.snapshot }
    private var passed: Bool { result?.hasPrefix("Self-test passed") == true }

    var body: some View {
        List {
            selfTestSection
            engineSection
            protocolSection
        }
        .mePage(glow: settings.bottomGlow, accent: settings.accentTheme.color)
        .tint(settings.accentTheme.color)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Self-test

    private var selfTestSection: some View {
        Section {
            Group {
                Button(action: runSelfTest) {
                    HStack(spacing: 12) {
                        MeRowLabel(title: "Run Self-Test", systemImage: "waveform.path.ecg", tint: .pink, titleColor: .accentColor)
                        Spacer(minLength: 8)
                        if running { ProgressView() }
                    }
                }
                .disabled(running)

                if let result {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundColor(passed ? .green : .red)
                            .accessibilityHidden(true)
                        Text(result)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            }
            .meRow(transparency: settings.cardTransparency)
        } footer: {
            Text("Checks that this iPhone's identity key, message signing and storage are all working.")
        }
    }

    private func runSelfTest() {
        running = true
        result = nil
        Task { @MainActor in
            // Let the spinner draw first - the key lookup can take a moment.
            try? await Task.sleep(nanoseconds: 150_000_000)
            let outcome = model.runSelfTest()
            withAnimation { result = outcome }
            running = false
            if outcome.hasPrefix("Self-test passed") {
                Haptics.success(settings.haptics)
            } else if settings.haptics {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    // MARK: - Engine

    private var engineSection: some View {
        Section {
            Group {
                MeDetailRow(title: "Status", value: snapshot.network.running ? "Running" : "Stopped")
                MeDetailRow(title: "Listening", value: snapshot.network.listening ? "Port \(Wire.port)" : "Not listening")
                MeDetailRow(title: "Discovery", value: discovery)
                MeDetailRow(title: "Local Network", value: localNetwork)
                MeDetailRow(title: "Wi-Fi Address", value: snapshot.network.lanAddress ?? "Not on Wi-Fi", monospaced: snapshot.network.lanAddress != nil)
                MeDetailRow(title: "Connected Devices", value: "\(snapshot.connectedCount)")
                MeDetailRow(title: "Trusted Devices", value: "\(snapshot.devices.filter(\.trusted).count)")
                MeDetailRow(title: "Synced Items", value: "\(snapshot.items.count)")
                MeDetailRow(title: "Identity Key", value: model.identityIsHardwareBacked ? "Secure Enclave" : "Keychain")
                MeDetailRow(title: "Passcode", value: snapshot.hasPassphrase ? "On" : "Off")
                if let error = snapshot.network.lastError {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last Error")
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .meRow(transparency: settings.cardTransparency)
        } header: {
            Text("Engine")
        }
    }

    private var discovery: String {
        switch snapshot.network.broadcast {
        case .available: return "Broadcast"
        case .unavailable: return "Direct"
        case .unknown: return "Starting…"
        }
    }

    private var localNetwork: String {
        switch snapshot.network.localNetwork {
        case .allowed: return "Allowed"
        case .denied: return "Off"
        case .unknown: return "Checking…"
        }
    }

    // MARK: - Protocol

    private var protocolSection: some View {
        Section {
            Group {
                MeDetailRow(title: "Ports", value: "\(Wire.port) TCP · UDP")
                MeDetailRow(title: "Encryption", value: "AES-256-GCM")
                MeDetailRow(title: "Key Exchange", value: "ECDH P-256")
                MeDetailRow(title: "Signatures", value: "ECDSA P-256")
                MeDetailRow(title: "Passcode Key", value: "PBKDF2 · \(MeFormat.grouped(Int(Wire.passphraseIterations)))")
            }
            .meRow(transparency: settings.cardTransparency)
        } header: {
            Text("Protocol")
        } footer: {
            Text("The same on Windows, Android and HarmonyOS. Everything travels directly between your devices — there are no servers.")
        }
    }
}
