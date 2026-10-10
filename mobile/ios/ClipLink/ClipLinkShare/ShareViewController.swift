import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Share → ClipLink" from any app - the iOS counterpart of Android's
/// share-sheet target: text, a link, or one file or many (see
/// `ItemLoader.shareCaptures`). Nothing goes on this device's clipboard.
///
/// The extension runs the same sync engine over the same App Group storage
/// and Keychain identity as the app, so it IS this iPhone on the network, not
/// a second device. It signs the shared items into history and sends them to
/// every paired device it can reach in a few seconds; anything it can't reach
/// gets them later from history, the next time the app (or a Background App
/// Refresh round) connects.
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
    @Published private(set) var icon = "doc.on.clipboard"
    @Published private(set) var preview = ""
    @Published private(set) var thumbnail: UIImage?
    @Published private(set) var connected = 0
    @Published private(set) var paired = 0

    /// Called once, when the sheet can go; true when the user cancelled.
    var onFinished: ((Bool) -> Void)?
    private var engine: SyncEngine?
    private var startedAt = Date()
    private var stopping = false
    /// Cancel was tapped while the items were still being prepared: they
    /// must not be sent after all.
    private var cancelled = false
    /// Reading (copying) the shared items; cancelled with the share.
    private var loading: Task<Void, Never>?
    /// The items were handed to the engine, which hasn't signed and stored
    /// them all yet (each file is hashed and moved into the store first).
    private var storing = false
    private var lastStoredAt = Date()
    private var afterStored: (() -> Void)?
    /// ClipLink's own node is up right now (e.g. side by side on iPad): don't
    /// start a second node with the same identity - store the items and let
    /// the app send them.
    private var handoff = false
    /// Items the engine stored, and what didn't go (said with the result).
    private var storedCount = 0
    private var failures: [String] = []
    private var problems: [String] = []

    /// Inline images past this many bytes in all go as files instead: every
    /// history_batch re-sends inline images, and the extension has a tight
    /// memory budget (see `ItemLoader.shareCaptures`).
    private static let maxInlineImageBytes = 16 * 1024 * 1024
    /// Longest Done waits for the next file to be hashed and stored.
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
        // ...with no screen to ask on: pairing requests are the app's to take.
        config.acceptPairingRequests = false
        config.maxLineBytes = 8 * 1024 * 1024
        let engine = SyncEngine(config: config, identity: identity, secrets: KeychainSecretStore())
        self.engine = engine
        handoff = SyncEngine.anotherNodeIsLive(in: directory)
        if !handoff { engine.enterForeground() }

        loading = Task {
            let shared = await ItemLoader.shareCaptures(from: providers, limit: Wire.historyCap, inlineBudget: ShareModel.maxInlineImageBytes)
            guard !cancelled else {
                shared.captures.forEach(ItemLoader.discard)
                return
            }
            problems = ShareModel.leftOut(in: shared)
            guard !shared.captures.isEmpty else {
                let nothingSaid = shared.tooLarge.isEmpty && shared.folders == 0
                phase = .failed(nothingSaid ? "ClipLink can't send this kind of item." : problems.joined(separator: " "))
                return
            }
            await send(shared.captures, with: engine)
        }
    }

    private func send(_ captures: [Capture], with engine: SyncEngine) async {
        phase = .sending
        startedAt = Date()
        // Before anything else: Done must wait for these to be stored.
        storing = true
        lastStoredAt = Date()
        describe(captures)
        // Before the engine moves a file it previews into the store.
        if let picture = captures.first(where: Self.isPicture) {
            thumbnail = await Task.detached(priority: .userInitiated) { ShareModel.previewImage(of: picture) }.value
        }
        sendNext(captures[...], with: engine)
        poll()
    }

    /// One at a time, in the order shared: each file is hashed and stored
    /// before the next, and the entries go out in that order.
    private func sendNext(_ rest: ArraySlice<Capture>, with engine: SyncEngine) {
        guard let capture = rest.first else { return allStored() }
        let then: (SendResult) -> Void = { [weak self] result in
            ItemLoader.discard(capture)
            self?.stored(result)
            self?.sendNext(rest.dropFirst(), with: engine)
        }
        switch capture {
        case .text(let text):
            engine.sendText(text, completion: then)
        case .image(let png):
            // Within maxInlineImageBytes: shareCaptures made any more a file.
            engine.sendImage(png: png, completion: then)
        case .file(let url, let name):
            engine.sendFile(at: url, name: name, moveIntoStore: true, completion: then)
        }
    }

    /// The engine signed and stored one item (or gave up on it).
    private func stored(_ result: SendResult) {
        lastStoredAt = Date()
        switch result {
        case .sent: storedCount += 1
        case .failed(let why): failures.append(why)
        }
    }

    /// Every item is signed and stored, or given up on.
    private func allStored() {
        storing = false
        switch failures.count {
        case 0: break
        case 1: problems.append(failures[0])
        default: problems.append("\(failures.count) items couldn't be sent.")
        }
        if storedCount == 0 {
            phase = .failed(problems.joined(separator: " "))
        } else if handoff {
            // The items are in the shared history: the live app sends them now.
            SyncEngine.announceExternalChange()
            phase = .sent(withProblems("Sent through ClipLink."))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2 + readingTime) { [weak self] in self?.stop() }
        }
        let then = afterStored
        afterStored = nil
        then?()
    }

    private func describe(_ captures: [Capture]) {
        guard captures.count == 1, let only = captures.first else {
            title = "\(captures.count) items"
            icon = "doc.on.doc.fill"
            let names = captures.map { capture -> String in
                if case .file(_, let name) = capture { return name }
                return "Image"
            }
            preview = names.prefix(5).joined(separator: "\n") + (names.count > 5 ? "\n+ \(names.count - 5) more" : "")
            return
        }
        switch only {
        case .text(let text):
            let link = SyncedItem.kind(for: ClipboardEntry(content: text, type: Wire.EntryType.text, deviceId: "", timestamp: "")) == .link
            title = link ? "Link" : "Text"
            icon = link ? "link" : "doc.on.clipboard"
            preview = String(text.prefix(400))
        case .image:
            title = "Image"
            icon = "photo"
        case .file(_, let name):
            title = "File"
            icon = "doc.fill"
            preview = name
        }
    }

    nonisolated private static func isPicture(_ capture: Capture) -> Bool {
        switch capture {
        case .image: return true
        case .file(let url, _): return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        case .text: return false
        }
    }

    /// Off the main thread: it decodes (part of) the picture.
    nonisolated private static func previewImage(of picture: Capture) -> UIImage? {
        switch picture {
        case .image(let png): return ItemLoader.thumbnail(ofImageData: png, maxPixelSize: 720)
        case .file(let url, _): return ItemLoader.thumbnail(ofImageFileAt: url, maxPixelSize: 720)
        case .text: return nil
        }
    }

    /// What of the share didn't make it, in words.
    private static func leftOut(in shared: SharedItems) -> [String] {
        var out: [String] = []
        switch shared.tooLarge.count {
        case 0: break
        case 1: out.append("\(shared.tooLarge[0]) is over 1 GB, too big to sync.")
        default: out.append("\(shared.tooLarge.count) files are over 1 GB, too big to sync.")
        }
        if shared.folders > 0 { out.append("ClipLink syncs files, not folders.") }
        if shared.unreadable > 0 { out.append("Couldn't read \(shared.unreadable) item\(shared.unreadable == 1 ? "" : "s").") }
        if shared.skipped > 0 {
            out.append("ClipLink keeps \(Wire.historyCap) items, so \(shared.skipped) more \(shared.skipped == 1 ? "was" : "were") left out.")
        }
        return out
    }

    private func withProblems(_ message: String) -> String {
        ([message] + problems).joined(separator: " ")
    }

    /// Longer on screen when there's more to read.
    private var readingTime: TimeInterval { problems.isEmpty ? 0 : 3 }

    /// Runs `then` once the items are stored, or right away if nothing is
    /// being stored. Bounded: once none has been stored for `maxStoreWait`,
    /// a file that isn't stored by then won't be.
    private func whenStored(_ then: @escaping () -> Void) {
        guard storing else { return then() }
        afterStored = then
        giveUpWhenStuck()
    }

    private func giveUpWhenStuck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let then = self.afterStored else { return }
            guard Date().timeIntervalSince(self.lastStoredAt) >= ShareModel.maxStoreWait else { return self.giveUpWhenStuck() }
            self.afterStored = nil
            then()
        }
    }

    /// Keeps the engine up while paired devices connect (each gets the new
    /// items via live send or its history_batch), then wraps up.
    private func poll() {
        guard let engine, !stopping, !handoff else { return }
        engine.currentSnapshot { [weak self] snapshot in
            guard let self, !self.stopping else { return }
            if case .failed = self.phase { return }
            self.connected = snapshot.connectedCount
            self.paired = snapshot.devices.filter(\.trusted).count
            let elapsed = Date().timeIntervalSince(self.startedAt)
            let everyone = self.paired > 0 && self.connected >= self.paired
            // Never "sent" before the engine has actually stored the items.
            if !self.storing, (elapsed >= 2 && everyone) || elapsed >= 12 {
                self.phase = .sent(self.summary())
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4 + self.readingTime) { [weak self] in self?.stop() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.poll() }
            }
        }
    }

    private func summary() -> String {
        let many = storedCount > 1
        let what = many ? " \(storedCount) items" : ""
        let them = many ? "them" : "it"
        let message: String
        if paired == 0 {
            message = "Saved\(what). Pair a device in ClipLink to sync \(them)."
        } else if connected == 0 {
            message = "Saved\(what) — \(many ? "they sync" : "it syncs") the next time ClipLink reaches your devices."
        } else if connected < paired {
            message = "Sent\(what) to \(connected) of \(paired) devices. The rest get \(them) next time."
        } else {
            message = "Sent\(what) to \(connected) device\(connected == 1 ? "" : "s")."
        }
        return withProblems(message)
    }

    /// The sheet's button: Cancel while the items are still being prepared,
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
        loading?.cancel()
        guard let engine else { return finish(cancelled: true) }
        engine.finish(grace: 0) { [weak self] in self?.finish(cancelled: true) }
    }

    /// Waits for the items to be stored and for in-flight file streams to
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
                    Label(model.title, systemImage: model.icon)
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
                }
                // A picture's file name, or what else came with it.
                if !model.preview.isEmpty {
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
