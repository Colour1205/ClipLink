import SwiftUI
import UIKit

/// Sizes and animations of a stack of items, in one place so the Synced tab's
/// grid estimate and the stack views agree. The gesture and timing numbers
/// themselves live in `StackMotion`, apart from the UI.
enum SyncedStackStyle {
    /// How far each layer behind the front card peeks out below it.
    static let layerStep = CGFloat(StackMotion.peek)
    /// How much narrower each layer is, on each side.
    static let layerInset = CGFloat(StackMotion.layerInset)
    /// A layer is drawn taller than what shows: only its bottom edge is below
    /// the card, the rest is clipped away, so it reads as a whole card slid behind.
    static let layerHeight: CGFloat = 70
    /// Touch target of the handle, low in the card and centred, and the bar
    /// drawn in it 8 pt above the card's bottom edge (inside its own padding).
    static let handleSize = CGSize(width: 240, height: 56)
    static let barSize = CGSize(width: 36, height: 5)
    static let barBottom: CGFloat = 8

    /// A card or a stack coming in, and the cards around it moving over.
    static func arrival(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.85)
    }

    /// Opening or closing the stack: the cards below move.
    static func openAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.85)
    }

    /// A drag that let go too early, or the layers coming back to the finger.
    static func springBack(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.35, dampingFraction: 0.8)
    }

    /// The layers fading under the cards that take their place.
    static func layerFade(reduceMotion: Bool) -> Animation {
        .easeIn(duration: reduceMotion ? 0.1 : 0.12)
    }

    /// A hidden card sliding out from where its layer was, and fading in a
    /// little after it starts, as it comes out from under the front card.
    static let revealSlide = Animation.spring(response: 0.45, dampingFraction: 0.8)
    static let revealFade = Animation.easeOut(duration: 0.16)
    static let revealFadeLag: Double = 0.09
    /// The card sliding back there, when the finger brings the stack back.
    static let revealReturn = Animation.spring(response: 0.4, dampingFraction: 0.9)

    /// "Expand 4 more items".
    static func expandLabel(hidden: Int) -> String {
        hidden == 1 ? "Expand 1 more item" : "Expand \(hidden) more items"
    }
}

/// Where a card that an opened stack revealed is drawn, relative to its place:
/// moved and scaled (about its middle) back to where its layer was.
struct RevealPlace: Equatable {
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    var scale: CGFloat = 1

    static let rest = RevealPlace()

    init(dx: CGFloat = 0, dy: CGFloat = 0, scale: CGFloat = 1) {
        self.dx = dx
        self.dy = dy
        self.scale = scale
    }

    init(_ start: RevealStart) {
        self.init(dx: CGFloat(start.dx), dy: CGFloat(start.dy), scale: CGFloat(start.scale))
    }
}

private struct RevealPlaceEffect: ViewModifier {
    let place: RevealPlace

    func body(content: Content) -> some View {
        content
            .scaleEffect(place.scale)
            .offset(x: place.dx, y: place.dy)
    }
}

