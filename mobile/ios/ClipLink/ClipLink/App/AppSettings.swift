import Combine
import Foundation

/// User preferences (UserDefaults). Keys and defaults follow Android's
/// DeviceSettings / HarmonyOS' DeviceSettings where a setting exists there.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    enum SyncedLayout: String { case grid, list }

    /// "Copy received items automatically" - auto_apply, default on everywhere.
    @Published var autoApply: Bool { didSet { defaults.set(autoApply, forKey: "auto_apply") } }
    /// "Send my clipboard when I open ClipLink" - Android's auto_capture.
    @Published var autoCapture: Bool { didSet { defaults.set(autoCapture, forKey: "auto_capture") } }
    /// "Point out new copies" - HarmonyOS' notice_new_copies.
    @Published var noticeNewCopies: Bool { didSet { defaults.set(noticeNewCopies, forKey: "notice_new_copies") } }
    /// iOS only: let the system wake ClipLink to catch up in the background.
    @Published var backgroundRefresh: Bool { didSet { defaults.set(backgroundRefresh, forKey: "background_refresh") } }
    /// iOS only: a notification when a background refresh brings something new.
    @Published var notifyBackgroundItems: Bool { didSet { defaults.set(notifyBackgroundItems, forKey: "notify_background_items") } }
    /// HarmonyOS' accent_theme ("" means navy there too).
    @Published var accentTheme: AccentTheme { didSet { defaults.set(accentTheme.rawValue, forKey: "accent_theme") } }
    @Published var bottomGlow: Bool { didSet { defaults.set(bottomGlow, forKey: "bottom_glow") } }
    /// 0...100, step 5 - HarmonyOS' card_transparency.
    @Published var cardTransparency: Double { didSet { defaults.set(cardTransparency, forKey: "card_transparency") } }
    @Published var syncedLayout: SyncedLayout { didSet { defaults.set(syncedLayout.rawValue, forKey: "synced_layout") } }
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }

    init() {
        let defaults = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        autoApply = bool("auto_apply", true)
        autoCapture = bool("auto_capture", true)
        noticeNewCopies = bool("notice_new_copies", true)
        backgroundRefresh = bool("background_refresh", true)
        notifyBackgroundItems = bool("notify_background_items", false)
        accentTheme = AccentTheme(rawValue: defaults.string(forKey: "accent_theme") ?? "") ?? .navy
        bottomGlow = bool("bottom_glow", true)
        cardTransparency = defaults.object(forKey: "card_transparency") as? Double ?? 0
        syncedLayout = SyncedLayout(rawValue: defaults.string(forKey: "synced_layout") ?? "") ?? .grid
        haptics = bool("haptics", true)
    }
}
