import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Background tasks must be registered before launch finishes.
        BackgroundSync.register()
        return true
    }
}

@main
struct ClipLinkApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .onOpenURL { url in
                    // "Open in ClipLink" / Copy to ClipLink from Files or a share sheet.
                    model.openFile(at: url)
                }
        }
        .onChange(of: scenePhase) { phase in
            model.scenePhaseChanged(phase)
        }
    }
}
