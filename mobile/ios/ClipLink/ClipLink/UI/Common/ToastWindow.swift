import Combine
import SwiftUI
import UIKit

/// Shows `model.toast` in a pass-through window of its own at alert level, so
/// toasts land above everything the app presents - the pairing sheet, the
/// scanner's full-screen cover, Quick Look, share sheets - instead of under
/// it. Attach once per scene (RootView's background). The window is only on
/// screen while a toast is, and only the toast itself takes touches.
struct ToastWindowHost: UIViewRepresentable {
    let model: AppModel

    func makeUIView(context: Context) -> ToastWindowAnchor {
        ToastWindowAnchor(model: model)
    }

    func updateUIView(_ view: ToastWindowAnchor, context: Context) {}
}

/// Invisible view inside the app's window: finds the window scene from
/// there, owns the toast window and shows it while a toast is set.
final class ToastWindowAnchor: UIView {
    private let model: AppModel
    private var toastWindow: ToastPassthroughWindow?
    private var controller: ToastHostingController?
    private var subscription: AnyCancellable?
    /// Bumped on every show / hide, so a stale delayed hide does nothing.
    private var generation = 0

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let appWindow = window, let scene = appWindow.windowScene else {
            tearDown()
            return
        }
        if toastWindow?.windowScene === scene { return }
        tearDown()

        let toastWindow = ToastPassthroughWindow(windowScene: scene)
        toastWindow.windowLevel = .alert + 1
        toastWindow.backgroundColor = .clear
        let content = ToastWindowContent(model: model) { [weak toastWindow] frame in
            toastWindow?.toastFrame = frame
        }
        let controller = ToastHostingController(rootView: content)
        controller.appWindow = appWindow
        controller.view.backgroundColor = .clear
        toastWindow.rootViewController = controller
        toastWindow.isHidden = true
        self.toastWindow = toastWindow
        self.controller = controller

        // `$toast` fires before the value changes, so the window is up
        // before SwiftUI renders the toast and its entry animation shows.
        subscription = model.$toast
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] showing in self?.setShowing(showing) }
    }

    private func setShowing(_ showing: Bool) {
        generation += 1
        guard let toastWindow, let controller else { return }
        if showing {
            guard toastWindow.isHidden else { return }
            controller.adoptStatusBar(of: toastWindow.windowScene)
            toastWindow.isHidden = false
        } else {
            // Let the exit animation finish first.
            let current = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.generation == current, self.model.toast == nil else { return }
                self.toastWindow?.isHidden = true
                self.toastWindow?.toastFrame = .null
            }
        }
    }

    private func tearDown() {
        generation += 1
        subscription = nil
        toastWindow?.isHidden = true
        toastWindow = nil
        controller = nil
    }
}

/// Lets every touch through to the app except those on the toast (tap to
/// dismiss), and never becomes key - presenting code looks for the key
/// window, and the keyboard stays with the app.
final class ToastPassthroughWindow: UIWindow {
    /// The toast capsule, in window coordinates; `.null` while none shows.
    var toastFrame: CGRect = .null

    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard toastFrame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

fileprivate struct ToastWindowContent: View {
    @ObservedObject var model: AppModel
    let onToastFrame: (CGRect) -> Void

    var body: some View {
        ToastOverlay(toast: $model.toast)
            .onPreferenceChange(ToastFrameKey.self) { onToastFrame($0) }
    }
}

/// A window with a root view controller takes part in status bar and
/// rotation decisions: this one keeps whatever the app's window has.
fileprivate final class ToastHostingController: UIHostingController<ToastWindowContent> {
    weak var appWindow: UIWindow?
    private var statusBarStyle: UIStatusBarStyle = .default
    private var statusBarHidden = false

    override init(rootView: ToastWindowContent) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Copies the status bar as it is right now, just before the window shows.
    func adoptStatusBar(of scene: UIWindowScene?) {
        guard let manager = scene?.statusBarManager else { return }
        statusBarStyle = manager.statusBarStyle
        statusBarHidden = manager.isStatusBarHidden
        setNeedsStatusBarAppearanceUpdate()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { statusBarStyle }
    override var prefersStatusBarHidden: Bool { statusBarHidden }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        var top = appWindow?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top?.supportedInterfaceOrientations ?? super.supportedInterfaceOrientations
    }
}

/// The toast capsule's frame, reported up to the window for hit-testing.
struct ToastFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull { value = next }
    }
}
