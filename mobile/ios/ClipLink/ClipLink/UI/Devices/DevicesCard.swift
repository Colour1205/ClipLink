import SwiftUI
import UIKit

/// One device on the Devices tab. Tap opens the detail screen (the ⋯ menu and
/// Trust button are separate controls); long-press and swipe offer the same
/// actions as the menu. Presses feel like a Synced card: a gentle spring.
///
/// The card shows one address at most - the one the live connection uses.
/// Every other address is on the detail screen.
struct DevicesCard: View {
    let row: DeviceRow
    let actions: DeviceActions
    /// The accent fill (AccentTheme.fill): it sits under a white glyph.
    let accent: Color
    /// "Card transparency" (0...100): fades this card's fill only.
    let transparency: Double
    let onOpen: () -> Void
    let onRename: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The main button is pressed: the whole card (not just its label) dips.
    @State private var pressed = false
    /// This card's Remove or Block, waiting for the user's answer. The dialog
    /// lives on the card (one per card, not one for the list): on iPad - and
    /// from iOS 26 on iPhone too - it points at the card it is about.
    @State private var pending: DevicePending?

    private var status: DeviceStatus { row.status }
    private var blocked: Bool { row.blocked }
    private var name: String { actions.name(row) }
    private var showsTrustButton: Bool { !row.trusted && !row.blocked }
    private var largeText: Bool { typeSize.isAccessibilitySize }

    private var primaryColor: Color { blocked ? DevicesBlockedStyle.primary : .primary }
    private var secondaryColor: Color { blocked ? DevicesBlockedStyle.secondary : .secondary }
    private var statusColor: Color { status == .connected ? Theme.connected : secondaryColor }

    /// The line under the status: where the live connection is, or, for a
    /// device we can't reach, when we last heard from it.
    private var address: String? { row.connected ? row.connectionAddress : nil }
    private var lastSeenText: String? {
        guard !row.connected, !blocked, let lastSeen = row.lastSeen else { return nil }
        guard status == .pairedOffline || status == .away else { return nil }
        return "Last seen \(DevicesRelativeTime.string(for: lastSeen))"
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous) }

    /// The card's own surface. A blocked card is dark gray in both
    /// appearances and always opaque; transparency doesn't apply to it.
    @ViewBuilder
    private var fill: some View {
        if blocked {
            shape.fill(DevicesBlockedStyle.fill)
        } else {
            shape.fill(Color(Theme.card).opacity(1 - min(max(transparency, 0), 95) / 100))
        }
    }

    var body: some View {
        layout
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(fill)
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .opacity(pressed ? 0.92 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.75), value: pressed)
            .devicesBlockedAppearance(blocked)
            .contentShape(.contextMenuPreview, shape)
            .contextMenu { items }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) { swipe }
            .deviceConfirmation($pending, actions: actions)
    }

    /// One row of tile, text, Trust and ⋯; at accessibility text sizes the text
    /// gets the whole width (tile on top, ⋯ in the corner, Trust underneath).
    /// Trust and ⋯ are always buttons of their own, never inside the one that
    /// opens details.
    @ViewBuilder
    private var layout: some View {
        if largeText {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 8) {
                    openButton
                    if showsTrustButton { trustButton }
                }
                menu
            }
        } else {
            HStack(alignment: .center, spacing: 8) {
                openButton
                if showsTrustButton { trustButton }
                menu
            }
        }
    }

    /// The card itself: tile and text. Tapping it opens the detail screen.
    private var openButton: some View {
        Button(action: onOpen) {
            tileAndText
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(DevicesCardPressStyle(pressed: $pressed))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens details.")
    }

    @ViewBuilder
    private var tileAndText: some View {
        if largeText {
            VStack(alignment: .leading, spacing: 8) {
                DevicesIconTile(status: status, trusted: row.trusted, accent: accent)
                texts
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                DevicesIconTile(status: status, trusted: row.trusted, accent: accent)
                texts
                Spacer(minLength: 0)
            }
        }
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.body.weight(.semibold))
                .foregroundColor(primaryColor)
                .lineLimit(largeText ? 4 : 1)
                .multilineTextAlignment(.leading)
            Text(status.text)
                .font(.subheadline)
                .foregroundColor(statusColor)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let address {
                Text(address)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(secondaryColor)
                    .lineLimit(largeText ? 2 : 1)
                    .minimumScaleFactor(0.8)
            }
            if let lastSeenText {
                Text(lastSeenText)
                    .font(.caption)
                    .foregroundColor(secondaryColor)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func askRemove() { pending = DevicePending(kind: .remove, row: row) }
    private func askBlock() { pending = DevicePending(kind: .block, row: row) }

    // MARK: - Controls

    private var trustButton: some View {
        Button("Trust") { actions.trust(row) }
            .buttonStyle(.bordered)
            .accessibilityLabel("Trust \(name)")
    }

    private var menu: some View {
        Menu {
            items
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundColor(blocked ? DevicesBlockedStyle.secondary : Color(UIColor.secondaryLabel))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More actions for \(name)")
    }

    private var items: some View {
        DeviceMenuItems(row: row, actions: actions, onRename: onRename, onRemove: askRemove, onBlock: askBlock)
    }

    @ViewBuilder
    private var swipe: some View {
        if row.blocked {
            Button {
                actions.unblock(row)
            } label: {
                Label("Unblock", systemImage: "hand.raised.slash")
            }
            .tint(accent)
        } else {
            if row.trusted {
                // Not role: .destructive - on iOS 15 that animates the row
                // away before the confirmation dialog has been answered.
                Button {
                    askRemove()
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .tint(.red)
            } else {
                Button {
                    actions.trust(row)
                } label: {
                    Label("Trust", systemImage: "checkmark.shield")
                }
                // White label on it: the high-contrast fill, not the tint.
                .tint(accent)
            }
            Button {
                askBlock()
            } label: {
                Label("Block", systemImage: "hand.raised")
            }
            .tint(DevicesBlockedStyle.swipeFill)
            Button {
                onRename()
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.gray)
        }
    }

    // MARK: - VoiceOver

    private var accessibilityLabel: String {
        var parts = [name, status.spokenText]
        if let address { parts.append("address \(address)") }
        if let lastSeenText { parts.append(lastSeenText.lowercased()) }
        return parts.joined(separator: ", ")
    }
}

/// The Synced card's press (a spring-back dip), reported to the card so the
/// whole card - not only the button's label - dips together.
private struct DevicesCardPressStyle: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { pressed = $0 }
    }
}
