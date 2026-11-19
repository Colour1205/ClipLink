import SwiftUI

/// Me › Device Name: what your other devices call this one (sent in beacons,
/// handshakes and the pairing code). Like the Tailscale IP, it edits a local
/// draft and publishes it only on Save.
struct MeDeviceNameView: View {
    /// Not watched: only the Me fields are (see MeStore).
    private var model: AppModel { AppModel.shared }
    @ObservedObject private var me = AppModel.shared.me
    @EnvironmentObject private var settings: AppSettings

    @State private var draft = ""
    @State private var loaded = false
    @FocusState private var fieldFocused: Bool

    private var saved: String { me.value.deviceNameOverride }
    /// The OS default, used while nothing is saved.
    private var defaultName: String {
        me.value.systemDeviceName.isEmpty ? ThisDeviceNoun.current : me.value.systemDeviceName
    }
    /// The draft as it would be stored: trimmed, capped at 64 characters.
    private var cleanedDraft: String { DeviceName.clean(draft) ?? "" }

    var body: some View {
        List {
            Section {
                Group {
                    TextField(defaultName, text: $draft)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                        .submitLabel(.done)
                        .focused($fieldFocused)
                        .onSubmit(save)
                        .accessibilityLabel("Device name")

                    Button("Save", action: save)
                        .disabled(cleanedDraft.isEmpty || cleanedDraft == saved)

                    if !saved.isEmpty {
                        Button("Use Default Name", role: .destructive) {
                            fieldFocused = false
                            draft = ""
                            model.setDeviceName("")
                        }
                    }
                }
                .meRow(transparency: settings.cardTransparency)
            } header: {
                Text("This \(ThisDeviceNoun.current)'s Name")
            } footer: {
                Text(saved.isEmpty
                     ? "Your other devices see this \(ThisDeviceNoun.current) as “\(defaultName)”. iOS only gives apps a generic name, so pick one that tells your devices apart."
                     : "Your other devices see this \(ThisDeviceNoun.current) as “\(saved)”. They pick up a change the next time they hear from it.")
            }
        }
        .mePage(glow: settings.bottomGlow, accent: settings.accentTheme.color)
        .tint(settings.accentTheme.color)
        .navigationTitle("Device Name")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = saved
        }
    }

    private func save() {
        guard !cleanedDraft.isEmpty, cleanedDraft != saved else { return }
        fieldFocused = false
        model.setDeviceName(cleanedDraft)
    }
}
