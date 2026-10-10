import SwiftUI
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Background tasks must be registered before launch finishes.
        BackgroundSync.register()
        // Notification buttons (pairing requests) must reach us even when this
        // launch was caused by tapping one.
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        Notifier.registerCategories()
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
                .onAppear {
                    // `onChange` only reports changes: a launch slow enough for
                    // the scene to be active before this view exists would
                    // never hear about it (becameActive is idempotent).
                    if UIApplication.shared.applicationState == .active {
                        model.scenePhaseChanged(.active)
                    }
                }
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
