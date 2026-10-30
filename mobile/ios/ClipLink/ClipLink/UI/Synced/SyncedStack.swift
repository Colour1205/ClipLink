import SwiftUI

/// Sizes and animations of a stack of items, in one place so the Synced tab's
/// grid estimate and the stack views agree. The gesture and timing numbers
/// themselves live in `StackMotion`, apart from the UI.
enum SyncedStackStyle {
    /// How far each layer behind the front card peeks out below it.
    static let layerStep: CGFloat = 7
    /// How much narrower each layer is, on each side.
    static let layerInset: CGFloat = 12
    /// How much further apart the layers slide, per layer, by the end of the drag.
    static let spread: CGFloat = 22
    /// Touch target of the handle (at least 44 pt tall) and the bar drawn in it.
    static let handleSize = CGSize(width: 96, height: 44)
    static let barSize = CGSize(width: 36, height: 5)

    /// Opening the stack: the cards below move down and the hidden ones settle.
    static func openAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.5, dampingFraction: 0.82)
    }

    /// A drag that let go too early.
    static func springBack(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.35, dampingFraction: 0.8)
    }

    /// "Expand 4 more items".
    static func expandLabel(hidden: Int) -> String {
        hidden == 1 ? "Expand 1 more item" : "Expand \(hidden) more items"
    }
}

/// A card hidden in a stack, as it arrives when the stack opens: a little
/// higher and smaller, then settling into its place.
private struct FanOutEffect: ViewModifier {
    let depth: Int
    let active: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? 0.94 : 1, anchor: .top)
            .offset(y: active ? -CGFloat(min(depth, 4)) * 22 : 0)
    }
}

/// One position in the Synced list: an ordinary card, or the card in front of
/// a stack (the newest item of one history batch) with the layers, the count
/// badge and the handle that opens it. The card itself is the same view in
/// both cases, so opening a stack keeps it in place and only adds the others.
struct SyncedRowView: View {
    let row: SyncedRow
    let compact: Bool
    /// Set for a card just revealed by opening a stack: its place in the fan
    /// (1 is the one right behind the front card).
    let fanIndex: Int?
    let onOpen: (SyncedItem) -> Void
    let onDelete: (SyncedItem) -> Void
    let onExpand: (StackInfo) -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the handle has been pulled down, 0 to 1.
    @State private var drag: Double = 0
    /// The stack was opened (by drag, tap or VoiceOver) and is on its way out.
    @State private var opened = false
    /// True while a finger is on the handle; also falls back to false if iOS
    /// cancels the drag, which a plain @State would never hear about.
    @GestureState private var dragging = false

    private var progress: Double { row.stack == nil ? 0 : drag }

    /// Room under the card for the layers, growing as they slide apart so the
    /// cards below are pushed down with them.
    private var reservedBottom: CGFloat {
        guard let stack = row.stack else { return 0 }
        return CGFloat(stack.layerCount) * (SyncedStackStyle.layerStep + CGFloat(progress) * SyncedStackStyle.spread)
    }

    var body: some View {
        SyncedCard(item: row.item, compact: compact, onOpen: { onOpen(row.item) }, onDelete: { onDelete(row.item) })
            .background(alignment: .bottom) { layers }
            .overlay(alignment: .bottom) { handle }
            .overlay(alignment: .topTrailing) { badge }
            .padding(.bottom, reservedBottom)
            .transition(arrival)
    }

    // MARK: - Transition

