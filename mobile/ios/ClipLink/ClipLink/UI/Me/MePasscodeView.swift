import SwiftUI

/// Me › Passcode: passcode auto-trust (the HarmonyOS flow). Devices with the
/// same passcode trust each other without a QR code.
struct MePasscodeView: View {
    /// Every device announces a proof derived from the passcode, so anyone on
    /// the network can try guesses against it offline. The key derivation has
    /// to stay as it is (the other platforms share it), so the floor is here.
    static let minimumLength = 8

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    @State private var passcode = ""
    @State private var changing = false
    @State private var confirmingClear = false
    @FocusState private var fieldFocused: Bool

    private var isSet: Bool { model.snapshot.hasPassphrase }
    private var showsStatus: Bool { isSet && !changing }
    /// What the engine derives the key from.
    private var trimmedPasscode: String { passcode.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isLongEnough: Bool { trimmedPasscode.count >= Self.minimumLength }
    private var canSubmit: Bool { isLongEnough && !model.passcodeBusy }

    /// Live guidance under the field: how far from the minimum, or a nudge
    /// away from an all-digit passcode.
    private var strengthHint: String? {
        let count = trimmedPasscode.count
        guard count > 0 else { return nil }
        if count < Self.minimumLength {
            let missing = Self.minimumLength - count
            return missing == 1 ? "1 more character needed." : "\(missing) more characters needed."
        }
        if trimmedPasscode.allSatisfy(\.isNumber) {
            return "Numbers alone are quick to guess — add some letters or words."
        }
        return nil
    }

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

                Button(role: .destructive) {
                    confirmingClear = true
                } label: {
                    Text("Clear Passcode")
                }
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
                .accessibilityHint(isLongEnough ? "" : "Needs at least \(Self.minimumLength) characters.")

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
                } else if let strengthHint {
                    Text(strengthHint)
                        .fontWeight(.semibold)
                }
                Text("Use at least \(Self.minimumLength) characters — a few words work well. Your devices announce a proof of the passcode on the network, so anyone nearby could try to guess a short one offline. If your other devices use a shorter passcode, change it there too.")
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
