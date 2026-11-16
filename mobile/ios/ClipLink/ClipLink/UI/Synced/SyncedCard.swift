import SwiftUI
import UIKit

/// One history item on the Synced tab. `compact` is the two-column grid.
/// Tap opens the detail screen; long-press shows the context menu; the card
/// can be dragged out to another app.
struct SyncedCard: View {
    let item: SyncedItem
    let compact: Bool
    let onOpen: () -> Void
    /// Delete, confirmed by the Synced tab (like the detail screen's).
    let onDelete: () -> Void
    /// Set on a stack's front card: the "+4" at the right end of the footer.
    var stackBadge: SyncedStackBadge? = nil
    /// The Synced tab's namespace for the card's zoom into its screen.
    var zoom: Namespace.ID? = nil

    @EnvironmentObject private var settings: AppSettings

    /// An image file whose picture couldn't be decoded: a card with no
    /// preview, so it shows the file's name like any other file.
    @State private var pictureFailed = false

    /// For the actions only, not watched: a card redraws when its item does
    /// (or, for a file on its way, its transfer - see SyncedTransfersReader),
    /// not with every snapshot.
    private var model: AppModel { AppModel.shared }

    static let gridTextLines = 8
    static let listTextLines = 4
    static let gridLinkLines = 5
    static let listLinkLines = 3

    /// How close a picture sits to the card's edge; text sits further in.
    private static let pictureEdge: CGFloat = 8

