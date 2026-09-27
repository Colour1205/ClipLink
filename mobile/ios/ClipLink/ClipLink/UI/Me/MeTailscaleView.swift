import SwiftUI

/// Me › Tailscale IP. Edits a local draft and publishes it only on Save, so
/// half-typed text never reaches the pairing code or beacons (the HarmonyOS
/// quirk this avoids).
struct MeTailscaleView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    @State private var draft = ""
    @State private var loaded = false
    @State private var detected: String?
    @FocusState private var fieldFocused: Bool

    private var saved: String { model.snapshot.tailscaleIP }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
            Section {
                MeTailscaleIntro(accent: settings.accentTheme.fill)
                    .meRow(transparency: settings.cardTransparency)
            }

            if let detected, detected != saved {
                Section {
                    Button {
                        draft = detected
                        Haptics.tap(settings.haptics)
                    } label: {
                        HStack(spacing: 12) {
                            MeRowLabel(title: "Use detected address", systemImage: "wand.and.stars", tint: .indigo, titleColor: .accentColor)
                            Spacer(minLength: 8)
                            Text(detected)
                                .font(.body.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                    .accessibilityLabel("Use detected address \(detected)")
                    .meRow(transparency: settings.cardTransparency)
                } footer: {
                    Text("Tailscale is running on this iPhone, so ClipLink can fill this in for you.")
                }
            }

            Section {
                Group {
                    TextField("100.x.y.z", text: $draft)
                        .font(.body.monospacedDigit())
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .submitLabel(.done)
                        .focused($fieldFocused)
                        .onSubmit(save)
                        .accessibilityLabel("Tailscale IP")

                    Button("Save", action: save)
                        .disabled(trimmedDraft.isEmpty || trimmedDraft == saved)

                    if !saved.isEmpty {
                        Button("Clear", role: .destructive) {
                            fieldFocused = false
                            draft = ""
                            model.saveTailscaleIP("")
                        }
                    }
                }
                .meRow(transparency: settings.cardTransparency)
            } header: {
                Text("This iPhone's Tailscale IP")
            } footer: {
                Text(saved.isEmpty
                     ? "Not set. Paired devices can only reach this iPhone on the same Wi-Fi."
                     : "Saved: \(saved). It's included in your pairing QR code.")
            }
        }
        .mePage(glow: settings.bottomGlow, accent: settings.accentTheme.color)
        .tint(settings.accentTheme.color)
        .navigationTitle("Tailscale IP")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            detected = model.detectedTailscaleIP
            guard !loaded else { return }
            loaded = true
            draft = saved
        }
    }

    private func save() {
        guard !trimmedDraft.isEmpty, trimmedDraft != saved else { return }
        fieldFocused = false
        model.saveTailscaleIP(trimmedDraft)
    }
}

private struct MeTailscaleIntro: View {
    let accent: Color

    var body: some View {
        VStack(spacing: 10) {
            MeIconTile(systemImage: "globe", color: accent, baseSize: 54)
            Text("Reach This iPhone Anywhere")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Paired devices can reach this iPhone over Tailscale when you're not on the same Wi-Fi. Enter this iPhone's Tailscale IP (100.x.y.z).")
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