/// Where the cards of the Synced list are, in its own coordinates, reported
/// only by the ones a stack being opened needs (see SyncedView.revealLaidOut).
struct SyncedCardFrames: PreferenceKey {
    static let space = "SyncedList"
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// "+4": how many items are behind a stack's front card, at the right end of
/// that card's footer, where it fades as the stack is pulled open.
struct SyncedStackBadge: View {
    let hiddenCount: Int
    /// Fades with the pull (see StackMotion.chromeOpacity).
    let opacity: Double

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Text("+\(hiddenCount)")
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundColor(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            // The pill's 3 pt above and below is drawn, not laid out, so the
            // footer is as tall as any other card's (and the grid's estimate).
            .background(Capsule().fill(settings.accentTheme.fill).padding(.vertical, -3))
            .opacity(opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// One position in the Synced list: an ordinary card, or the card in front of
/// a stack (the newest item of one history batch) with the layers, the count
/// badge in its footer and the handle that opens it. The card itself is the
/// same view in both cases, so opening a stack keeps it in place and only
/// adds the others.
///
/// Pulling the handle down stretches the layers against a rubber band; at the
/// commit point the stack opens with the finger still down, and bringing the
/// finger back above the release point closes it again (see StackMotion).
/// Lifting the finger, or a tap, makes the opening final.
struct SyncedRowView: View {
    let row: SyncedRow
    let compact: Bool
    /// Set for a card just revealed by opening a stack: its place in the fan
    /// (1 is the one right behind the front card).
    let fanIndex: Int?
    /// The card just came in (see FreshArrivals): it grows in.
    let fresh: Bool
    /// For a card a stack just revealed: where it is drawn now, relative to
    /// its place, and where it started (where it goes back to if the stack
    /// closes again). Nil otherwise.
    let revealPlace: RevealPlace?
    let revealStart: RevealPlace?
    /// A revealed card that has not faded in yet.
    let revealHidden: Bool
    /// The front card of a stack being opened: drawn above the cards that
    /// slide out from under it.
    let onTop: Bool
    /// Reports the card's frame (see SyncedCardFrames).
    let measured: Bool
    let zoom: Namespace.ID?
    let onOpen: (SyncedItem) -> Void
    let onDelete: (SyncedItem) -> Void
    /// The stack opens: its items become cards that slide out from where the
    /// layers are, `stretch` (0 to 1) being how far they had been pulled apart.
    let onExpand: (StackInfo, Double) -> Void
    /// The finger that opened it came back up: the items go back in.
    let onCollapse: (StackInfo) -> Void
    /// The opening is final (the finger let go, or a tap).
    let onSettle: (StackInfo) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the layers are stretched apart: the rubber band of the drag.
    @State private var drag: Double = 0
    /// 0 to 1: how much the layers have faded out, after the stack opened.
    @State private var fade: Double = 0
    /// The stack as it was when a finger came down on the handle. It keeps the
    /// layers, the count and the handle (and so the gesture) while the finger
    /// is down, and a moment after, even though the row is no stack once it
    /// has opened.
    @State private var held: StackInfo?
    /// The cards are out (by a pull, a fling or a tap).
    @State private var opened = false
    /// They came out with the finger still down, so it can still put them back.
    @State private var revertible = false
    @State private var fingerDown = false
    @State private var velocity = DragVelocity()
    /// Counts holds, so the end of one does not end the next.
    @State private var holdSerial = 0
    /// True while a finger is on the handle; also falls back to false if iOS
    /// cancels the drag, which a plain @State would never hear about.
    @GestureState private var dragging = false

    /// The stack drawn: the row's, or the one a finger holds.
    private var stack: StackInfo? { row.stack ?? held }

    private var chromeOpacity: Double { StackMotion.chromeOpacity(progress: drag, fade: fade) }

    /// Room under the card for the layers to peek into. Fixed while they
    /// stretch, so a drag never moves the cards below.
    private var reservedBottom: CGFloat {
        CGFloat(stack?.layerCount ?? 0) * SyncedStackStyle.layerStep
    }

    var body: some View {
        SyncedCard(item: row.item, compact: compact, onOpen: { onOpen(row.item) }, onDelete: { onDelete(row.item) },
                   stackBadge: stack.map { SyncedStackBadge(hiddenCount: $0.hiddenCount, opacity: chromeOpacity) },
                   zoom: zoom)
            .background(alignment: .bottom) { layers }
            .overlay(alignment: .bottom) { handle }
            .background(frameReader)
            .padding(.bottom, reservedBottom)
            .modifier(RevealPlaceEffect(place: revealPlace ?? .rest))
            .opacity(revealHidden ? 0 : 1)
            .onChange(of: row.stack?.groupID) { _ in
                // A card that is the front of a (new) stack again starts closed.
                guard held == nil, row.stack != nil else { return }
                opened = false
                revertible = false
                drag = 0
                fade = 0
            }
            // Above the cards around it: the front card over the ones sliding
            // out from under it, and stretched layers over the card below.
            .zIndex(onTop ? 2 : (held != nil ? 1 : 0))
            .transition(arrival)
    }

    private var frameReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: SyncedCardFrames.self,
                value: measured ? [row.id: proxy.frame(in: .named(SyncedCardFrames.space))] : [:]
            )
        }
    }