    private var actions: SyncedItemActions { SyncedItemActions(model: model, haptics: settings.haptics) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous) }
    /// Images and image files that show their picture.
    private var isPictureCard: Bool { SyncedItemActions.hasPicture(item) && !pictureFailed }
    private var cardPadding: CGFloat { compact ? 12 : 14 }
    private var padding: CGFloat { isPictureCard ? Self.pictureEdge : cardPadding }
    /// The footer takes up what a picture card's padding is short of, so it
    /// lands in the same place on every card.
    private var footerInset: CGFloat { isPictureCard ? cardPadding - Self.pictureEdge : 0 }

    var body: some View {
        // Only a file still on its way follows the transfers.
        if item.kind == .file && !item.fileAvailable {
            SyncedTransfersReader { transfers in card(transfers: transfers) }
        } else {
            card(transfers: [:])
        }
    }

    private func card(transfers: [String: TransferProgress]) -> some View {
        Button {
            onOpen()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                content(transfers: transfers)
                footer
                    .padding(.horizontal, footerInset)
                    .padding(.bottom, footerInset)
            }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground(transparency: settings.cardTransparency)
            .contentShape(shape)
        }
        .buttonStyle(SyncedCardButtonStyle())
        .contentShape(.contextMenuPreview, shape)
        .contextMenu { SyncedItemMenuItems(item: item, actions: actions, onDelete: onDelete) }
        .onDrag { actions.dragProvider(for: item) }
        .modifier(SyncedZoomSource(id: item.id, namespace: zoom))
        .accessibilityLabel(SyncedItemActions.accessibilitySummary(item, transfers: transfers))
        .accessibilityHint("Shows details.")
        .accessibilityAction(named: "Copy") { actions.copy(item) }
        .accessibilityAction(named: "Share") { actions.share(item) }
        .accessibilityAction(named: "Delete") { onDelete() }
    }

    // MARK: - Body per kind

    @ViewBuilder
    private func content(transfers: [String: TransferProgress]) -> some View {
        switch item.kind {
        case .text:
            textBody(lines: compact ? Self.gridTextLines : Self.listTextLines)
        case .link:
            VStack(alignment: .leading, spacing: 8) {
                textBody(lines: compact ? Self.gridLinkLines : Self.listLinkLines)
                linkChip
            }
        case .opaque:
            VStack(alignment: .leading, spacing: 4) {
                Text("Encoded data")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Text(Self.opaqueFragment(item.entry.content))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .image:
            pictureBody
        case .file:
            if isPictureCard {
                pictureBody
            } else {
                fileBody(transfers: transfers)
            }
        }
    }

    /// Just the picture, whole: no name or caption, the picture is the content.
    private var pictureBody: some View {
        SyncedThumbnailView(
            item: item,
            maxPixel: compact ? 480 : 900,
            placeholderHeight: Self.picturePlaceholderHeight(compact: compact),
            showsFailure: item.kind == .image,
            onFailure: { if item.kind == .file { pictureFailed = true } }
        )
    }

    private func textBody(lines: Int) -> some View {
        let preview = Self.displayText(item.entry.content, compact: compact)
        return Text(preview.isEmpty ? "Empty text" : preview)
            .font(compact ? .subheadline : .body)
            .foregroundColor(preview.isEmpty ? .secondary : .primary)
            .lineLimit(lines)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var linkChip: some View {
        let host = SyncedItemActions.linkURL(item)?.host ?? "Link"
        return HStack(spacing: 4) {
            Image(systemName: "link")
            Text(host).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundColor(settings.accentTheme.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(settings.accentTheme.color.opacity(0.14)))
    }

    private func fileBody(transfers: [String: TransferProgress]) -> some View {
        let name = item.filePayload?.fileName ?? "File"
        let fraction = SyncedItemActions.transferFraction(item, transfers: transfers)
        return HStack(alignment: .center, spacing: 10) {
            SyncedFileTile(fileName: name, size: compact ? 36 : 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(SyncedItemActions.fileStatus(item, transfers: transfers))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                }
            }
        }
    }

    /// The same on every card, but for the glyph: an image file gets an
    /// image's, since its picture is already shown above. Glyph, time and
    /// the sending device on the left, a file's extension and then a stack's
    /// badge on the right; when the row is short (grid cards) only the
    /// device's name gives way.
    private var footer: some View {
        HStack(spacing: 6) {
            KindChip(kind: isPictureCard ? .image : item.kind, size: 20)
            HStack(spacing: 0) {
                Text(TimeLabel.short(item.date))
                    .lineLimit(1)
                    .fixedSize()
                if !item.isOwn {
                    Text(" · \(item.sourceLabel)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            // Ahead of the spacer, so the device's name is cut only once the
            // spacer is down to its minimum, not when the two share the row.
            .layoutPriority(1)
            Spacer(minLength: 4)
            if let ext = item.fileExtensionLabel {
                Text(ext)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let badge = stackBadge {
                badge.transition(.opacity)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Text helpers (shared with the masonry estimate)

    /// Enough of the text to fill the card: laying out a megabyte of text
    /// just to show eight lines of it would stall scrolling.
    static func displayText(_ content: String, compact: Bool) -> String {
        let capped = content.prefix(compact ? 480 : 360)
        return capped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The start of an opaque item (one token of 40 or more characters, see
    /// SyncedItem.kind). Only its first characters are looked at: trimming and
    /// counting all of a multi-megabyte token on every render stalled scrolling.
    static func opaqueFragment(_ content: String) -> String {
        let head = content.unicodeScalars.drop(while: { CharacterSet.whitespacesAndNewlines.contains($0) }).prefix(25)
        let trimmed = String(Substring(head)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 24 ? "\(trimmed.prefix(24))…" : trimmed
    }

    static func picturePlaceholderHeight(compact: Bool) -> CGFloat { compact ? 150 : 210 }
}

/// Hands its content the incoming transfers, and watches them: the card of a
/// file still on its way redraws with its progress, and no other card does.
struct SyncedTransfersReader<Content: View>: View {
    @ObservedObject private var store = AppModel.shared.transfers
    private let content: ([String: TransferProgress]) -> Content

    init(@ViewBuilder content: @escaping ([String: TransferProgress]) -> Content) {
        self.content = content
    }

    var body: some View {
        content(store.value)
    }
}

/// Accent-tinted tile with a glyph for the file's type.
struct SyncedFileTile: View {
    let fileName: String
    var size: CGFloat = 44

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Image(systemName: SyncedItemActions.fileSymbol(for: fileName))
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundColor(settings.accentTheme.color)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size / 3.2, style: .continuous)
                    .fill(settings.accentTheme.color.opacity(0.15))
            )
            .accessibilityHidden(true)
    }
}

/// A card shrinks a little under the finger and comes back on the same spring
/// (HarmonyOS' 0.95). A scroll or the context menu taking over ends the press,
/// so a card held until its menu opens is not left small. Not changed by
/// Reduce Motion, as on HarmonyOS.
struct SyncedCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.9), value: configuration.isPressed)
    }
}

/// iOS 18's zoom: the card grows into the item's screen and shrinks back into
/// it when that closes (HarmonyOS' card-to-detail morph). The system scales
/// the whole screen from the card's frame, so its text grows with it instead
/// of being uncovered. Earlier systems, or an SDK without it, keep the push.
/// A device card zooms into its screen the same way (see DevicesView).
struct SyncedZoomSource: ViewModifier {
    let id: String
    let namespace: Namespace.ID?
    /// The card's corners: the zoom starts (and a close ends) with them.
    /// Without a clip shape the system takes the card's frame as a plain
    /// rectangle, and the card's rounded fill showed sharp corners at the
    /// start of the zoom and at the end of a close.
    var radius: CGFloat = Theme.cardRadius

    func body(content: Content) -> some View {
        #if compiler(>=6.0)
        if #available(iOS 18.0, *), let namespace {
            let corners = RoundedRectangle(cornerRadius: radius, style: .continuous)
            return AnyView(content.matchedTransitionSource(id: id, in: namespace) { source in
                source.clipShape(corners)
            })
        }
        #endif
        return AnyView(content)
    }
}

/// Behind a card zooming into its screen, and shrinking back, the list stays
/// on screen, blurred and a little darker - never faded (HarmonyOS'
/// DETAIL_BACKDROP_*). Only with the zoom: a push slides the list away, and
/// a list blurring as it slides would only look smeared.
enum SyncedZoom {
    /// iOS 18's zoom is there (see SyncedZoomSource).
    static var available: Bool {
        #if compiler(>=6.0)
        if #available(iOS 18.0, *) { return true }
        #endif
        return false
    }

    /// 24 pt leaves the cards as soft shapes with no readable text, like the
    /// system's materials.
    static let backdropBlur: CGFloat = 24
    /// A 15% black veil: HarmonyOS' brightness of 0.85, enough to push the
    /// list back without greying it out.
    static let backdropVeil: Double = 0.15

    /// HarmonyOS' spring for its zoom (stiffness 328, damping 36), so the
    /// list goes soft as the card grows; with Reduce Motion a short ease, as
    /// the other reduce-motion paths here, the list still blurring and clearing.
    static func motion(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeInOut(duration: 0.15)
            : .interpolatingSpring(mass: 1, stiffness: 328, damping: 36, initialVelocity: 0)
    }
}

/// The list's blur behind the zoom (see SyncedZoom). On the scrolling list
/// itself, not on the page: the page's background then shows at its blurred
/// edges, and the blur is never larger than the screen.
struct SyncedZoomBlur: ViewModifier {
    /// A card's screen is open (or opening, or not yet closed).
    let shown: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: shown ? SyncedZoom.backdropBlur : 0)
            .animation(SyncedZoom.motion(reduceMotion: reduceMotion), value: shown)
    }
}

/// The list's veil behind the zoom (see SyncedZoom): over the whole page,
/// background included, as HarmonyOS darkens all of it. It never takes a touch.
struct SyncedZoomVeil: ViewModifier {
    let shown: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content.overlay {
            Color.black
                .opacity(shown ? SyncedZoom.backdropVeil : 0)
                .animation(SyncedZoom.motion(reduceMotion: reduceMotion), value: shown)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The item's screen, as the end of the card's zoom (see SyncedZoomSource).
struct SyncedZoomDestination: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    /// Told false the moment the screen starts to close (see
    /// SyncedScreenWatcher) and true if it comes back, so the list behind
    /// clears as the card shrinks, not once it has landed.
    var onShown: ((Bool) -> Void)? = nil

    func body(content: Content) -> some View {
        #if compiler(>=6.0)
        if #available(iOS 18.0, *) {
            let zoomed = content.navigationTransition(.zoom(sourceID: id, in: namespace))
            if let onShown {
                return AnyView(zoomed.background(SyncedScreenWatcher(onShown: onShown)))
            }
            return AnyView(zoomed)
        }
        #endif
        return AnyView(content)
    }
}

/// When the screen it sits on starts to go, and comes back. The link's
/// binding only says the screen is gone, which may be once the close has
/// finished; UIKit's viewWillDisappear comes as it starts - a back tap, or a
/// swipe or drag back beginning (viewWillAppear again if that is given up).
/// A child of the screen's hosting controller, so it is told what the screen
/// is told. If it ever is not, the list just clears when the binding does.
struct SyncedScreenWatcher: UIViewControllerRepresentable {
    let onShown: (Bool) -> Void

    func makeUIViewController(context: Context) -> Watcher { Watcher() }

    func updateUIViewController(_ watcher: Watcher, context: Context) {
        watcher.onShown = onShown
    }

    final class Watcher: UIViewController {
        var onShown: ((Bool) -> Void)?

        override func loadView() {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            self.view = view
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            report(true)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            report(false)
        }

        /// After the call: a push can make it while SwiftUI is still
        /// updating, and state must not change in the middle of that.
        private func report(_ shown: Bool) {
            guard let onShown else { return }
            DispatchQueue.main.async { onShown(shown) }
        }
    }
}
