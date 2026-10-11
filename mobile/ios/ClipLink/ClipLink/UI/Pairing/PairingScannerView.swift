import AVFoundation
import SwiftUI
import UIKit

/// Full-screen QR scanner for another device's pairing code. Delivers the
/// first code it reads, exactly once, through `onCode`; the presenter
/// dismisses it.
struct PairingScannerView: View {
    let onCode: (String) -> Void
    let onCancel: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var state: PairingCameraState = .checking
    /// Why the running camera is paused (iPad multitasking, another app on
    /// the camera), or nil while it streams.
    @State private var interruption: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch state {
            case .checking:
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            case .ready:
                PairingCameraPreview(
                    onCode: onCode,
                    onFailure: { state = .unavailable },
                    onInterruption: { interruption = $0 }
                )
                .ignoresSafeArea()
                if let interruption {
                    // Covers the preview but keeps it (and its session)
                    // alive: the camera resumes by itself once it's free.
                    Color.black.ignoresSafeArea()
                    message(
                        systemImage: "video.slash.fill",
                        title: "Camera paused",
                        detail: interruption,
                        showSettings: false
                    )
                } else {
                    PairingViewfinder()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            case .denied:
                message(
                    systemImage: "camera.fill",
                    title: "Camera access is off",
                    detail: "Allow camera access for ClipLink in Settings to scan a pairing code, or pair by address instead.",
                    showSettings: true
                )
            case .restricted:
                message(
                    systemImage: "camera.fill",
                    title: "Camera access is restricted",
                    detail: "This \(ThisDeviceNoun.current) doesn't allow camera access. Pair by address instead.",
                    showSettings: false
                )
            case .unavailable:
                message(
                    systemImage: "video.slash.fill",
                    title: "No camera available.",
                    detail: "Pair by address instead: enter the other device's IP address or paste its pairing info.",
                    showSettings: false
                )
            }

            chrome
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(true)
        .task { await evaluate() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if state != .ready { Task { await evaluate() } }
        }
    }

    private var chrome: some View {
        VStack {
            HStack {
                Button("Cancel", action: onCancel)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
            }
            Spacer()
            if state == .ready, interruption == nil {
                Text("Point the camera at the pairing QR code on the other device. Its pairing screen has to be open too.")
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(16)
    }

    private func message(systemImage: String, title: String, detail: String, showSettings: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundColor(.white)
            Text(detail)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if showSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 40)
        .accessibilityElement(children: .contain)
    }

    private func evaluate() async {
        guard PairingCameraPreview.captureDevice() != nil else {
            state = .unavailable
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            state = .ready
        case .notDetermined:
            state = .checking
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            state = granted ? .ready : .denied
        case .restricted:
            state = .restricted
        case .denied:
            state = .denied
        @unknown default:
            state = .denied
        }
    }
}

enum PairingCameraState: Equatable {
    case checking, ready, denied, restricted, unavailable
}

// MARK: - Viewfinder

/// Dimmed surround with a clear rounded square and white corner brackets.
private struct PairingViewfinder: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height) * 0.68
            ZStack {
                Color.black.opacity(0.45)
                    .mask(
                        ZStack {
                            Rectangle()
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .frame(width: side, height: side)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    )
                PairingViewfinderCorners(radius: 26, length: side * 0.16)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    .frame(width: side, height: side)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityHidden(true)
    }
}