    // MARK: - Transition

    /// How this row arrives and leaves. A card a stack revealed is already in
    /// place, invisible, and slides out once it has been laid out (see
    /// SyncedView.revealLaidOut); if the stack closes again it slides back to
    /// where its layer was. A card or stack that just came in grows from 60%
    /// as it fades in. Anything else fades, as it always did.
    private var arrival: AnyTransition {
        if let start = revealStart, !reduceMotion {
            let back = AnyTransition
                .modifier(active: RevealPlaceEffect(place: start), identity: RevealPlaceEffect(place: .rest))
                .animation(SyncedStackStyle.revealReturn)
            return .asymmetric(insertion: .identity, removal: back)
        }
        if fanIndex != nil {
            if reduceMotion { return AnyTransition.opacity.animation(.easeInOut(duration: 0.15)) }
            return .asymmetric(insertion: .identity, removal: .opacity)
        }
        if fresh {
            if reduceMotion { return AnyTransition.opacity.animation(.easeInOut(duration: 0.15)) }
            let grow = AnyTransition.opacity
                .combined(with: .scale(scale: 0.6))
                .animation(.spring(response: 0.3, dampingFraction: 0.85))
            return .asymmetric(insertion: grow, removal: .opacity)
        }
        return .opacity
    }

    // MARK: - Layers

    /// The cards behind the front one: the bottom of each peeks out below it.
    /// Only what is below the card is drawn (a strip clipped at its bottom
    /// edge), so a see-through card has nothing showing through it.
    @ViewBuilder
    private var layers: some View {
        if let stack {
            ZStack(alignment: .top) {
                // The furthest first, so the nearest ends up on top.
                ForEach(Array(stride(from: stack.layerCount, through: 1, by: -1)), id: \.self) { depth in
                    layer(depth: depth)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: stripHeight(stack), alignment: .top)
            .clipped()
            // The strip's top edge 1 pt up, under the card's bottom edge.
            .alignmentGuide(.bottom) { dimensions in dimensions[.top] + 1 }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
        }
    }

    /// Room for the layers at their furthest.
    private func stripHeight(_ stack: StackInfo) -> CGFloat {
        CGFloat(stack.layerCount) * CGFloat(StackMotion.peek + StackMotion.spread)
    }

    /// The card's own fill (with "Card transparency"), a hairline edge, a
    /// little narrower and dimmer for each step back.
    private func layer(depth: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        let shift = CGFloat(StackMotion.layerShift(depth: depth, stretch: drag))
        return LayerFill(shape: shape)
            .frame(height: SyncedStackStyle.layerHeight)
            .padding(.horizontal, CGFloat(depth) * SyncedStackStyle.layerInset)
            .offset(y: shift - SyncedStackStyle.layerHeight)
            .opacity(StackMotion.layerOpacity(depth: depth, fade: fade))
    }

    // MARK: - Handle

    /// A short bar, low in a touch target 56 pt tall and up to 240 wide. A
    /// swipe down that starts on it opens the stack; one that starts anywhere
    /// else is the list's to scroll.
    @ViewBuilder
    private var handle: some View {
        if let stack {
            ZStack(alignment: .bottom) {
                Color.clear
                Capsule()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: SyncedStackStyle.barSize.width, height: SyncedStackStyle.barSize.height)
                    .padding(.bottom, SyncedStackStyle.barBottom)
                    // The bar fades, not the touch target: a finger still on it
                    // keeps its drag after the stack has opened.
                    .opacity(chromeOpacity)
            }
            .frame(maxWidth: SyncedStackStyle.handleSize.width)
            .frame(height: SyncedStackStyle.handleSize.height)
            .contentShape(Rectangle())
            .onTapGesture { expand(stack, revertible: false) }
            .gesture(dragGesture)
            .onChange(of: dragging) { isDragging in
                // iOS took the drag away without ending it: what is out stays
                // out, anything else springs back.
                guard !isDragging, fingerDown else { return }
                release(translation: 0, velocity: 0, cancelled: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SyncedStackStyle.expandLabel(hidden: stack.hiddenCount))
            .accessibilityHint("Shows each item as its own card.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { expand(stack, revertible: false) }
            .transition(.opacity)
        }
    }

    // MARK: - Pulling

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                pull(Double(value.translation.height), at: value.time.timeIntervalSinceReferenceDate)
            }
            .onEnded { value in
                let translation = Double(value.translation.height)
                velocity.add(translation, at: value.time.timeIntervalSinceReferenceDate)
                release(translation: translation, velocity: velocity.velocity, cancelled: false)
            }
    }

