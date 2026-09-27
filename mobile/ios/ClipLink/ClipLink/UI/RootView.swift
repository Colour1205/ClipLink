import SwiftUI

/// Three tabs - Synced, Devices, Me - as on Android and HarmonyOS, in the
/// standard iOS tab bar, each tab with its own navigation stack.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
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
            if let error = model.startupError {
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
        .sheet(isPresented: $model.pairingPresented) {
            PairingView()
                .environmentObject(model)
                .environmentObject(settings)
                .accentColor(settings.accentTheme.color)
        }
        // The pairing prompt lives inside PairingView: a request can only reach
        // this device while that sheet is open, and an alert here couldn't be
        // shown over the sheet anyway.
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
