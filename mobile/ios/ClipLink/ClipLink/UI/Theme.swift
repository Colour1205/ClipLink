import SwiftUI
import UIKit

/// The six accent themes from the HarmonyOS app (Me › Appearance › Theme),
/// same keys and colours, with their dark-mode variants.
enum AccentTheme: String, CaseIterable, Identifiable {
    case navy, teal, green, orange, rose, violet

    var id: String { rawValue }

    var name: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// Tint: the HarmonyOS palette, the dark variants lightened to read well as
    /// text and glyphs on dark backgrounds.
    private var hex: (light: UInt32, dark: UInt32) {
        switch self {
        case .navy: return (0x5468D4, 0x6F81E6)
        case .teal: return (0x1E8C84, 0x4DB6AC)
        case .green: return (0x3D8F5A, 0x66BB80)
        case .orange: return (0xD9692F, 0xF0935E)
        case .rose: return (0xC24D7C, 0xE07BA3)
        case .violet: return (0x7B55C7, 0xA084E0)
        }
    }

    /// Fills under white text or glyphs, in both appearances: the light hex,
    /// darkened where it fell short, so white on it is at least 4.5:1 (the
    /// lightened dark variants only reach 2.3-3.5:1).
    private var fillHex: UInt32 {
        switch self {
        case .navy: return 0x5468D4
        case .teal: return 0x1A7A73
        case .green: return 0x2F7A4A
        case .orange: return 0xB8561F
        case .rose: return 0xC24D7C
        case .violet: return 0x7B55C7
        }
    }

    /// Increase Contrast in dark mode: between the tint and the fill, so it
    /// stays 4.5:1 as text on dark cards and reaches 3:1 under white bold
    /// labels and glyphs (the tint also colours prominent buttons).
    private var highContrastDarkHex: UInt32 {
        switch self {
        case .navy: return 0x6F81E6
        case .teal: return 0x349890
        case .green: return 0x4A9A65
        case .orange: return 0xD1713B
        case .rose: return 0xD26691
        case .violet: return 0x9778DA
        }
    }

    var uiColor: UIColor {
        let (light, dark) = hex
        let fill = fillHex, highContrastDark = highContrastDarkHex
        return UIColor { trait in
            let high = trait.accessibilityContrast == .high
            if trait.userInterfaceStyle == .dark {
                return UIColor(hex: high ? highContrastDark : dark)
            }
            // In light mode the fill also passes 4.5:1 as text on white.
            return UIColor(hex: high ? fill : light)
        }
    }

    var color: Color { Color(uiColor) }

    /// For surfaces under white content (icon tiles, swatches, filled
    /// buttons); keep `color` for text and glyphs in the accent.
    var fillUIColor: UIColor { UIColor(hex: fillHex) }

    var fill: Color { Color(fillUIColor) }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Visual tokens shared by every screen. Surfaces follow iOS's grouped style:
/// cards are `secondarySystemGroupedBackground` on a
/// `systemGroupedBackground` page, like Settings.
enum Theme {
    static let cardRadius: CGFloat = 18
    static let smallRadius: CGFloat = 12
    static let pagePadding: CGFloat = 16
    static let cardSpacing: CGFloat = 10

    static let page = Color(UIColor.systemGroupedBackground)
    static let card = UIColor.secondarySystemGroupedBackground
    /// systemGreen is only ~2.2:1 as text on a light card, so light mode uses
    /// a deeper green (~5:1); dark mode keeps systemGreen.
    static let connected = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.systemGreen.resolvedColor(with: trait)
            : UIColor(hex: 0x1E7F36)
    })
}

extension View {
    /// Card surface honouring the "Card transparency" setting: only the fill
    /// fades, never the content (HarmonyOS' cardFill()).
    func cardBackground(transparency: Double, radius: CGFloat = Theme.cardRadius) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color(Theme.card).opacity(1 - min(max(transparency, 0), 95) / 100))
        )
    }

    /// Page background with the optional accent "bottom glow".
    func pageBackground(glow: Bool, accent: Color) -> some View {
        background(PageBackground(glow: glow, accent: accent).ignoresSafeArea())
    }
}

/// HarmonyOS' bottom glow: the accent at 13% alpha along the bottom edge,
/// fading to nothing ~460pt up with a smoothstep curve.
struct PageBackground: View {
    let glow: Bool
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Theme.page
                if glow {
                    let height = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
                    let fraction = height > 0 ? min(1, (proxy.safeAreaInsets.bottom + 460) / height) : 0.55
                    LinearGradient(stops: Self.stops(fraction: fraction, accent: accent), startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    static func stops(fraction: CGFloat, accent: Color) -> [Gradient.Stop] {
        var stops: [Gradient.Stop] = [.init(color: accent.opacity(0), location: 0)]
        for i in stride(from: 8, through: 0, by: -1) {
            let t = CGFloat(i) / 8
            let eased = t * t * (3 - 2 * t)
            stops.append(.init(color: accent.opacity(0.13 * (1 - eased)), location: 1 - fraction * t))
        }
        return stops
    }
}

enum Haptics {
    static func tap(_ enabled: Bool) {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success(_ enabled: Bool) {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

/// Relative + absolute time labels ("14:05:32" today, "Yesterday 09:14",
/// "12 Sep 09:14") - local time, unlike HarmonyOS' UTC HH:MM.
enum TimeLabel {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM jj:mm")
        return f
    }()

    static func short(_ date: Date?) -> String {
        guard let date else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return time.string(from: date) }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time.string(from: date))" }
        return dayTime.string(from: date)
    }

    static func full(_ date: Date?) -> String {
        guard let date else { return "" }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .medium)
    }
}

enum ByteSize {
    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