    /// How this row arrives. A stack fades and scales in once, whatever it
    /// holds; a card revealed by a stack fans out, each a little after the
    /// one before (and past the first few, just appears in place); anything
    /// else arrives as it always did.
    private var arrival: AnyTransition {
        if row.stack != nil {
            if reduceMotion { return .opacity }
            return AnyTransition.opacity.combined(with: .scale(scale: 0.96))
        }
        guard let index = fanIndex else { return .opacity }
        if reduceMotion { return AnyTransition.opacity.animation(.easeInOut(duration: 0.15)) }
        guard StackMotion.animates(index: index) else { return .identity }
        let delay = StackMotion.staggerDelay(forIndex: index)
        let fan = AnyTransition
            .modifier(active: FanOutEffect(depth: index, active: true), identity: FanOutEffect(depth: index, active: false))
            .combined(with: .opacity)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(delay))
        return .asymmetric(insertion: fan, removal: .opacity)
    }

    // MARK: - Layers

    /// The cards behind the front one: a strip of each peeks out below it.
    @ViewBuilder
    private var layers: some View {
        if let stack = row.stack {
            ZStack(alignment: .bottom) {
                // The furthest first, so the nearest ends up on top.
                ForEach(Array(stride(from: stack.layerCount, through: 1, by: -1)), id: \.self) { depth in
                    layer(depth: depth)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
        }
    }

    /// Only the bottom of a layer is ever seen, so it is as tall as two
    /// corners; a little narrower and a little dimmer for each step back.
    private func layer(depth: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        let step = CGFloat(depth)
        return shape
            .fill(Color(Theme.card))
            .overlay(shape.fill(Color.black.opacity(0.07 * Double(depth))))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.06)))
            .frame(height: Theme.cardRadius * 2)
            .padding(.horizontal, step * SyncedStackStyle.layerInset)
            .offset(y: step * (SyncedStackStyle.layerStep + CGFloat(progress) * SyncedStackStyle.spread))
            .opacity(1 - 0.25 * progress)
    }

    // MARK: - Handle and badge

    @ViewBuilder
    private var handle: some View {
        if let stack = row.stack {
            ZStack(alignment: .bottom) {
                Color.clear
                Capsule()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: SyncedStackStyle.barSize.width, height: SyncedStackStyle.barSize.height)
                    // Inside the card's bottom padding, under the footer.
                    .padding(.bottom, 5)
            }
            .frame(width: SyncedStackStyle.handleSize.width, height: SyncedStackStyle.handleSize.height)
            .contentShape(Rectangle())
            .opacity(1 - progress)
            .onTapGesture { expand(stack) }
            .gesture(dragGesture(stack))
            .onChange(of: dragging) { isDragging in
                // iOS cancelled the drag: close the layers again.
                guard !isDragging, !opened, drag > 0 else { return }
                withAnimation(SyncedStackStyle.springBack(reduceMotion: reduceMotion)) { drag = 0 }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SyncedStackStyle.expandLabel(hidden: stack.hiddenCount))
            .accessibilityHint("Shows each item as its own card.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { expand(stack) }
            .transition(.opacity)
        }
    }

    /// "+4": how many items are behind the front card.
    @ViewBuilder
    private var badge: some View {
        if let stack = row.stack {
            Text("+\(stack.hiddenCount)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(settings.accentTheme.fill))
                // Half over the card's corner, clear of its text.
                .offset(x: 6, y: -6)
                .opacity(1 - progress)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }

    // MARK: - Opening

    /// Swiping down on the handle: the layers follow the finger, and on release
    /// the stack opens if it went about a third of the way or the swipe was
    /// fast, else it springs shut.
    private func dragGesture(_ stack: StackInfo) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                guard !opened else { return }
                drag = StackMotion.progress(forDrag: Double(value.translation.height))
            }
            .onEnded { value in
                let reached = StackMotion.progress(forDrag: Double(value.translation.height))
                if StackMotion.shouldExpand(progress: reached, projectedEnd: Double(value.predictedEndTranslation.height)) {
                    expand(stack)
                } else {
                    withAnimation(SyncedStackStyle.springBack(reduceMotion: reduceMotion)) { drag = 0 }
                }
            }
    }

    private func expand(_ stack: StackInfo) {
        guard !opened else { return }
        opened = true
        Haptics.tap(settings.haptics)
        onExpand(stack)
    }
}
