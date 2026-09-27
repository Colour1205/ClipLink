import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Share → ClipLink" from any app - the iOS counterpart of Android's
/// share-sheet target.
///
/// The extension runs the same sync engine over the same App Group storage
/// and Keychain identity as the app, so it IS this iPhone on the network, not
/// a second device. It signs the shared item into history and sends it to
/// every paired device it can reach in a few seconds; anything it can't reach
/// gets the item later from history, the next time the app (or a Background
/// App Refresh round) connects.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let host = UIHostingController(rootView: ShareView(model: model) { [weak self] in self?.close() })
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        model.onFinished = { [weak self] cancelled in
            if cancelled {
                self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            } else {
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        }
        model.start(providers: providers)
    }

    private func close() {
        model.close()
    }
}

@MainActor
final class ShareModel: ObservableObject {
    enum Phase: Equatable {
        case preparing
        case sending
        case sent(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var title = "ClipLink"
    @Published private(set) var preview = ""
    @Published private(set) var thumbnail: UIImage?
    @Published private(set) var connected = 0
    @Published private(set) var paired = 0

    /// Called once, when the sheet can go; true when the user cancelled.
    var onFinished: ((Bool) -> Void)?
    private var engine: SyncEngine?
    private var startedAt = Date()
    private var stopping = false
    /// Cancel was tapped while the item was still being prepared: it must
    /// not be sent after all.
    private var cancelled = false
    /// The item was handed to the engine, which hasn't signed and stored it
    /// yet (a file is hashed and moved into the store first).
    private var storing = false
    private var afterStored: (() -> Void)?
    /// ClipLink's own node is up right now (e.g. side by side on iPad): don't
    /// start a second node with the same identity - store the item and let
    /// the app send it.
    private var handoff = false

    /// Inline images bigger than this go as a file instead: every
    /// history_batch re-sends inline images, and the extension has a tight
    /// memory budget.
    private static let maxInlineImageBytes = 16 * 1024 * 1024
    /// Longest Done waits for a file that is still being hashed and stored.
    private static let maxStoreWait: TimeInterval = 30

    func start(providers: [NSItemProvider]) {
        guard SharedContainer.isAvailable else {
            phase = .failed("ClipLink's shared storage isn't set up. Open ClipLink once, then try again.")
            return
        }
        let identity: KeychainIdentity
        do {
            identity = try KeychainIdentity.loadOrCreate()
        } catch {
            phase = .failed("\(error)")
            return
        }
        let directory = SharedContainer.storageDirectory(migrateLegacy: false)
        var config = EngineConfig(storageDirectory: directory)
        config.enableSweeps = true
        // A sender only: peers' history batches (inline images and all) and
        // file bytes would cost memory the extension doesn't have.
        config.sendOnly = true
        config.maxLineBytes = 8 * 1024 * 1024
        let engine = SyncEngine(config: config, identity: identity, secrets: KeychainSecretStore())
        self.engine = engine
        handoff = SyncEngine.anotherNodeIsLive(in: directory)
        if !handoff { engine.enterForeground() }

        Task {
            let capture = await ItemLoader.capture(from: providers)
            guard !cancelled else {
                if case .file(let url, _) = capture { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                return
            }
            guard let capture else {
                phase = .failed("ClipLink can't send this kind of item.")
                return
            }
            send(capture, with: engine)
        }
    }

    private func send(_ capture: Capture, with engine: SyncEngine) {
        phase = .sending
        startedAt = Date()
        storing = true
        let onStored: (SendResult) -> Void = { [weak self] result in self?.stored(result) }
        switch capture {
        case .text(let text):
            title = SyncedItem.kind(for: ClipboardEntry(content: text, type: Wire.EntryType.text, deviceId: "", timestamp: "")) == .link ? "Link" : "Text"
            preview = String(text.prefix(400))
            engine.sendText(text, completion: onStored)
        case .image(let png):
            title = "Image"
            Task { thumbnail = await Task.detached(priority: .userInitiated) { ItemLoader.thumbnail(ofImageData: png, maxPixelSize: 720) }.value }
            if png.count > Self.maxInlineImageBytes {
                let url = ItemLoader.tempURL(named: "Image.png")
                try? png.write(to: url)
                engine.sendFile(at: url, name: "Image.png", moveIntoStore: true, completion: onStored)
            } else {
                engine.sendImage(png: png, completion: onStored)
            }
        case .file(let url, let name):
            title = "File"
            preview = name
            engine.sendFile(at: url, name: name, moveIntoStore: true, completion: onStored)
        }
        poll()
    }

    /// The engine signed and stored the item (or gave up on it).
    private func stored(_ result: SendResult) {
        storing = false
        if case .failed(let why) = result { phase = .failed(why) }
        if handoff, case .sent = result {
            // The item is in the shared history: the live app sends it now.
            SyncEngine.announceExternalChange()
            phase = .sent("Sent through ClipLink.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.stop() }
        }
        let then = afterStored
        afterStored = nil
        then?()
    }

    /// Runs `then` once the item is stored, or right away if nothing is
    /// being stored. Bounded: a file that isn't stored by then won't be.
    private func whenStored(_ then: @escaping () -> Void) {
        guard storing else { return then() }
        afterStored = then
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxStoreWait) { [weak self] in
            guard let self, let then = self.afterStored else { return }
            self.afterStored = nil
            then()
        }
    }

    /// Keeps the engine up while paired devices connect (each gets the new
    /// item via live send or its history_batch), then wraps up.
    private func poll() {
        guard let engine, !stopping, !handoff else { return }
        engine.currentSnapshot { [weak self] snapshot in
            guard let self, !self.stopping else { return }
            if case .failed = self.phase { return }
            self.connected = snapshot.connectedCount
            self.paired = snapshot.devices.filter(\.trusted).count
            let elapsed = Date().timeIntervalSince(self.startedAt)
            let everyone = self.paired > 0 && self.connected >= self.paired
            // Never "sent" before the engine has actually stored the item.
            if !self.storing, (elapsed >= 2 && everyone) || elapsed >= 12 {
                self.phase = .sent(self.summary())
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.stop() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.poll() }
            }
        }
    }

    private func summary() -> String {
        if paired == 0 { return "Saved. Pair a device in ClipLink to sync it." }
        if connected == 0 { return "Saved — it syncs the next time ClipLink reaches your devices." }
        if connected < paired { return "Sent to \(connected) of \(paired) devices. The rest get it next time." }
        return "Sent to \(connected) device\(connected == 1 ? "" : "s")."
    }

    /// The sheet's button: Cancel while the item is still being prepared,
    /// Done after that.
    func close() {
        if phase == .preparing { cancel() } else { stop() }
    }

    /// Nothing has been handed to the engine yet: send nothing, and tell the
    /// host app the share was cancelled.
    private func cancel() {
        guard !stopping else { return }
        cancelled = true
        stopping = true
        guard let engine else { return finish(cancelled: true) }
        engine.finish(grace: 0) { [weak self] in self?.finish(cancelled: true) }
    }

    /// Waits for the item to be stored and for in-flight file streams to
    /// finish (both bounded), then closes the sheet.
    func stop() {
        guard !stopping else { return }
        stopping = true
        guard let engine else { return finish(cancelled: false) }
        whenStored {
            engine.finish(grace: 20) { [weak self] in self?.finish(cancelled: false) }
        }
    }

    private func finish(cancelled: Bool) {
        let done = onFinished
        onFinished = nil
        done?(cancelled)
    }
}

private struct ShareView: View {
    @ObservedObject var model: ShareModel
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 16) {
                HStack {
                    Label(model.title, systemImage: icon)
                        .font(.headline)
                    Spacer()
                    Button(buttonTitle, action: done)
                        .font(.body.weight(.semibold))
                }
                if let thumbnail = model.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else if !model.preview.isEmpty {
                    Text(model.preview)
                        .font(.body)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(UIColor.tertiarySystemFill)))
                }
                status
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(UIColor.systemBackground)))
            .shadow(color: .black.opacity(0.15), radius: 20, y: 6)
            .padding(16)
        }
    }

    private var icon: String {
        switch model.title {
        case "Image": return "photo"
        case "File": return "doc.fill"
        case "Link": return "link"
        default: return "doc.on.clipboard"
        }
    }

    private var buttonTitle: String {
        model.phase == .preparing ? "Cancel" : "Done"
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .preparing:
            HStack(spacing: 8) { ProgressView(); Text("Preparing…").foregroundStyle(.secondary) }
        case .sending:
            HStack(spacing: 8) {
                ProgressView()
                Text(model.connected > 0
                     ? "Sending — \(model.connected) device\(model.connected == 1 ? "" : "s") connected…"
                     : "Looking for your devices…")
                    .foregroundStyle(.secondary)
            }
        case .sent(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
        }
    }
}
