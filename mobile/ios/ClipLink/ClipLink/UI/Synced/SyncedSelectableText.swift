import SwiftUI
import UIKit

/// Read-only, selectable text with tappable links - a UITextView, because
/// SwiftUI's `.textSelection` on iOS 15 can only copy the whole string.
/// Sizes itself to its content so it can sit inside a ScrollView.
struct SyncedSelectableText: View {
    let text: String
    var monospaced = false
    var tint: UIColor = .link

    @State private var height: CGFloat = 24

    var body: some View {
        SyncedTextViewRepresentable(text: text, monospaced: monospaced, tint: tint, height: $height)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

private struct SyncedTextViewRepresentable: UIViewRepresentable {
    let text: String
    let monospaced: Bool
    let tint: UIColor
    @Binding var height: CGFloat

    func makeUIView(context: Context) -> SyncedAutoSizingTextView {
        let view = SyncedAutoSizingTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = [.link]
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: SyncedAutoSizingTextView, context: Context) {
        let font = SyncedTextFont.body(monospaced: monospaced)
        var changed = false
        if view.font != font {
            view.font = font
            changed = true
        }
        // Compared with the string last set, not `view.text`: that one is
        // bridged back from the text storage, a full copy on every update.
        if view.appliedText != text {
            view.appliedText = text
            view.text = text
            changed = true
        }
        view.tintColor = tint
        let binding = _height
        view.onHeightChange = { newHeight in
            if abs(binding.wrappedValue - newHeight) > 0.5 { binding.wrappedValue = newHeight }
        }
        if changed { view.recalculateHeight() }
    }
}

/// Reports the height its text needs whenever its width, text or Dynamic
/// Type size changes.
final class SyncedAutoSizingTextView: UITextView {
    var onHeightChange: ((CGFloat) -> Void)?
    var appliedText: String?
    private var lastWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            recalculateHeight()
        }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            recalculateHeight()
        }
    }

    func recalculateHeight() {
        guard bounds.width > 0 else { return }
        let fitting = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
        let height = max(ceil(fitting), 20)
        // Never mutate SwiftUI state during its own update pass.
        DispatchQueue.main.async { [weak self] in self?.onHeightChange?(height) }
    }
}

/// Selectable text for very long content (a pasted log, a JSON dump): the
/// text view scrolls itself, so TextKit only lays out what's on screen
/// instead of sizing the whole string up front, and link detection - a scan
/// of every character - is off.
struct SyncedScrollingText: UIViewRepresentable {
    let text: String
    var monospaced = false
    var tint: UIColor = .link

    final class Coordinator {
        var appliedText: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let font = SyncedTextFont.body(monospaced: monospaced)
        if view.font != font { view.font = font }
        if context.coordinator.appliedText != text {
            context.coordinator.appliedText = text
            view.text = text
        }
        view.tintColor = tint
    }
}

enum SyncedTextFont {
    static func body(monospaced: Bool) -> UIFont {
        monospaced
            ? UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 16, weight: .regular))
            : .preferredFont(forTextStyle: .body)
    }
}