private struct PairingViewfinderCorners: Shape {
    let radius: CGFloat
    let length: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, rect.width / 4)
        let l = max(length, r + 4)
        // Top-left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + l))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
        // Top-right
        path.move(to: CGPoint(x: rect.maxX - l, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
        // Bottom-right
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        // Bottom-left
        path.move(to: CGPoint(x: rect.minX + l, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
        return path
    }
}

// MARK: - Camera

/// The live camera preview; owns the capture session through its coordinator.
struct PairingCameraPreview: UIViewRepresentable {
    let onCode: (String) -> Void
    let onFailure: () -> Void
    let onInterruption: (String?) -> Void

    static func captureDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    func makeCoordinator() -> PairingScannerSession {
        PairingScannerSession()
    }

    func makeUIView(context: Context) -> PairingPreviewView {
        let view = PairingPreviewView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = context.coordinator.session
        context.coordinator.onCode = onCode
        context.coordinator.onFailure = onFailure
        context.coordinator.onInterruption = onInterruption
        context.coordinator.onConfigured = { [weak view] device in view?.cameraReady(device) }
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: PairingPreviewView, context: Context) {
        context.coordinator.onCode = onCode
        context.coordinator.onFailure = onFailure
        context.coordinator.onInterruption = onInterruption
    }

    static func dismantleUIView(_ uiView: PairingPreviewView, coordinator: PairingScannerSession) {
        coordinator.stop()
    }
}

/// Hosts the preview layer and keeps its picture upright in every interface
/// orientation (the connection starts out portrait, which shows the feed
/// sideways in landscape).
final class PairingPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    // swiftlint:disable:next force_cast
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    /// iOS 17+: an AVCaptureDevice.RotationCoordinator, which follows the
    /// interface (180° turns included) and reports the angle to draw at.
    private var rotationCoordinator: NSObject?
    private var rotationObservation: NSKeyValueObservation?

    /// The session has its camera (on the main queue): the preview
    /// connection only exists from now on.
    func cameraReady(_ device: AVCaptureDevice) {
        if #available(iOS 17.0, *) {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotationCoordinator = coordinator
            rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async { self?.apply(angle) }
            }
        } else {
            updateOrientation()
        }
    }

    @available(iOS 17.0, *)
    private func apply(_ angle: CGFloat) {
        guard let connection = previewLayer.connection,
              connection.videoRotationAngle != angle,
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    // iOS 15-16: follow the window scene's interface orientation.

    override func didMoveToWindow() {
        super.didMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        if #available(iOS 17.0, *) { return }
        guard window != nil else { return }
        // A 180° turn keeps the bounds, so layoutSubviews alone misses it.
        NotificationCenter.default.addObserver(self, selector: #selector(deviceOrientationChanged), name: UIDevice.orientationDidChangeNotification, object: nil)
        updateOrientation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateOrientation()
    }

    @objc private func deviceOrientationChanged() {
        // The interface turns a moment after the device does.
        DispatchQueue.main.async { [weak self] in self?.updateOrientation() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.updateOrientation() }
    }

    private func updateOrientation() {
        if #available(iOS 17.0, *) { return }
        // UIInterfaceOrientation and AVCaptureVideoOrientation share raw
        // values (1 portrait … 4 landscape left); unknown (0) maps to nil.
        guard let connection = previewLayer.connection,
              connection.isVideoOrientationSupported,
              let interface = window?.windowScene?.interfaceOrientation,
              let orientation = AVCaptureVideoOrientation(rawValue: interface.rawValue),
              connection.videoOrientation != orientation else { return }
        connection.videoOrientation = orientation
    }
}

/// AVCaptureSession reading QR codes only, configured and started/stopped on
/// its own queue (startRunning blocks). Results, interruptions and the
/// configured camera arrive on the main queue.
final class PairingScannerSession: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()
    var onCode: ((String) -> Void)?
    var onFailure: (() -> Void)?
    /// A reason to show while the camera is interrupted, nil once it streams.
    var onInterruption: ((String?) -> Void)?
    var onConfigured: ((AVCaptureDevice) -> Void)?

    private let queue = DispatchQueue(label: "io.uaena.ClipLink.qr-scanner")
    private var configured = false
    private var delivered = false

    override init() {
        super.init()
        // Selector observers are removed automatically when this deallocates.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(wasInterrupted(_:)), name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.addObserver(self, selector: #selector(interruptionEnded), name: AVCaptureSession.interruptionEndedNotification, object: session)
    }

    func start() {
        queue.async { [self] in
            if !configured {
                guard let device = configure() else {
                    DispatchQueue.main.async { self.onFailure?() }
                    return
                }
                configured = true
                DispatchQueue.main.async { self.onConfigured?(device) }
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Returns the camera it set up, or nil if it can't scan.
    private func configure() -> AVCaptureDevice? {
        guard let device = PairingCameraPreview.captureDevice(),
              let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        // iPad Split View, Slide Over and Stage Manager: keep scanning next
        // to other apps where the hardware allows it.
        if #available(iOS 16.0, *), session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true
        }
        guard session.canAddInput(input) else { return nil }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        guard output.availableMetadataObjectTypes.contains(.qr) else { return nil }
        output.metadataObjectTypes = [.qr]
        Self.tuneFocus(device)
        return device
    }

    // MARK: Interruptions

    @objc private func wasInterrupted(_ note: Notification) {
        let raw = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
        let message = Self.message(for: raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:)))
        DispatchQueue.main.async { self.onInterruption?(message) }
    }

    @objc private func interruptionEnded() {
        DispatchQueue.main.async { self.onInterruption?(nil) }
    }

    private static func message(for reason: AVCaptureSession.InterruptionReason?) -> String? {
        switch reason {
        case .videoDeviceNotAvailableInBackground:
            return nil // Nothing on screen meanwhile; it resumes on return.
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            return "The camera isn't available while ClipLink shares the screen with other apps. Make ClipLink full screen to scan, or pair by address instead."
        case .videoDeviceInUseByAnotherClient:
            return "Another app is using the camera. Scanning resumes when it's done, or pair by address instead."
        case .videoDeviceNotAvailableDueToSystemPressure:
            return "The camera paused to let the device cool down. Scanning resumes in a moment, or pair by address instead."
        default:
            return "The camera is unavailable right now. Scanning resumes when it's free, or pair by address instead."
        }
    }

    /// Codes held close are blurry on cameras with a long minimum focus
    /// distance (iPhone 13 Pro and later): zoom in just enough that a code
    /// filling the viewfinder sits beyond it (Apple's AVCamBarcode approach).
    private static func tuneFocus(_ device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        let minimumFocus = Float(device.minimumFocusDistance)
        guard minimumFocus > 0 else { return }
        let fieldOfView = device.activeFormat.videoFieldOfView
        let codeSize: Float = 40 // mm - a QR on another phone's screen
        let fill: Float = 0.6
        let radians = (fieldOfView / 2) * .pi / 180
        let subjectDistance = (codeSize / fill) / tan(radians)
        guard subjectDistance < minimumFocus else { return }
        let zoom = CGFloat(minimumFocus / subjectDistance)
        device.videoZoomFactor = min(max(1, zoom), min(device.activeFormat.videoMaxZoomFactor, 4))
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered else { return }
        for object in metadataObjects {
            guard let code = object as? AVMetadataMachineReadableCodeObject, code.type == .qr,
                  let value = code.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
            else { continue }
            delivered = true
            stop()
            onCode?(value)
            return
        }
    }
}