    /// The finger moved: before the commit point the layers follow it, past it
    /// the stack opens; once open, back above the release point closes it.
    private func pull(_ translation: Double, at time: TimeInterval) {
        if !fingerDown {
            fingerDown = true
            // A hold that was about to end is not over any more.
            holdSerial += 1
            velocity.reset()
        }
        // The stack as it is now: a batch that lands under the finger adds
        // its items, and they come out with the others.
        if let current = row.stack, current != held { held = current }
        velocity.add(translation, at: time)
        guard let stack = held else { return }
        if opened {
            if revertible && StackMotion.shouldCollapse(translation) { collapse(stack, translation: translation) }
            return
        }
        if StackMotion.reachedCommit(translation) {
            expand(stack, revertible: true)
        } else {
            drag = StackMotion.progress(forDrag: translation)
        }
    }

    /// The finger let go (or iOS took the gesture): where the cards are now is
    /// final. A stack not yet open opens on a fast swipe down or a long enough
    /// pull, else it springs shut.
    private func release(translation: Double, velocity: Double, cancelled: Bool) {
        guard fingerDown else { return }
        fingerDown = false
        guard let stack = held else { return }
        if opened {
            if revertible {
                revertible = false
                onSettle(stack)
            }
        } else if !cancelled && StackMotion.shouldExpand(translation: translation, velocity: velocity) {
            expand(stack, revertible: false)
        } else {
            withAnimation(SyncedStackStyle.springBack(reduceMotion: reduceMotion)) { drag = 0 }
        }
        // With the cards out, the handle and the count stay a moment so the
        // layers can finish fading; then the room they took goes, and the
        // cards below slide up into it.
        holdSerial += 1
        let serial = holdSerial
        DispatchQueue.main.asyncAfter(deadline: .now() + (opened ? StackMotion.holdAfterRelease : 0)) {
            guard holdSerial == serial else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { held = nil }
        }
    }

    /// Opens the stack (the commit point, a fast swipe, a tap, or VoiceOver):
    /// the items become cards that start where the layers are, and the layers
    /// fade out under them.
    private func expand(_ stack: StackInfo, revertible: Bool) {
        guard !opened else { return }
        opened = true
        self.revertible = revertible
        withAnimation(SyncedStackStyle.layerFade(reduceMotion: reduceMotion)) { fade = 1 }
        onExpand(stack, drag)
        if !revertible { onSettle(stack) }
    }

    /// The finger that opened the stack came back up before it let go: the
    /// cards go back in, and the layers follow the finger again.
    private func collapse(_ stack: StackInfo, translation: Double) {
        opened = false
        revertible = false
        onCollapse(stack)
        withAnimation(SyncedStackStyle.springBack(reduceMotion: reduceMotion)) {
            drag = StackMotion.progress(forDrag: translation)
            fade = 0
        }
    }
}

/// One layer's shape: the cards' fill, with "Card transparency" applied, and
/// a hairline edge.
private struct LayerFill: View {
    let shape: RoundedRectangle

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        shape
            .fill(Color(Theme.card).opacity(Theme.cardFillOpacity(transparency: settings.cardTransparency)))
            .overlay(shape.strokeBorder(Color(UIColor.separator), lineWidth: 1))
    }
}
