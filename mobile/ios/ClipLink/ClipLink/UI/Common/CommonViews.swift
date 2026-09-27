import SwiftUI

/// Transient message capsule above the tab bar - the iOS stand-in for
/// Android's snackbar / HarmonyOS' toast. One slot: a new message replaces
/// the current one. Shown through `ToastWindowHost`, so it sits above sheets.
struct ToastOverlay: View {
    @Binding var toast: Toast?

    /// The last toast spoken, so one showing in several scenes is said once.
    private static var announcedID: UUID?

    var body: some View {
        VStack {
            Spacer()
            if let toast {
                Text(toast.message)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ToastFrameKey.self, value: proxy.frame(in: .global))
                    })
                    .padding(.horizontal, 24)
                    .padding(.bottom, 132)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
                    .onTapGesture { self.toast = nil }
                    .accessibilityAddTraits(.isStaticText)
                    .task(id: toast.id) {
                        Self.announce(toast)
                        try? await Task.sleep(nanoseconds: UInt64(Self.duration(for: toast.message) * 1_000_000_000))
                        if self.toast?.id == toast.id {
                            withAnimation(.easeOut(duration: 0.25)) { self.toast = nil }
                        }
                    }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: toast)
        .allowsHitTesting(toast != nil)
    }

    /// Long enough to read: 3 s for "Copied.", up to 8 s for a sentence, and
    /// twice that under VoiceOver.
    static func duration(for message: String) -> Double {
        let seconds = min(8, max(3, 1.5 + Double(message.count) / 18))
        return UIAccessibility.isVoiceOverRunning ? seconds * 2 : seconds
    }

    /// A toast appearing doesn't move VoiceOver's focus, so speak it - queued,
    /// so it isn't cut off by (or cut off) the speech for the tap that caused it.
    private static func announce(_ toast: Toast) {
        guard announcedID != toast.id else { return }
        announcedID = toast.id
        UIAccessibility.post(
            notification: .announcement,
            argument: NSAttributedString(string: toast.message, attributes: [.accessibilitySpeechQueueAnnouncement: true])
        )
    }
}

/// Centered illustration + title + body, for empty lists.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 96, height: 96)
                .background(Circle().fill(Color(UIColor.tertiarySystemFill)))
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Uppercased footnote header, like Settings' section headers.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Glyph for an item kind, used on chips and file rows.
extension SyncedItem.Kind {
    var systemImage: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .opaque: return "key.fill"
        case .image: return "photo"
        case .file: return "doc.fill"
        }
    }

    var label: String {
        switch self {
        case .text: return "Text"
        case .link: return "Link"
        case .opaque: return "Encoded data"
        case .image: return "Image"
        case .file: return "File"
        }
    }
}

/// Accent-tinted rounded tile holding a white glyph (HarmonyOS' type chip).
struct KindChip: View {
    let kind: SyncedItem.Kind
    var size: CGFloat = 36

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Image(systemName: kind.systemImage)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size / 3.2, style: .continuous).fill(settings.accentTheme.color))
            .accessibilityLabel(kind.label)
    }
}

/// Green/grey connection status pill.
struct ConnectionPill: View {
    let snapshot: EngineSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundColor(color == .gray ? .secondary : color)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        if snapshot.connectedCount > 0 { return Theme.connected }
        if snapshot.network.localNetwork == .denied { return .orange }
        return .gray
    }

    private var text: String {
        let n = snapshot.connectedCount
        if n > 0 { return "\(n) device\(n == 1 ? "" : "s") connected" }
        if snapshot.network.localNetwork == .denied { return "Local Network off" }
        return snapshot.network.running ? "Looking for devices…" : "Not connected"
    }
}
