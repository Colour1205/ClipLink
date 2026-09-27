import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The system Paste button (iOS 16+). A tap on it is the user's consent, so
/// reading the clipboard this way never shows iOS's "Allow Paste" prompt -
/// the iOS counterpart of HarmonyOS' PasteButton.
@available(iOS 16.0, *)
struct SyncedPasteControl: UIViewRepresentable {
    let accent: UIColor
    let onPaste: ([NSItemProvider]) -> Void

    func makeUIView(context: Context) -> SyncedPasteHostView {
        SyncedPasteHostView(accent: accent, onPaste: onPaste)
    }

    func updateUIView(_ view: SyncedPasteHostView, context: Context) {
        view.onPaste = onPaste
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SyncedPasteHostView, context: Context) -> CGSize? {
        uiView.intrinsicContentSize
    }
}

/// Hosts the UIPasteControl and is its target: it declares what it accepts
/// (`pasteConfiguration`) and receives the item providers.
@available(iOS 16.0, *)
final class SyncedPasteHostView: UIView {
    var onPaste: ([NSItemProvider]) -> Void
    private let control: UIPasteControl

    init(accent: UIColor, onPaste: @escaping ([NSItemProvider]) -> Void) {
        self.onPaste = onPaste
        let configuration = UIPasteControl.Configuration()
        configuration.displayMode = .iconAndLabel
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = accent
        configuration.baseForegroundColor = .white
        control = UIPasteControl(configuration: configuration)
        super.init(frame: .zero)

        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
            UTType.image.identifier,
            UTType.plainText.identifier,
            UTType.url.identifier,
            UTType.data.identifier,
            UTType.item.identifier,
        ])
        control.target = self
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.topAnchor.constraint(equalTo: topAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        let size = control.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return CGSize(width: max(size.width, 44), height: max(size.height, 44))
    }

    override func paste(itemProviders: [NSItemProvider]) {
        onPaste(itemProviders)
    }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool { true }
}
