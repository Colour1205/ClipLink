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
    /// Stacks the user opened (see StackPlanner). The engine forgets a group a
    /// moment after being told, so this keeps one open if a snapshot made in
    /// between still lists it. Only the ids of this session.
    @State private var expandedGroups: Set<String> = []
    /// For each card a stack just revealed, its place in the fan-out.
    @State private var fanIndex: [String: Int] = [:]

    private var items: [SyncedItem] { model.snapshot.items }
    /// What arrived since the app started on top, the last arrival first, then
    /// everything else by time (see StackPlanner).
    private var rows: [SyncedRow] {
        StackPlanner.rows(items: items, groups: model.snapshot.blocks, expanded: expandedGroups)
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
                .animation(.spring(response: 0.4, dampingFraction: 0.86), value: rows.map(\.id))
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { SyncedDock() }
            .pageBackground(glow: settings.bottomGlow, accent: settings.accentTheme.color)
            .navigationTitle("Synced")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { layoutToggle }
            }
            .background(
                NavigationLink(destination: ItemDetailView(itemID: detailID), isActive: $detailActive) {
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
        return HStack(alignment: .top, spacing: Theme.cardSpacing) {
            column(columns.left)
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
            onOpen: { open($0) },
            onDelete: { deleting = $0 },
            onExpand: { expand($0) }
        )
    }

    /// The stack's items become ordinary cards, for good, right under its front
    /// card. Revealed cards fan out one after the other; the ones below move
    /// down with the same spring.
    private func expand(_ stack: StackInfo) {
        var fan = fanIndex
        // Only cards that are still there: the map must not grow for ever.
        let present = Set(items.map(\.id))
        fan = fan.filter { present.contains($0.key) }
        for (index, id) in stack.memberIDs.enumerated() where index > 0 { fan[id] = index }
        withAnimation(SyncedStackStyle.openAnimation(reduceMotion: reduceMotion)) {
            fanIndex = fan
            expandedGroups.insert(stack.groupID)
        }
        model.expandGroup(stack.groupID)
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
