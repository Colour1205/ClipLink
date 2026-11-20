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
    /// The size the system control wants, once it knows (see SyncedPasteButton).
    let onFit: (CGSize) -> Void

    func makeUIView(context: Context) -> SyncedPasteHostView {
        SyncedPasteHostView(accent: accent, onPaste: onPaste, onFit: onFit)
    }

    func updateUIView(_ view: SyncedPasteHostView, context: Context) {
        view.onPaste = onPaste
        view.onFit = onFit
    }
}

/// The Paste control at the size the system gives it. UIPasteControl cannot say
/// how big it is until it is on screen: asked before that (as `sizeThatFits`
/// did, once) iOS 16 answers with nothing, which came out as the 44 pt minimum -
/// a bare square instead of the "Paste" capsule. So the control reports its size
/// when it has one, and until then the capsule is drawn at a usual size.
@available(iOS 16.0, *)
struct SyncedPasteButton: View {
    let accent: UIColor
    let onPaste: ([NSItemProvider]) -> Void

    @State private var size = CGSize(width: 96, height: 44)

    var body: some View {
        SyncedPasteControl(accent: accent, onPaste: onPaste, onFit: { fit in
            if fit != size { size = fit }
        })
        .frame(width: size.width, height: size.height)
    }
}

/// Hosts the UIPasteControl and is its target: it declares what it accepts
/// (`pasteConfiguration`) and receives the item providers.
@available(iOS 16.0, *)
final class SyncedPasteHostView: UIView {
    var onPaste: ([NSItemProvider]) -> Void
    var onFit: (CGSize) -> Void
    private let control: UIPasteControl
    private var lastFit = CGSize.zero

    init(accent: UIColor, onPaste: @escaping ([NSItemProvider]) -> Void, onFit: @escaping (CGSize) -> Void) {
        self.onPaste = onPaste
        self.onFit = onFit
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

    /// Reports the control's own size when it has a real one (at least a tap
    /// target wide). Its content loads after it is on screen, so this is tried
    /// when it arrives, on every layout, and a few times shortly after.
    private func reportFit() {
        let size = control.intrinsicContentSize
        guard size.width >= 44, size.height >= 24 else { return }
        let fit = CGSize(width: ceil(size.width), height: max(ceil(size.height), 44))
        guard fit != lastFit else { return }
        lastFit = fit
        DispatchQueue.main.async { [weak self] in self?.onFit(fit) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        reportFit()
        for delay in [0.1, 0.4, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.reportFit() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportFit()
    }

    override func paste(itemProviders: [NSItemProvider]) {
        onPaste(itemProviders)
    }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool { true }
}
