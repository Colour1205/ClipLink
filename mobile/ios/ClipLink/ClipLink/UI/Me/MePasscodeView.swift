import SwiftUI

/// Me › Passcode: passcode auto-trust (the HarmonyOS flow). Devices with the
/// same passcode trust each other without a QR code. It can be set, changed
/// or cleared at any time; the next beacon and handshake use the new state.
struct MePasscodeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    @State private var passcode = ""
    @State private var changing = false
    @State private var confirmingClear = false
    @FocusState private var fieldFocused: Bool

    private var isSet: Bool { model.snapshot.hasPassphrase }
    private var showsStatus: Bool { isSet && !changing }
    /// The only rule, the same on every platform: not blank once trimmed
    /// (the engine derives the key from the trimmed passcode).
    private var isEntered: Bool { !passcode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSubmit: Bool { isEntered && !model.passcodeBusy }

    var body: some View {
        List {
            Section {
                MePasscodeIntro(accent: settings.accentTheme.fill)
                    .meRow(transparency: settings.cardTransparency)
            }

            if showsStatus {
                statusSection
            } else {
                entrySection
            }
        }
        .mePage(glow: settings.bottomGlow, accent: settings.accentTheme.color)
        .tint(settings.accentTheme.color)
        .navigationTitle("Passcode")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.default, value: showsStatus)
        .onDisappear {
            changing = false
            passcode = ""
        }
    }

    // MARK: - Passcode set

    private var statusSection: some View {
        Section {
            Group {
                Label {
                    Text("Passcode is set on this iPhone.")
                        .foregroundColor(Theme.connected)
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(Theme.connected)
                }

                Button {
                    passcode = ""
                    changing = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { fieldFocused = true }
                } label: {
                    Text("Change Passcode")
                }
                // Both wait out a set that's still deriving (the user left
                // and came back): it would land after a clear and undo it.
                .disabled(model.passcodeBusy)

                Button(role: .destructive) {
                    confirmingClear = true
                } label: {
                    Text("Clear Passcode")
                }
                .disabled(model.passcodeBusy)
                .confirmationDialog("Clear passcode?", isPresented: $confirmingClear, titleVisibility: .visible) {
                    Button("Clear Passcode", role: .destructive) {
                        model.clearPassphrase()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("New devices won't trust this iPhone automatically any more. Devices you've already paired stay paired.")
                }
            }
            .meRow(transparency: settings.cardTransparency)
        } footer: {
            footer
        }
    }

    // MARK: - Entering a passcode

    private var entrySection: some View {
        Section {
            Group {
                SecureField(isSet ? "Enter a new shared passcode" : "Enter a shared passcode", text: $passcode)
                    .focused($fieldFocused)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .submitLabel(.done)
                    .onSubmit(submit)
                    .disabled(model.passcodeBusy)
                    .accessibilityLabel("Passcode")

                Button(action: submit) {
                    HStack(spacing: 8) {
                        if model.passcodeBusy {
                            ProgressView()
                            Text("Setting…")
                        } else {
                            Text("Set Passcode")
                        }
                    }
                }
                .disabled(!canSubmit)
                .accessibilityHint(isEntered ? "" : "Enter a passcode first.")

                if changing {
                    Button("Cancel") {
                        passcode = ""
                        fieldFocused = false
                        changing = false
                    }
                    .disabled(model.passcodeBusy)
                }
            }
            .meRow(transparency: settings.cardTransparency)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if model.passcodeBusy {
                    Text("Deriving the key takes a moment.")
                }
                Text("Your devices announce a proof of the passcode on the network, so a longer passcode is harder for anyone nearby to guess.")
                footer
            }
        }
    }

    private var footer: some View {
        Text("Use the same passcode on your Windows PC, Android and HarmonyOS devices.")
    }

    private func submit() {
        guard canSubmit else { return }
        fieldFocused = false
        model.setPassphrase(passcode) { ok in
            guard ok else { return }
            passcode = ""
            changing = false
            Haptics.success(settings.haptics)
        }
    }
}

/// Header card: glyph, title and the explanation.
private struct MePasscodeIntro: View {
    let accent: Color

    var body: some View {
        VStack(spacing: 10) {
            MeIconTile(systemImage: "ellipsis.rectangle.fill", color: accent, baseSize: 54)
            Text("Passcode Auto-Trust")
                .font(.title3.weight(.semibold))
            Text("Devices with the same passcode trust each other automatically — no QR code needed. The passcode never leaves this iPhone; only a proof derived from it is shared.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
