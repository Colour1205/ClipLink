import SwiftUI
import UIKit

// Building blocks shared by the Me tab and its sub-screens: Settings-style
// icon tiles and rows, the themed page/row backgrounds, and small helpers.

/// A white SF Symbol on a rounded, colour-filled square - the glyph style of
/// the iOS Settings app. Scales with Dynamic Type.
struct MeIconTile: View {
    let systemImage: String
    let color: Color
    var baseSize: CGFloat = 29

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let size = baseSize * min(scale, 1.6)
        Image(systemName: systemImage)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .fill(color)
            )
            .accessibilityHidden(true)
    }
}

/// Icon + title laid out like a Settings row: the icon centred against the
/// whole title block, and (iOS 16+) the separator aligned to the title.
struct MeTileLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 14) {
            configuration.icon
            if #available(iOS 16, *) {
                configuration.title
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            } else {
                configuration.title
            }
        }
    }
}

/// The standard Me row label: tile, title, optional secondary line.
struct MeRowLabel: View {
    let title: String
    var subtitle: String?
    let systemImage: String
    let tint: Color
    /// Set for rows inside a `Button`, which would otherwise tint the title.
    var titleColor: Color?

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundColor(isEnabled ? titleColor : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } icon: {
            MeIconTile(systemImage: systemImage, color: tint)
                .opacity(isEnabled ? 1 : 0.45)
        }
        .labelStyle(MeTileLabelStyle())
    }
}

/// A read-only row: label on the left, value on the right.
struct MeValueRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    let value: String
    var valueColor: Color = .secondary

    var body: some View {
        HStack(spacing: 12) {
            MeRowLabel(title: title, systemImage: systemImage, tint: tint)
            Spacer(minLength: 8)
            Text(value)
                .foregroundColor(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A plain label/value row without an icon (sub-screens).
struct MeDetailRow: View {
    let title: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A caution row that sends the user to ClipLink's page in Settings.
struct MeSettingsNoticeRow: View {
    let message: String
    var systemImage = "exclamationmark.triangle.fill"
    var tint: Color = .orange
    var showsButton = true

    var body: some View {
        if showsButton {
            Button {
                MeSystemSettings.open()
            } label: {
                content
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens ClipLink in the Settings app.")
        } else {
            content
                .accessibilityElement(children: .combine)
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundColor(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if showsButton {
                    Text("Open Settings")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.accentColor)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

enum MeSystemSettings {
    /// ClipLink's own page in the Settings app (Background App Refresh,
    /// Local Network, Notifications, Paste from Other Apps).
    @MainActor
    static func open() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

enum MeFormat {
    static let logTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
    }

    static func grouped(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}

// MARK: - Themed page & row backgrounds

extension View {
    /// An inset-grouped list on the themed page background (bottom glow),
    /// honouring the list's own background on every iOS version.
    func mePage(glow: Bool, accent: Color) -> some View {
        modifier(MePageModifier(glow: glow, accent: accent))
    }

    /// Row fill honouring "Card transparency" (only the fill fades), plus the
    /// iOS 15 hook that lets the page background show through the list.
    func meRow(transparency: Double) -> some View {
        modifier(MeRowModifier(transparency: transparency))
    }

    /// Just the iOS 15 hook of `meRow`, for rows that draw their own card
    /// fill (and so leave the row's background clear).
    func meTableClear() -> some View {
        modifier(MeTableClearModifier())
    }
}

private struct MeTableClearModifier: ViewModifier {
    func body(content: Content) -> some View {
        Group {
            if #available(iOS 16, *) {
                content
            } else {
                content.background(MeTableBackgroundClearer())
            }
        }
    }
}

private struct MePageModifier: ViewModifier {
    let glow: Bool
    let accent: Color

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 16, *) {
                content.scrollContentBackground(.hidden)
            } else {
                content
            }
        }
        .listStyle(.insetGrouped)
        .background(PageBackground(glow: glow, accent: accent).ignoresSafeArea())
    }
}

private struct MeRowModifier: ViewModifier {
    let transparency: Double

    func body(content: Content) -> some View {
        let fill: Color? = transparency > 0
            ? Color(Theme.card).opacity(1 - min(max(transparency, 0), 95) / 100)
            : nil
        Group {
            if #available(iOS 16, *) {
                content
            } else {
                content.background(MeTableBackgroundClearer())
            }
        }
        .listRowBackground(fill)
    }
}

/// iOS 15 has no `.scrollContentBackground(.hidden)`: its List is a
/// UITableView with an opaque grouped background. This invisible view, placed
/// in a row, clears the background of the one table it lives in (never the
/// global appearance proxy, which would change every other screen's lists).
private struct MeTableBackgroundClearer: UIViewRepresentable {
    func makeUIView(context: Context) -> MeClearingView {
        let view = MeClearingView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: MeClearingView, context: Context) {
        uiView.clearEnclosingTable()
    }
}

final class MeClearingView: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        clearEnclosingTable()
    }

    func clearEnclosingTable() {
        DispatchQueue.main.async { [weak self] in
            var view = self?.superview
            while let current = view {
                if let table = current as? UITableView {
                    if table.backgroundColor != .clear { table.backgroundColor = .clear }
                    table.backgroundView = nil
                    return
                }
                view = current.superview
            }
        }
    }
}
