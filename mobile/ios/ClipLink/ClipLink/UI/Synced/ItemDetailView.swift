import SwiftUI
import UIKit

/// One item in full. Looks the item up live on every render, so a file's
/// "Transferring…" turns into its size as the bytes arrive, and the screen
/// closes itself if the item is deleted or the history cleared.
struct ItemDetailView: View {
    let itemID: String

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingDelete = false

    private var item: SyncedItem? { model.snapshot.items.first { $0.id == itemID } }
    private var actions: SyncedItemActions { SyncedItemActions(model: model, haptics: settings.haptics) }

    var body: some View {
        Group {
            if let item {
                content(for: item)
            } else {
                EmptyStateView(
                    systemImage: "trash",
                    title: "Item Removed",
                    message: "This item is no longer in your synced history."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .pageBackground(glow: settings.bottomGlow, accent: settings.accentTheme.color)
        .navigationTitle(item?.kind.label ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if let item { toolbarButtons(for: item) }
            }
        }
        .confirmationDialog("Delete this item?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let item { actions.delete(item) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's removed from this device only. Paired devices keep their own copies.")
        }
        .onChange(of: item == nil) { gone in
            if gone { dismiss() }
        }
    }

    @ViewBuilder
    private func toolbarButtons(for item: SyncedItem) -> some View {
        Button {
            actions.copy(item)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .accessibilityLabel("Copy")

        Button {
            actions.share(item)
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel("Share")
        .disabled(item.kind == .file && !item.fileAvailable)

        Button {
            confirmingDelete = true
        } label: {
            Image(systemName: "trash")
        }
        .accessibilityLabel("Delete")
    }

    // MARK: - Content per kind

    @ViewBuilder
    private func content(for item: SyncedItem) -> some View {
        switch item.kind {
        case .text, .link, .opaque:
            textContent(item)
        case .image:
            pictureContent(item) { EmptyView() }
        case .file:
            if SyncedItemActions.hasPicture(item) {
                pictureContent(item) { fileInfo(item, centered: false) }
            } else {
                fileContent(item)
            }
        }
    }

    /// Above this, text isn't sized in one piece inside a ScrollView: for a
    /// multi-megabyte log that's seconds of main-thread layout and a view
    /// hundreds of thousands of points tall.
    private static let longTextBytes = 64 * 1024

    @ViewBuilder
    private func textContent(_ item: SyncedItem) -> some View {
        if item.entry.content.utf8.count > Self.longTextBytes {
            longTextContent(item)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        if item.kind == .opaque { opaqueLabel }
                        SyncedSelectableText(
                            text: item.entry.content,
                            monospaced: item.kind == .opaque,
                            tint: settings.accentTheme.uiColor
                        )
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardBackground(transparency: settings.cardTransparency)

                    if item.kind == .link { openLinkButton(item) }

                    provenance(item, extra: Self.characterCount(item))
                }
                .padding(Theme.pagePadding)
            }
        }
    }

    /// Long text: a card that scrolls its own text (laid out lazily, no link
    /// detection) fills the screen, with the provenance underneath.
    private func longTextContent(_ item: SyncedItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if item.kind == .opaque { opaqueLabel }
            SyncedScrollingText(
                text: item.entry.content,
                monospaced: item.kind == .opaque,
                tint: settings.accentTheme.uiColor
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cardBackground(transparency: settings.cardTransparency)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))

            if item.kind == .link { openLinkButton(item) }

            provenance(item, extra: Self.characterCount(item))
        }
        .padding(Theme.pagePadding)
    }

    private var opaqueLabel: some View {
        Label("Looks like a key or token", systemImage: "key.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func openLinkButton(_ item: SyncedItem) -> some View {
        Button {
            actions.openLink(item)
        } label: {
            Label("Open Link", systemImage: "safari")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    /// Images (and image files): zoomable picture filling the screen, with
    /// an optional info panel and the provenance underneath.
    private func pictureContent<Info: View>(_ item: SyncedItem, @ViewBuilder info: () -> Info) -> some View {
        VStack(spacing: 0) {
            SyncedZoomableImageView(item: item)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 12) {
                info()
                HStack(alignment: .bottom) {
                    provenance(item, extra: nil)
                    Spacer(minLength: 12)
                    if SyncedItemActions.canSaveToPhotos(item) {
                        Button {
                            actions.saveToPhotos(item)
                        } label: {
                            Label("Save to Photos", systemImage: "square.and.arrow.down")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                }
            }
            .padding(Theme.pagePadding)
        }
    }

    private func fileContent(_ item: SyncedItem) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                SyncedFileTile(fileName: item.filePayload?.fileName ?? "File", size: 88)
                    .padding(.top, 24)
                fileInfo(item, centered: true)
                provenance(item, extra: nil)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding(Theme.pagePadding)
        }
    }

    /// Name, size or transfer progress, and the file actions.
    private func fileInfo(_ item: SyncedItem, centered: Bool) -> some View {
        let name = item.filePayload?.fileName ?? "File"
        let fraction = SyncedItemActions.transferFraction(item, transfers: model.snapshot.transfers)
        let isPicture = SyncedItemActions.hasPicture(item)
        return VStack(alignment: centered ? .center : .leading, spacing: 14) {
            VStack(alignment: centered ? .center : .leading, spacing: 6) {
                Text(name)
                    .font(centered ? .title3.weight(.semibold) : .headline)
                    .multilineTextAlignment(centered ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    if !item.fileAvailable, fraction == nil {
                        ProgressView()
                    }
                    Text(SyncedItemActions.fileStatus(item, transfers: model.snapshot.transfers))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 280)
                }
                if !item.fileAvailable {
                    Text("It arrives while a device that has it is connected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(centered ? .center : .leading)
                }
            }
            HStack(spacing: 10) {
                if !isPicture {
                    SyncedActionTile(title: "Quick Look", systemImage: "eye") { actions.quickLook(item) }
                }
                SyncedActionTile(title: "Share", systemImage: "square.and.arrow.up") { actions.share(item) }
                SyncedActionTile(title: "Save to Files", systemImage: "folder") { actions.saveToFiles(item) }
            }
            .disabled(!item.fileAvailable)
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    /// `String.count` walks every character, and this screen re-renders with
    /// each snapshot (several a second during transfers) - so remember the
    /// last item's.
    private static var characterCountCache: (id: String, label: String)?

    private static func characterCount(_ item: SyncedItem) -> String {
        if let cached = characterCountCache, cached.id == item.id { return cached.label }
        let count = item.entry.content.count
        let label = count == 1 ? "1 character" : "\(count.formatted()) characters"
        characterCountCache = (item.id, label)
        return label
    }

    private func provenance(_ item: SyncedItem, extra: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.isOwn ? "Sent from this device" : "From \(item.sourceLabel)")
            let when = TimeLabel.full(item.date)
            if !when.isEmpty { Text(when) }
            if let extra { Text(extra) }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

/// Icon-over-label bordered button, like the action row in Files.
struct SyncedActionTile: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
    }
}
