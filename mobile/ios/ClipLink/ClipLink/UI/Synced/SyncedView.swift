import SwiftUI
import UIKit

/// The Synced tab: clipboard history as a masonry grid or a list, with the
/// Paste / Send dock floating above the tab bar.
struct SyncedView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    /// One programmatic link for every card: a NavigationLink inside a card
    /// would pop the detail screen whenever the masonry grid moves that card
    /// to the other column (iOS 15 tears the link down with its row).
    @State private var detailID = ""
    @State private var detailActive = false
    /// A card's Delete, waiting for the same confirmation the detail screen
    /// asks for: a deleted item stays deleted (peers don't send it back).
    /// Asked here, not on the card: the dialog must outlive the context menu.
    @State private var deleting: SyncedItem?

    private var items: [SyncedItem] { model.snapshot.items }
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
                .animation(.spring(response: 0.4, dampingFraction: 0.86), value: items.map(\.id))
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
                Text("It's removed from this device only. Paired devices keep their own copies, but won't send it back.")
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
        } else if settings.syncedLayout == .grid {
            grid.transition(.opacity)
        } else {
            list.transition(.opacity)
        }
    }

    private var grid: some View {
        let columns = SyncedMasonry.columns(for: items)
        return HStack(alignment: .top, spacing: Theme.cardSpacing) {
            column(columns.left)
            column(columns.right)
        }
    }

    private func column(_ columnItems: [SyncedItem]) -> some View {
        LazyVStack(spacing: Theme.cardSpacing) {
            ForEach(columnItems) { item in
                SyncedCard(item: item, compact: true, onOpen: { open(item) }, onDelete: { deleting = item })
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var list: some View {
        LazyVStack(spacing: Theme.cardSpacing) {
            ForEach(items) { item in
                SyncedCard(item: item, compact: false, onOpen: { open(item) }, onDelete: { deleting = item })
            }
        }
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
    static func columns(for items: [SyncedItem]) -> (left: [SyncedItem], right: [SyncedItem]) {
        let screenWidth = UIScreen.main.bounds.width
        let columnWidth = max(120, (screenWidth - 2 * Theme.pagePadding - Theme.cardSpacing) / 2)
        let metrics = Metrics()
        var left: [SyncedItem] = []
        var right: [SyncedItem] = []
        var leftHeight: CGFloat = 0
        var rightHeight: CGFloat = 0
        for item in items {
            let height = estimatedHeight(item, columnWidth: columnWidth, metrics: metrics) + Theme.cardSpacing
            if leftHeight <= rightHeight {
                left.append(item)
                leftHeight += height
            } else {
                right.append(item)
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
            let picture = min(260, (columnWidth - 16) * 0.8)
            return 16 + picture + 8 + metrics.footer + 2
        case .file:
            var height = chrome + max(36, 2 * metrics.body.lineHeight + metrics.caption.lineHeight)
            if SyncedItemActions.hasPicture(item) { height += min(220, inner * 0.8) + 10 }
            if !item.fileAvailable { height += 8 }
            return height
        }
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
