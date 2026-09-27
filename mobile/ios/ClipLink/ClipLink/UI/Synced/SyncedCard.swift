import SwiftUI
import UIKit

/// One history item on the Synced tab. `compact` is the two-column grid.
/// Tap opens the detail screen; long-press shows the context menu; the card
/// can be dragged out to another app.
struct SyncedCard: View {
    let item: SyncedItem
    let compact: Bool
    let onOpen: () -> Void

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    static let gridTextLines = 8
    static let listTextLines = 4
    static let gridLinkLines = 5
    static let listLinkLines = 3

    private var actions: SyncedItemActions { SyncedItemActions(model: model, haptics: settings.haptics) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous) }
    private var isPictureCard: Bool { item.kind == .image }
    private var padding: CGFloat { isPictureCard ? 8 : (compact ? 12 : 14) }

    var body: some View {
        Button {
            onOpen()
        } label: {
            VStack(alignment: .leading, spacing: isPictureCard ? 8 : 10) {
                content
                footer
                    .padding(.horizontal, isPictureCard ? 4 : 0)
                    .padding(.bottom, isPictureCard ? 2 : 0)
            }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground(transparency: settings.cardTransparency)
            .contentShape(shape)
        }
        .buttonStyle(SyncedCardButtonStyle())
        .contentShape(.contextMenuPreview, shape)
        .contextMenu { SyncedItemMenuItems(item: item, actions: actions) }
        .onDrag { actions.dragProvider(for: item) }
        .accessibilityLabel(SyncedItemActions.accessibilitySummary(item, transfers: model.snapshot.transfers))
        .accessibilityHint("Shows details.")
        .accessibilityAction(named: "Copy") { actions.copy(item) }
        .accessibilityAction(named: "Share") { actions.share(item) }
        .accessibilityAction(named: "Delete") { actions.delete(item) }
    }

    // MARK: - Body per kind

    @ViewBuilder
    private var content: some View {
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
            SyncedThumbnailView(
                item: item,
                maxPixel: compact ? 480 : 900,
                maxHeight: compact ? 260 : 340,
                placeholderHeight: Self.picturePlaceholderHeight(compact: compact)
            )
        case .file:
            fileBody
        }
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

    private var fileBody: some View {
        let name = item.filePayload?.fileName ?? "File"
        let fraction = SyncedItemActions.transferFraction(item, transfers: model.snapshot.transfers)
        return VStack(alignment: .leading, spacing: 10) {
            if SyncedItemActions.hasPicture(item) {
                SyncedThumbnailView(
                    item: item,
                    maxPixel: compact ? 480 : 900,
                    maxHeight: compact ? 220 : 300,
                    placeholderHeight: Self.picturePlaceholderHeight(compact: compact),
                    showsFailure: false
                )
            }
            HStack(alignment: .center, spacing: 10) {
                SyncedFileTile(fileName: name, size: compact ? 36 : 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(SyncedItemActions.fileStatus(item, transfers: model.snapshot.transfers))
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
    }

    private var footer: some View {
        HStack(spacing: 6) {
            KindChip(kind: item.kind, size: 20)
            Text(TimeLabel.short(item.date))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if !item.isOwn {
                Text(item.sourceLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
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

    static func opaqueFragment(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 24 ? "\(trimmed.prefix(24))…" : trimmed
    }

    static func picturePlaceholderHeight(compact: Bool) -> CGFloat { compact ? 150 : 210 }
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

/// A gentle press-down for cards.
struct SyncedCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.75), value: configuration.isPressed)
    }
}
