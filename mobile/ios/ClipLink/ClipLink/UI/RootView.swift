import SwiftUI

/// Three tabs - Synced, Devices, Me - as on Android and HarmonyOS, in the
/// standard iOS tab bar, each tab with its own navigation stack.
struct RootView: View {
    /// Not watched (see RootStore): only the startup error and the pairing
    /// sheet's state are, so a snapshot no longer re-runs the tab view.
    private var model: AppModel { AppModel.shared }
    @ObservedObject private var root = AppModel.shared.root
    @EnvironmentObject private var settings: AppSettings

    enum Tab: Hashable { case synced, devices, me }

    @State private var tab: Tab = RootView.initialTab

    private static var initialTab: Tab {
        #if DEBUG
        // Test hook (Debug builds only): `-ClipLinkDebugTab devices|me`.
        switch UserDefaults.standard.string(forKey: "ClipLinkDebugTab") {
        case "devices": return .devices
        case "me": return .me
        default: return .synced
        }
        #else
        return .synced
        #endif
    }

    var body: some View {
        Group {
            if let error = root.value.startupError {
                StartupErrorView(message: error) { model.retryStartup() }
            } else {
                TabView(selection: $tab) {
                    SyncedView()
                        .tabItem { Label("Synced", systemImage: "doc.on.clipboard") }
                        .tag(Tab.synced)
                    DevicesView()
                        .tabItem { Label("Devices", systemImage: "laptopcomputer.and.iphone") }
                        .tag(Tab.devices)
                    MeView()
                        .tabItem { Label("Me", systemImage: "person.crop.circle") }
                        .tag(Tab.me)
                }
            }
        }
        .accentColor(settings.accentTheme.color)
        // Toasts get a window of their own, above this sheet and anything
        // else presented over the app.
        .background(ToastWindowHost(model: model))
        .sheet(isPresented: pairingPresented) {
            PairingView()
                .environmentObject(model)
                .environmentObject(settings)
                .accentColor(settings.accentTheme.color)
        }
    }

    /// Read from the root store, written through the model (whose setter
    /// does what opening and closing the sheet means).
    private var pairingPresented: Binding<Bool> {
        Binding(get: { root.value.pairingPresented }, set: { model.pairingPresented = $0 })
    }
}

/// Shown when the identity couldn't be loaded - usually a Keychain that
/// isn't available yet (before the first unlock after a restart), which a
/// retry fixes without quitting the app.
private struct StartupErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            EmptyStateView(systemImage: "exclamationmark.lock", title: "ClipLink can't start", message: message)
            Button(action: retry) {
                Text("Try Again")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
