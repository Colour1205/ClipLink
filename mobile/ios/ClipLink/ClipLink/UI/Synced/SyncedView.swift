import SwiftUI
import UIKit

/// The Synced tab: clipboard history as a masonry grid or a list, with the
/// Paste / Send dock floating above the tab bar.
struct SyncedView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One programmatic link for every card: a NavigationLink inside a card
    /// would pop the detail screen whenever the masonry grid moves that card
    /// to the other column (iOS 15 tears the link down with its row).
    @State private var detailID = ""
    @State private var detailActive = false
    /// A card's Delete, waiting for the same confirmation the detail screen
    /// asks for: a deleted item stays deleted (peers don't send it back).
    /// Asked here, not on the card: the dialog must outlive the context menu.
    @State private var deleting: SyncedItem?
    /// Stacks the user opened (see StackPlanner). The engine is told once the
    /// opening is final (see settle) and forgets a group a moment after, so
    /// this keeps one open if a snapshot made in between still lists it. Only
    /// the ids of this session.
    @State private var expandedGroups: Set<String> = []
    /// For each card a stack just revealed, its place in the fan-out.
    @State private var fanIndex: [String: Int] = [:]
    /// The stack being opened, and how its revealed cards are drawn while they
    /// slide out (see revealLaidOut): moved back toward their layers, and
    /// invisible until they come out from under the front card.
    @State private var reveal = StackReveal()
    @State private var revealPlaces: [String: RevealPlace] = [:]
    @State private var revealHidden: Set<String> = []
    /// Which cards just came in: they grow in.
    @State private var arrivals = SyncedArrivals()
    @Namespace private var cardZoom

    private var items: [SyncedItem] { model.snapshot.items }
    /// What arrived since the app started on top, the last arrival first, then
    /// everything else by time (see StackPlanner).
    private var rows: [SyncedRow] {
        StackPlanner.rows(items: items, groups: model.snapshot.blocks, expanded: expandedGroups)
    }
    /// Changes when items come in or go (not when a stack opens, which
    /// animates itself): the cards then move to their new places.
    private var arrivalKey: [String] {
        model.snapshot.items.map(\.id) + model.snapshot.blocks.map(\.id)
    }
    private var actions: SyncedItemActions { SyncedItemActions(model: model, haptics: settings.haptics) }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ConnectionPill(snapshot: model.snapshot)
                        .animation(.easeInOut(duration: 0.2), value: model.snapshot.connectedCount)
                    content
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, 4)
                .padding(.bottom, 20)
                .animation(SyncedStackStyle.arrival(reduceMotion: reduceMotion), value: arrivalKey)
                .coordinateSpace(name: SyncedCardFrames.space)
                .onPreferenceChange(SyncedCardFrames.self) { revealLaidOut($0) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { SyncedDock() }
            .pageBackground(glow: settings.bottomGlow, accent: settings.accentTheme.color)
            .navigationTitle("Synced")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { layoutToggle }
            }
            .background(
                NavigationLink(
                    destination: ItemDetailView(itemID: detailID)
                        .modifier(SyncedZoomDestination(id: detailID, namespace: cardZoom)),
                    isActive: $detailActive
                ) {
                    EmptyView()
                }
            )
            .confirmationDialog(
                "Delete this item?",
                isPresented: Binding(
                    get: { deleting != nil },
                    set: { if !$0 { deleting = nil } }
                ),
                titleVisibility: .visible,
                presenting: deleting
            ) { item in
                Button("Delete", role: .destructive) {
                    actions.delete(item)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("It's removed here and on your paired devices, and won't come back. A device with an older ClipLink keeps its copy.")
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var content: some View {
        let _ = arrivals.note(model.snapshot)
        if items.isEmpty {
            EmptyStateView(
                systemImage: "doc.on.clipboard",
                title: "Nothing Synced Yet",
                message: "Copy something on a paired device, or tap Paste below to send what's on this \(UIDevice.current.model)'s clipboard."
            )
            .padding(.top, 24)
            .transition(.opacity)
        } else {
            let rows = self.rows
            if settings.syncedLayout == .grid {
                grid(rows).transition(.opacity)
            } else {
                list(rows).transition(.opacity)
            }
        }
    }

    private func grid(_ rows: [SyncedRow]) -> some View {
        let columns = SyncedMasonry.columns(for: rows)
        // The column with the front card of a stack being opened is drawn over
        // the other, so the cards sliding out of it pass under it.
        let frontOnLeft = !reveal.frontID.isEmpty && columns.left.contains { $0.id == reveal.frontID }
        return HStack(alignment: .top, spacing: Theme.cardSpacing) {
            column(columns.left)
                .zIndex(frontOnLeft ? 1 : 0)
            column(columns.right)
        }
    }

    private func column(_ columnRows: [SyncedRow]) -> some View {
        LazyVStack(spacing: Theme.cardSpacing) {
            ForEach(columnRows) { row in
                rowView(row, compact: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func list(_ rows: [SyncedRow]) -> some View {
        LazyVStack(spacing: Theme.cardSpacing) {
            ForEach(rows) { row in
                rowView(row, compact: false)
            }
        }
    }

    private func rowView(_ row: SyncedRow, compact: Bool) -> some View {
        SyncedRowView(
            row: row,
            compact: compact,
            fanIndex: fanIndex[row.id],
            fresh: arrivals.isFresh(row.id),
            revealPlace: revealPlaces[row.id],
            revealStart: reveal.starts[row.id],
            revealHidden: revealHidden.contains(row.id),
            onTop: !reveal.frontID.isEmpty && reveal.frontID == row.id,
            measured: reveal.measures(row.id),
            zoom: cardZoom,
            onOpen: { open($0) },
            onDelete: { deleting = $0 },
            onExpand: { expand($0, stretch: $1) },
            onCollapse: { collapse($0) },
            onSettle: { settle($0) }
        )
    }

    // MARK: - Opening a stack

    /// The stack's items become ordinary cards right under its front card. The
    /// cards below move down, and each revealed card starts where its layer
    /// was, `stretch` (0 to 1) being how far the layers had been pulled apart,
    /// and slides out to its place (see revealLaidOut). Until it is settled
    /// the finger that opened it can still close it again (see collapse).
    private func expand(_ stack: StackInfo, stretch: Double) {
        guard !expandedGroups.contains(stack.groupID) else { return }
        Haptics.tap(settings.haptics)
        var next = StackReveal()
        next.serial = reveal.serial + 1
        next.groupID = stack.groupID
        next.frontID = stack.memberIDs.first ?? ""
        next.stretch = stretch
        // Only cards that are still there: the map must not grow for ever.
        let present = Set(items.map(\.id))
        var fan = fanIndex.filter { present.contains($0.key) }
        var hidden = Set<String>()
        for (index, id) in stack.memberIDs.enumerated() where index > 0 {
            fan[id] = index
            // Invisible until its place is known; the rest of a large stack
            // just appears in place, and with Reduce Motion each fades in.
            if !reduceMotion && StackMotion.animates(index: index) {
                next.pending[id] = index
                hidden.insert(id)
            }
        }
        withAnimation(SyncedStackStyle.openAnimation(reduceMotion: reduceMotion)) {
            reveal = next
            revealPlaces = [:]
            revealHidden = hidden
            fanIndex = fan
            expandedGroups.insert(stack.groupID)
        }
        let serial = next.serial
        // A card that is never laid out (scrolled far away) must not stay invisible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard reveal.serial == serial, !reveal.pending.isEmpty else { return }
            for id in reveal.pending.keys { revealHidden.remove(id) }
            reveal.pending = [:]
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            guard reveal.serial == serial else { return }
            endReveal()
        }
    }

    /// Cards have been laid out: each one the stack revealed whose place is
    /// now known is put where its layer was - as narrow, its bottom edge
    /// peeking out below the front card - and after one frame slides to its
    /// place, each 30 ms after the one before, fading in a little after it
    /// starts, as it comes out from under the front card.
    private func revealLaidOut(_ frames: [String: CGRect]) {
        guard !reveal.pending.isEmpty, let front = frames[reveal.frontID] else { return }
        let serial = reveal.serial
        let stretch = reveal.stretch
        for (id, index) in reveal.pending {
            guard let own = frames[id], own.width > 0, own.height > 0 else { continue }
            let start = RevealPlace(StackMotion.revealStart(
                index: index, stretch: stretch,
                frontMidX: Double(front.midX), frontBottom: Double(front.maxY),
                ownMidX: Double(own.midX), ownMidY: Double(own.midY),
                ownWidth: Double(own.width), ownHeight: Double(own.height)
            ))
            var jump = Transaction(animation: nil)
            jump.disablesAnimations = true
            withTransaction(jump) {
                reveal.pending[id] = nil
                reveal.starts[id] = start
                revealPlaces[id] = start
            }
            let delay = 0.024 + StackMotion.staggerDelay(forIndex: index)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard reveal.serial == serial else { return }
                withAnimation(SyncedStackStyle.revealSlide) { revealPlaces[id] = .rest }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + SyncedStackStyle.revealFadeLag) {
                guard reveal.serial == serial else { return }
                withAnimation(SyncedStackStyle.revealFade) { _ = revealHidden.remove(id) }
            }
        }
    }

    /// The cards have finished sliding: nothing is moved or hidden any more.
    /// Where they started is kept while the finger that opened the stack can
    /// still put them back.
    private func endReveal() {
        revealPlaces = [:]
        revealHidden = []
        reveal.pending = [:]
        reveal.ended = true
        if reveal.settled { finishReveal() }
    }

    /// Nothing is being revealed any more, and the cards it revealed are
    /// ordinary cards: one deleted and sent again later comes in like any other.
    private func finishReveal() {
        reveal.reset()
        fanIndex = [:]
    }

    /// The finger that opened the stack came back up before it let go: the
    /// items go back into it, each sliding back to where its layer was (see
    /// SyncedRowView's transition) under the front card.
    private func collapse(_ stack: StackInfo) {
        guard expandedGroups.contains(stack.groupID), reveal.groupID == stack.groupID, !reveal.settled else { return }
        Haptics.tap(settings.haptics)
        // Cards still waiting to be laid out never moved: they just go. The
        // reveal's timers stop here.
        reveal.pending = [:]
        reveal.serial += 1
        let serial = reveal.serial
        withAnimation(SyncedStackStyle.openAnimation(reduceMotion: reduceMotion)) {
            _ = expandedGroups.remove(stack.groupID)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard reveal.serial == serial else { return }
            revealPlaces = [:]
            revealHidden = []
            finishReveal()
        }
    }

    /// The opening is final (the finger let go, or a tap): the engine stops
    /// listing the stack, which never closes again.
    private func settle(_ stack: StackInfo) {
        guard expandedGroups.contains(stack.groupID) else { return }
        model.expandGroup(stack.groupID)
        guard reveal.groupID == stack.groupID else { return }
        reveal.settled = true
        if reveal.ended { finishReveal() }
    }

    private var layoutToggle: some View {
        let isGrid = settings.syncedLayout == .grid
        return Button {
            Haptics.tap(settings.haptics)
            withAnimation(.easeInOut(duration: 0.25)) {
                settings.syncedLayout = isGrid ? .list : .grid
            }
        } label: {
            Image(systemName: isGrid ? "list.bullet" : "square.grid.2x2")
        }
        .accessibilityLabel(isGrid ? "List View" : "Grid View")
    }

    private func open(_ item: SyncedItem) {
        Haptics.tap(settings.haptics)
        detailID = item.id
        detailActive = true
    }
}

/// A stack being opened: its hidden cards slide out from where its layers
/// were (see SyncedView.revealLaidOut). Only the stack opened last.
private struct StackReveal {
    var groupID = ""
    /// Its front card, drawn above the cards sliding out from under it.
    var frontID = ""
    /// How far the layers had been pulled apart (0 to 1).
    var stretch: Double = 0
    /// Cards waiting to be laid out, by id, to their place in the stack (1 is
    /// the one right behind the front card).
    var pending: [String: Int] = [:]
    /// Where each laid-out card started: where it goes back to if the finger
    /// closes the stack again.
    var starts: [String: RevealPlace] = [:]
    /// The finger let go, or a tap opened it: the stack stays open.
    var settled = false
    /// The cards have finished sliding.
    var ended = false
    /// Counts reveals, so the timers of one leave the next alone.
    var serial = 0

    /// Cards whose place is needed: the front card and the ones waiting.
    func measures(_ id: String) -> Bool {
        !pending.isEmpty && (id == frontID || pending[id] != nil)
    }

    /// Nothing is being revealed; the count carries on.
    mutating func reset() {
        self = StackReveal(serial: serial)
    }
}

/// Which cards just came in (see FreshArrivals), noted while the list is
/// worked out: a reference, since a body must not change @State.
final class SyncedArrivals {
    private var tracker = FreshArrivals()

    func note(_ snapshot: EngineSnapshot) {
        var members = Set<String>()
        for block in snapshot.blocks { members.formUnion(block.memberIDs) }
        tracker.note(items: snapshot.items.map(\.id), blockMembers: members, now: Date.timeIntervalSinceReferenceDate)
    }

    func isFresh(_ id: String) -> Bool {
        tracker.isFresh(id, now: Date.timeIntervalSinceReferenceDate)
    }
}

// MARK: - Masonry

/// iOS 15 has no Layout protocol, so the "waterfall" grid is two lazy
/// columns: each item, in order, goes to whichever column is shorter so far,
/// by an estimate of its card's height. Deterministic (no measured sizes), so
/// cards never hop columns when their images finish loading.
@MainActor
enum SyncedMasonry {
    static func columns(for rows: [SyncedRow]) -> (left: [SyncedRow], right: [SyncedRow]) {
        let screenWidth = UIScreen.main.bounds.width
        let columnWidth = max(120, (screenWidth - 2 * Theme.pagePadding - Theme.cardSpacing) / 2)
        let metrics = Metrics()
        var left: [SyncedRow] = []
        var right: [SyncedRow] = []
        var leftHeight: CGFloat = 0
        var rightHeight: CGFloat = 0
        for row in rows {
            var height = estimatedHeight(row.item, columnWidth: columnWidth, metrics: metrics) + Theme.cardSpacing
            // The layers peeking out below a stack's front card.
            if let stack = row.stack { height += CGFloat(stack.layerCount) * SyncedStackStyle.layerStep }
            if leftHeight <= rightHeight {
                left.append(row)
                leftHeight += height
            } else {
                right.append(row)
                rightHeight += height
            }
        }
        return (left, right)
    }

    private struct Metrics {
        let body = UIFont.preferredFont(forTextStyle: .subheadline)
        let caption = UIFont.preferredFont(forTextStyle: .caption1)
        var footer: CGFloat { max(20, caption.lineHeight) }
    }

    private static func estimatedHeight(_ item: SyncedItem, columnWidth: CGFloat, metrics: Metrics) -> CGFloat {
        let padding: CGFloat = 12
        let inner = columnWidth - 2 * padding
        let chrome = 2 * padding + 10 + metrics.footer
        switch item.kind {
        case .text:
            let lines = textLines(SyncedCard.displayText(item.entry.content, compact: true), width: inner,
                                  font: metrics.body, maxLines: SyncedCard.gridTextLines)
            return chrome + CGFloat(lines) * metrics.body.lineHeight
        case .link:
            let lines = textLines(SyncedCard.displayText(item.entry.content, compact: true), width: inner,
                                  font: metrics.body, maxLines: SyncedCard.gridLinkLines)
            return chrome + CGFloat(lines) * metrics.body.lineHeight + 8 + metrics.caption.lineHeight + 8
        case .opaque:
            return chrome + metrics.body.lineHeight + 4 + metrics.caption.lineHeight
        case .image:
            return pictureHeight(columnWidth: columnWidth, metrics: metrics)
        case .file:
            // A picture without a name; failing to decode it is a rarity.
            if SyncedItemActions.hasPicture(item) { return pictureHeight(columnWidth: columnWidth, metrics: metrics) }
            var height = chrome + max(36, 2 * metrics.body.lineHeight + metrics.caption.lineHeight)
            if !item.fileAvailable { height += 8 }
            return height
        }
    }

    /// An image card: the picture 8 pt from the edges, then the footer.
    private static func pictureHeight(columnWidth: CGFloat, metrics: Metrics) -> CGFloat {
        let picture = min(260, (columnWidth - 16) * 0.8)
        return 16 + picture + 10 + metrics.footer + 4
    }

    /// Wrapped line count, from an average glyph width (CJK counts double).
    private static func textLines(_ text: String, width: CGFloat, font: UIFont, maxLines: Int) -> Int {
        guard !text.isEmpty else { return 1 }
        let unitsPerLine = max(6, width / (font.pointSize * 0.53))
        var lines = 0
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var units: CGFloat = 0
            for scalar in paragraph.unicodeScalars {
                units += scalar.value < 0x2E80 ? 1 : 1.9
            }
            lines += max(1, Int((units / unitsPerLine).rounded(.up)))
            if lines >= maxLines { return maxLines }
        }
        return min(max(lines, 1), maxLines)
    }
}

// MARK: - Dock

/// Floating capsule above the tab bar: the "New Item" hint, Paste (the system
/// paste control on iOS 16+, so no permission prompt) and Send.
struct SyncedDock: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var arrowNudged = false

    var body: some View {
        HStack(spacing: 10) {
            if model.hasNewClipboardItem {
                newItemPill
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            pasteButton
            sendMenu
        }
        .padding(8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.hasNewClipboardItem)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var newItemPill: some View {
        if #available(iOS 16.0, *) {
            // Reading the clipboard from our own button would raise iOS's
            // "Allow Paste" prompt, and the system Paste control beside it
            // doesn't - so here the pill only points at Paste (as on
            // HarmonyOS), nudging its arrow toward it when it appears or is tapped.
            newItemLabel
                .contentShape(Capsule())
                .onTapGesture { nudgeArrow(after: 0) }
                .onAppear { nudgeArrow(after: 0.4) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("New item on the clipboard")
                .accessibilityHint("Use Paste to sync it to your devices.")
        } else {
            Button {
                Haptics.tap(settings.haptics)
                Task { await model.captureAndSend(quiet: false) }
            } label: {
                newItemLabel
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New item on the clipboard")
            .accessibilityHint("Syncs it to your devices.")
        }
    }

    private var newItemLabel: some View {
        HStack(spacing: 5) {
            Text("New Item")
            Image(systemName: "arrow.right")
                .offset(x: arrowNudged ? 4 : 0)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundColor(.white)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(settings.accentTheme.color))
    }

    /// Two quick pokes of the arrow toward the Paste control.
    private func nudgeArrow(after delay: Double) {
        guard !reduceMotion else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard !arrowNudged else { return }
            withAnimation(.easeInOut(duration: 0.16).repeatCount(3, autoreverses: true)) { arrowNudged = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.48) {
                withAnimation(.easeInOut(duration: 0.16)) { arrowNudged = false }
            }
        }
    }

    @ViewBuilder
    private var pasteButton: some View {
        if #available(iOS 16.0, *) {
            SyncedPasteControl(accent: settings.accentTheme.uiColor) { providers in
                Haptics.tap(settings.haptics)
                Task { await model.sendProviders(providers) }
            }
            .fixedSize()
            .id(settings.accentTheme)
        } else {
            Button {
                Haptics.tap(settings.haptics)
                Task { await model.captureAndSend(quiet: false) }
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .accessibilityHint("Sends this device's clipboard to your devices.")
        }
    }

    private var sendMenu: some View {
        Menu {
            Button {
                SyncedPhotoPicker.present()
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }
            Button {
                SyncedDocumentImporter.present()
            } label: {
                Label("Files", systemImage: "folder")
            }
        } label: {
            Image(systemName: "paperplane")
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(UIColor.tertiarySystemFill)))
                .contentShape(Circle())
        }
        .accessibilityLabel("Send")
        .accessibilityHint("Sends a photo or file to your devices.")
    }
}
