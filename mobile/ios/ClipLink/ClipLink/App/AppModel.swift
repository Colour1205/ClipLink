import Combine
import ImageIO
import os
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

/// The one object the UI talks to: owns the sync engine, the clipboard and
/// the settings, turns engine events into UI state, and runs the app
/// lifecycle (foreground node, background refresh).
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settings = AppSettings()
    let clipboard = ClipboardService()
    private(set) var engine: SyncEngine?

    @Published private(set) var snapshot = EngineSnapshot()
    @Published var toast: Toast?
    /// The pasteboard changed since we last looked ("New item" hint).
    @Published private(set) var hasNewClipboardItem = false
    @Published private(set) var startupError: String?
    @Published private(set) var identityIsHardwareBacked = false
    /// A request opened from its notification after the connection it came on
    /// is gone: Trust still saves the device, and it connects when it next can.
    @Published private(set) var offlineRequest: PairingRequest?

    /// True while the pairing sheet is on screen - that IS pairing mode.
    @Published var pairingPresented = false {
        didSet {
            guard pairingPresented != oldValue else { return }
            engine?.setPairingOpen(pairingPresented)
            // The moment someone expects a request is the moment to ask
            // whether they may be told about one while ClipLink is closed.
            if pairingPresented {
                #if DEBUG
                if !usingFixtures { Notifier.requestPairingAuthorizationIfNeeded() }
                #else
                Notifier.requestPairingAuthorizationIfNeeded()
                #endif
            }
            if !pairingPresented {
                pairStatus = nil
                pairInProgress = false
            }
        }
    }
    @Published private(set) var pairStatus: String?
    @Published private(set) var pairInProgress = false
    @Published private(set) var passcodeBusy = false

    /// The scene is in the foreground (between becameActive and
    /// enteredBackground).
    private(set) var isActive = false
    /// The UIKit background task of the latest trip to the background.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var changeCountAtBackground: Int?
    /// A received item that arrived while we were in the background: it lands
    /// on the clipboard when the app opens, unless the user copied something
    /// else in the meantime.
    private var heldForForeground: (ClipboardEntry, URL?)?
    private var lastSentImage: (ImageFingerprint, Date)?
    /// Requests the prompt has already been raised (or notified) for.
    private var knownRequestIds: Set<String> = []
    /// The OS-level modal for a pairing request - over whatever is on screen.
    private let promptPresenter = PairingPromptPresenter()
    #if DEBUG
    /// `-ClipLinkDebugFixtures` shows a made-up snapshot instead of the
    /// engine's (screenshots, UI work): see DebugFixtures.
    private var usingFixtures = false
    #endif
    private var pasteboardObserver: NSObjectProtocol?
    private var protectedDataObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "io.uaena.ClipLink", category: "ClipLinkNet")

    /// Images bigger than this as PNG go as a file instead: every
    /// history_batch re-sends inline images.
    static let maxInlineImageBytes = 24 * 1024 * 1024

    private init() {
        startEngine()
        promptPresenter.onTrust = { [weak self] in self?.acceptRequest($0) }
        promptPresenter.onIgnore = { [weak self] in self?.ignoreRequest($0) }
        promptPresenter.nameFor = { [weak self] in self?.name(for: $0) ?? DeviceLabel.short($0) }
        #if DEBUG
        if UserDefaults.standard.string(forKey: "ClipLinkDebugFixtures") != nil {
            usingFixtures = true
            snapshot = DebugFixtures.snapshot(UserDefaults.standard.string(forKey: "ClipLinkDebugFixtures") ?? "")
        }
        #endif
        clipboard.onOwnWriteSettled = { [weak self] in self?.refreshClipboardHint() }
        pasteboardObserver = NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshClipboardHint() }
        }
        // A launch before the first unlock finds the Keychain locked: start
        // as soon as it opens rather than only on the next launch.
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.retryStartup() }
        }
    }

    /// Loads the identity and builds the engine; on failure `startupError`
    /// says why and the UI shows it instead of the tabs.
    private func startEngine() {
        guard engine == nil else { return }
        do {
            let identity = try KeychainIdentity.loadOrCreate()
            identityIsHardwareBacked = identity.isHardwareBacked
            var config = EngineConfig(storageDirectory: Self.storageDirectory())
            let logger = logger
            config.logSink = { message in logger.info("\(message, privacy: .public)") }
            let engine = SyncEngine(config: config, identity: identity, secrets: KeychainSecretStore())
            self.engine = engine
            engine.delegate = self
            // Queued ahead of enterForeground, so the first beacon and
            // handshake already carry it.
            engine.setSystemDeviceName(Self.systemDeviceName)
            snapshot.ownDeviceId = engine.ownId
            startupError = nil
            #if DEBUG
            // Test hook (Debug builds only): `-ClipLinkDebugPasscode <code>` as a
            // launch argument sets the shared passcode, for scripted runs.
            if let code = UserDefaults.standard.string(forKey: "ClipLinkDebugPasscode"), !code.isEmpty {
                engine.setPassphrase(code) { _ in }
            }
            #endif
        } catch {
            startupError = "\(error)"
        }
    }

    /// Tries again after a failed start - the Keychain is unavailable before
    /// the first unlock, and the process (this singleton) outlives that. Runs
    /// on its own when the app becomes active or protected data unlocks, and
    /// from the startup error screen.
    func retryStartup() {
        guard engine == nil, startupError != nil else { return }
        startEngine()
        // Already in the foreground: bring the new node up like becameActive.
        guard let engine, isActive else { return }
        engine.enterForeground()
        if pairingPresented { engine.setPairingOpen(true) }
    }

    /// The App Group container shared with the Share extension (migrating
    /// anything stored before the group existed).
    static func storageDirectory() -> URL {
        SharedContainer.storageDirectory(migrateLegacy: true)
    }

    var ownDeviceId: String { snapshot.ownDeviceId }

    func name(for deviceId: String) -> String { snapshot.name(for: deviceId) }

    /// The OS default device name - read here, on the main actor (it's
    /// UIKit), and handed to the engine, which stores it for the Share
    /// extension and background rounds. Without Apple's user-assigned-name
    /// entitlement, iOS 16+ only says "iPhone" or "iPad": hence Me › Device
    /// Name.
    private static var systemDeviceName: String { UIDevice.current.name }

    // MARK: - Lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active: becameActive()
        case .background: enteredBackground()
        default: break
        }
    }

    private func becameActive() {
        guard !isActive else { return }
        if startupError != nil { retryStartup() }
        isActive = true
        refreshPrompt()
        endBackgroundTask(backgroundTask)
        // The user may have renamed the device in Settings meanwhile.
        engine?.setSystemDeviceName(Self.systemDeviceName)
        engine?.enterForeground()
        // Pairing mode was switched off for the background: back on if the
        // pairing sheet is still up.
        if pairingPresented { engine?.setPairingOpen(true) }

        #if DEBUG
        // Test hook: `-ClipLinkDebugOpenPairing` opens the pairing sheet at launch.
        if UserDefaults.standard.bool(forKey: "ClipLinkDebugOpenPairing"), !pairingPresented {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.pairingPresented = true }
        }
        #endif
        clipboard.discardStaleCounts()
        if let (entry, url) = heldForForeground {
            heldForForeground = nil
            if settings.autoApply, clipboard.changeCount == changeCountAtBackground {
                autoApply(entry, fileURL: url)
            }
        }
        changeCountAtBackground = nil
        refreshClipboardHint()

        if clipboard.neverLooked {
            // First launch: whatever is on the clipboard predates ClipLink,
            // and on iOS 16+ reading it would greet the user with "Allow
            // Paste?" before they've seen the app. Paste still sends it.
            clipboard.markSeen()
            refreshClipboardHint()
        } else if settings.autoCapture, clipboard.hasUnseenChange {
            // The one moment iOS lets an app pick up the clipboard on its own
            // (on iOS 16+ this asks first, unless paste is allowed in Settings).
            Task { await captureAndSend(quiet: true) }
        }
    }

    private func enteredBackground() {
        guard isActive else { return }
        isActive = false
        refreshPrompt()
        // A request still waiting as the user leaves can't be answered here
        // any more - its connection closes with the node. Carry it into a
        // notification, whose Trust button works without the connection.
        for request in snapshot.pairingRequests where !request.initiatedByUs && !answered.contains(request.id) {
            Notifier.notifyPairingRequest(request, name: name(for: request.deviceId))
        }
        changeCountAtBackground = clipboard.changeCount
        // Pairing mode never outlives the visible screen: nobody can accept a
        // request from the background, and the grace period below keeps the
        // node reachable for a while.
        engine?.setPairingOpen(false)
        // Time to finish in-flight transfers and close links cleanly (peers
        // then drop us at once instead of after their heartbeat timeout).
        // Each task is ended exactly once, by its own id: a completion from
        // an earlier trip to the background must not end this one.
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "ClipLink sync") { [weak self] in
            guard let self, self.backgroundTask == task else { return }
            self.engine?.enterBackground(grace: 0)
            self.endBackgroundTask(task)
        }
        backgroundTask = task
        engine?.enterBackground(grace: 25) { [weak self] in self?.endBackgroundTask(task) }
        let pendingFiles = snapshot.items.contains { $0.kind == .file && !$0.fileAvailable }
        BackgroundSync.schedule(enabled: settings.backgroundRefresh, hasPendingFiles: pendingFiles)
    }

    /// Ends `task` if it is still the current one (no-op otherwise).
    private func endBackgroundTask(_ task: UIBackgroundTaskIdentifier) {
        guard task != .invalid, backgroundTask == task else { return }
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }

    /// A Background App Refresh round ended.
    func backgroundSyncFinished(received: [ClipboardEntry]) {
        guard !received.isEmpty, !isActive, settings.notifyBackgroundItems else { return }
        Notifier.notify(received) { [weak self] in self?.name(for: $0) ?? DeviceLabel.short($0) }
    }

    func setBackgroundRefresh(_ enabled: Bool) {
        settings.backgroundRefresh = enabled
        BackgroundSync.schedule(enabled: enabled, hasPendingFiles: false)
    }

    func setNotifyBackgroundItems(_ enabled: Bool) {
        guard enabled else {
            settings.notifyBackgroundItems = false
            return
        }
        Notifier.requestAuthorization { [weak self] granted in
            self?.settings.notifyBackgroundItems = granted
            if !granted { self?.showToast("Notifications are off for ClipLink in Settings.") }
        }
    }

    // MARK: - Clipboard → peers

    func refreshClipboardHint() {
        hasNewClipboardItem = settings.noticeNewCopies && clipboard.hasUnseenChange
    }

    func dismissClipboardHint() {
        clipboard.markSeen()
        refreshClipboardHint()
    }

    /// Reads this device's clipboard and syncs it. `quiet` is the automatic
    /// on-open capture: silence instead of "nothing to sync".
    func captureAndSend(quiet: Bool) async {
        guard engine != nil else { return }
        if clipboard.holdsOwnWrite {
            clipboard.markSeen()
            refreshClipboardHint()
            if !quiet { showToast("Already synced.") }
            return
        }
        let capture = await clipboard.capture()
        refreshClipboardHint()
        guard let capture else {
            if !quiet { showToast(clipboard.lastCaptureDeclined ? "Paste wasn't allowed." : "Nothing on the clipboard to sync.") }
            return
        }
        send(capture, quiet: quiet)
    }

    /// From the system Paste button (iOS 16+), drag & drop, or share-in.
    func sendProviders(_ providers: [NSItemProvider]) async {
        guard let capture = await clipboard.capture(from: providers) else {
            showToast("Nothing ClipLink can sync there.")
            return
        }
        clipboard.markSeen()
        refreshClipboardHint()
        send(capture, quiet: false)
    }

    func send(_ capture: Capture, quiet: Bool) {
        guard let engine else { return }
        switch capture {
        case .text(let text):
            let hash = ContentHash.sha256Hex(Data(text.utf8))
            guard hash != clipboard.lastKnownHash || !quiet else { return }
            clipboard.noteSent(hash: hash)
            engine.sendText(text) { [weak self] in self?.report($0) }
        case .image(let png):
            Task {
                // Hashing and fingerprinting read (and partly decode) the
                // whole PNG: off the main actor.
                let (hash, fingerprint) = await Task.detached(priority: .userInitiated) {
                    (ContentHash.sha256Hex(png), ImageFingerprint(imageData: png))
                }.value
                guard hash != clipboard.lastKnownHash || !quiet else { return }
                clipboard.noteSent(hash: hash)
                if let fingerprint { lastSentImage = (fingerprint, Date()) }
                guard png.count > Self.maxInlineImageBytes else {
                    engine.sendImage(png: png) { [weak self] in self?.report($0) }
                    return
                }
                let url = ItemLoader.tempURL(named: "Image.png")
                let written = await Task.detached(priority: .userInitiated) { (try? png.write(to: url)) != nil }.value
                guard written else { return showToast("Couldn't store that image.") }
                engine.sendFile(at: url, name: "Image.png", moveIntoStore: true) { [weak self] in self?.report($0) }
            }
        case .file(let url, let name):
            engine.sendFile(at: url, name: name, moveIntoStore: true) { [weak self] in self?.report($0) }
        }
    }

    /// A file from the document picker. Copied right here: the picker's own
    /// (local, private) copy is removed as soon as this returns.
    func sendFile(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let temp = ClipboardService.tempURL(named: name)
        do {
            try FileManager.default.copyItem(at: url, to: temp)
        } catch {
            showToast("Couldn't read that file.")
            return
        }
        sendCopiedFile(temp, name: name)
    }

    /// "Open in ClipLink" / Copy to ClipLink from Files or another app. The
    /// URL can be a document opened in place from a file provider (maybe not
    /// even downloaded yet), so it is read under file coordination, off the
    /// main thread. A file shared in stays a file - an image file too - as
    /// with the Share extension and on every other platform.
    func openFile(at url: URL) {
        let name = url.lastPathComponent
        Task {
            let temp = await Task.detached(priority: .userInitiated) { Self.coordinatedCopy(of: url) }.value
            guard let temp else { return showToast("Couldn't read that file.") }
            send(.file(temp, name: name), quiet: false)
        }
    }

    nonisolated private static func coordinatedCopy(of url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let temp = ItemLoader.tempURL(named: url.lastPathComponent)
        var copied = false
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readURL in
            copied = (try? FileManager.default.copyItem(at: readURL, to: temp)) != nil
        }
        // What iOS copied into Documents/Inbox for us is ours to delete: with
        // file sharing on, those copies would pile up under Files › ClipLink.
        let inbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true).resolvingSymlinksInPath().path + "/"
        if url.resolvingSymlinksInPath().path.hasPrefix(inbox) {
            try? FileManager.default.removeItem(at: url)
        }
        return copied ? temp : nil
    }

    /// Images travel inline as PNG, like every other platform's captures,
    /// unless that would mean scaling them down or a huge PNG: those, and
    /// every other file, go as the file itself.
    private func sendCopiedFile(_ temp: URL, name: String) {
        guard let type = UTType(filenameExtension: temp.pathExtension), type.conforms(to: .image) else {
            return send(.file(temp, name: name), quiet: false)
        }
        Task {
            let limit = Self.maxInlineImageBytes
            let png = await Task.detached(priority: .userInitiated) { ItemLoader.inlinePNG(forImageFileAt: temp, maxBytes: limit) }.value
            guard let png else { return send(.file(temp, name: name), quiet: false) }
            try? FileManager.default.removeItem(at: temp.deletingLastPathComponent())
            send(.image(png: png), quiet: false)
        }
    }

    /// Photos picked from the library (PHPicker hands over the original bytes,
    /// often a 12-48 MP HEIC): decoded and re-encoded off the main thread.
    func sendImageData(_ data: Data) {
        Task {
            let png = await Task.detached(priority: .userInitiated) { ItemLoader.pngData(fromImageData: data) }.value
            guard let png else { return showToast("Couldn't read that image.") }
            send(.image(png: png), quiet: false)
        }
    }

    private func report(_ result: SendResult) {
        switch result {
        case .failed(let why):
            showToast(why)
        case .sent:
            // No toast: the item is at the top of Synced the moment it's
            // sent, and the connection pill says who is reachable.
            break
        }
    }

    // MARK: - Peers → clipboard

    fileprivate func received(_ entry: ClipboardEntry, fileURL: URL?) {
        if entry.type == Wire.EntryType.image, let (sent, when) = lastSentImage, Date().timeIntervalSince(when) < 30,
           let data = Data(base64Encoded: entry.content), let fingerprint = ImageFingerprint(imageData: data),
           fingerprint.looksLike(sent) {
            // Windows re-encoding our own image and sending it back.
            return
        }
        guard settings.autoApply else { return }
        guard isActive else {
            heldForForeground = (entry, fileURL)
            return
        }
        autoApply(entry, fileURL: fileURL)
    }

    /// "Copy received items automatically", minus big files (see
    /// maxAutoApplyFileBytes): those just stay in Synced. Silent: the item
    /// has already appeared in the list, and a toast on every arrival is
    /// noise.
    private func autoApply(_ entry: ClipboardEntry, fileURL: URL?) {
        if entry.type == Wire.EntryType.file, let payload = FilePayload.parse(entry.content),
           payload.fileSize > ClipboardService.maxAutoApplyFileBytes {
            return
        }
        if clipboard.apply(entry, fileURL: fileURL) {
            refreshClipboardHint()
        }
    }

    // MARK: - Items

    func copy(_ item: SyncedItem) {
        let url = item.filePayload.flatMap { engine?.blobURL(forHash: $0.fileHash) }
        if item.kind == .file, url == nil {
            showToast("That file hasn't finished transferring yet.")
            return
        }
        if let size = item.filePayload?.fileSize, size > ClipboardService.maxPasteboardFileBytes {
            showToast("That file is too big for the clipboard — use Share or Save instead.")
            return
        }
        if clipboard.apply(item.entry, fileURL: url) {
            refreshClipboardHint()
            showToast("Copied.")
        } else {
            showToast("Couldn't copy that item.")
        }
    }

    func delete(_ item: SyncedItem) {
        engine?.deleteItem(id: item.id)
    }

    func clearHistory() {
        // No toast: the list visibly empties, after a confirmation.
        engine?.clearHistory()
    }

    /// A shareable file for an item: the file itself under its real name, or
    /// an image written out as a PNG. Nil for text, or while transferring.
    func shareURL(for item: SyncedItem) -> URL? {
        switch item.kind {
        case .file:
            guard let payload = item.filePayload else { return nil }
            return engine?.exportURL(for: payload)
        case .image:
            guard let data = imageData(for: item) else { return nil }
            let ext = (CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType) as String?)
                .flatMap { UTType($0)?.preferredFilenameExtension } ?? "png"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ClipLink Image \(item.id.hashValue & 0xFFFF).\(ext)")
            try? data.write(to: url, options: .atomic)
            return url
        default:
            return nil
        }
    }

    func imageData(for item: SyncedItem) -> Data? {
        switch item.kind {
        case .image:
            return Data(base64Encoded: item.entry.content)
        case .file:
            guard let payload = item.filePayload, Self.isImageFileName(payload.fileName),
                  let url = engine?.blobURL(forHash: payload.fileHash) else { return nil }
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        default:
            return nil
        }
    }

    static func isImageFileName(_ name: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "tif", "tiff"].contains((name as NSString).pathExtension.lowercased())
    }

    // MARK: - Devices & pairing

    func trust(_ device: DeviceRow) {
        #if DEBUG
        if fixture({ DebugFixtures.trust(device.deviceId, in: &$0) }) { return }
        #endif
        engine?.trustDevice(device.deviceId)
    }

    func untrust(_ device: DeviceRow) {
        #if DEBUG
        if fixture({ DebugFixtures.untrust(device.deviceId, in: &$0) }) { return }
        #endif
        engine?.untrustDevice(device.deviceId)
    }

    /// Blocks a device: its pairing requests never come through, it is never
    /// auto-trusted (not even by a matching passcode) and ClipLink never
    /// connects to it. Local only; undone with `unblock`.
    func block(_ device: DeviceRow) {
        #if DEBUG
        if fixture({ DebugFixtures.block(device.deviceId, in: &$0) }) { return }
        #endif
        engine?.blockDevice(device.deviceId)
    }

    func unblock(_ device: DeviceRow) {
        #if DEBUG
        if fixture({ DebugFixtures.unblock(device.deviceId, in: &$0) }) { return }
        #endif
        engine?.unblockDevice(device.deviceId)
    }

    #if DEBUG
    /// Applies `change` to the fake snapshot when fixtures are on; false (and
    /// nothing done) otherwise, so the caller goes on to the real engine.
    private func fixture(_ change: (inout EngineSnapshot) -> Void) -> Bool {
        guard usingFixtures else { return false }
        change(&snapshot)
        return true
    }
    #endif

    func rename(_ deviceId: String, to name: String) { engine?.setNickname(name, for: deviceId) }

    func refreshNetwork() { engine?.refreshNetwork() }

    func pair(with raw: String) {
        guard let engine, !pairInProgress else { return }
        pairInProgress = true
        pairStatus = "Connecting…"
        engine.pair(with: raw) { [weak self] outcome in
            guard let self, self.pairingPresented else { return }
            self.pairInProgress = false
            self.pairStatus = outcome.message
        }
    }

    // MARK: - Pairing requests

    /// Trust. A live request is accepted - its connection goes to work. One
    /// whose connection is long gone (a notification opened much later)
    /// still saves the device; it connects as soon as it can be reached.
    func acceptRequest(_ request: PairingRequest) {
        Haptics.success(settings.haptics)
        let live = snapshot.pairingRequests.contains { $0.id == request.id }
        offlineRequest = nil
        answered.insert(request.id)
        Notifier.removePairingNotification(deviceId: request.deviceId)
        #if DEBUG
        if fixture({ DebugFixtures.trust(request.deviceId, in: &$0); DebugFixtures.answer(request.deviceId, in: &$0) }) { return refreshPrompt() }
        #endif
        engine?.trustDevice(request.deviceId, address: request.address)
        if !live {
            showToast("Trusted \(request.name ?? name(for: request.deviceId)). It connects as soon as it's reachable.")
        }
        refreshPrompt()
    }

    /// Ignore - not a block: the device may ask again later.
    func ignoreRequest(_ request: PairingRequest) {
        offlineRequest = nil
        answered.insert(request.id)
        Notifier.removePairingNotification(deviceId: request.deviceId)
        #if DEBUG
        if fixture({ DebugFixtures.answer(request.deviceId, in: &$0) }) { return refreshPrompt() }
        #endif
        engine?.ignorePairing(deviceId: request.deviceId)
        pairStatus = nil
        refreshPrompt()
    }

    /// Requests the user has answered; kept until the engine stops listing
    /// them so a snapshot published in between can't raise the prompt again.
    private var answered: Set<String> = []

    /// Called with every snapshot: raise a notification for a request that
    /// arrived while ClipLink is closed, and keep the on-screen prompt in
    /// step with the engine's list.
    private func requestsChanged(_ requests: [PairingRequest]) {
        let ids = Set(requests.map(\.id))
        answered.formIntersection(ids)
        for request in requests where !knownRequestIds.contains(request.id) && !request.initiatedByUs {
            if isActive {
                Haptics.tap(settings.haptics)
            } else {
                // Only possible during a background round: nothing on screen to
                // ask in, so ask through a notification.
                Notifier.notifyPairingRequest(request, name: name(for: request.deviceId))
            }
        }
        // A request that went away while the app is open was answered or
        // withdrawn: its notification is stale. While the app is NOT open it
        // just went away with the background round - the notification must
        // stay, its Trust button works without the connection.
        if isActive {
            for gone in knownRequestIds.subtracting(ids) { Notifier.removePairingNotification(deviceId: gone) }
        }
        knownRequestIds = ids
        refreshPrompt()
    }

    /// Shows (or updates, or dismisses) the OS-level prompt for the oldest
    /// request. Only while the app is open: otherwise a notification asks.
    private func refreshPrompt() {
        var shown = snapshot.pairingRequests.filter { !answered.contains($0.id) }
        if let offline = offlineRequest, !shown.contains(where: { $0.id == offline.id }) { shown.append(offline) }
        promptPresenter.update(shown, active: isActive)
    }

    /// A notification's button, or a tap on the notification itself. Runs
    /// even when the app was launched just for this.
    func handleNotificationResponse(actionIdentifier: String, userInfo: [AnyHashable: Any]) async {
        guard let id = userInfo[Notifier.requestIdKey] as? String else { return }
        let address = (userInfo[Notifier.requestAddressKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = (userInfo[Notifier.requestNameKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch actionIdentifier {
        case Notifier.trustAction:
            // Possibly the only thing this launch does: let the engine's queue
            // finish writing the trust before the process may be suspended.
            engine?.trustDevice(id, address: address)
            await withCheckedContinuation { continuation in
                guard let engine else { return continuation.resume() }
                engine.currentSnapshot { _ in continuation.resume() }
            }
        case Notifier.ignoreAction:
            engine?.ignorePairing(deviceId: id)
        case UNNotificationDefaultActionIdentifier:
            guard !snapshot.pairingRequests.contains(where: { $0.id == id }) else { return refreshPrompt() }
            offlineRequest = PairingRequest(deviceId: id, address: address, name: name)
            refreshPrompt()
        default:
            break
        }
    }

    func copyDeviceID() {
        clipboard.copyText(ownDeviceId)
        showToast("Device ID copied.")
    }

    func copyPairingInfo() {
        clipboard.copyText(snapshot.pairingPayload)
        showToast("Pairing info copied.")
    }

    // MARK: - Passcode & network

    func setPassphrase(_ passphrase: String, completion: @escaping (Bool) -> Void) {
        guard let engine else { return }
        guard !passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast("Enter a passcode first.")
            completion(false)
            return
        }
        passcodeBusy = true
        engine.setPassphrase(passphrase) { [weak self] ok in
            self?.passcodeBusy = false
            // Only a failure needs saying: on success the screen itself
            // changes to "Passcode is set".
            if !ok { self?.showToast("Couldn't set the passcode.") }
            completion(ok)
        }
    }

    func clearPassphrase() {
        engine?.clearPassphrase()
    }

    /// Me › Device Name. Empty goes back to the OS default.
    func setDeviceName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        engine?.setDeviceName(trimmed)
    }

    func saveTailscaleIP(_ ip: String) {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, NetworkInterfaces.parse(trimmed) == nil {
            showToast("Enter an IPv4 address like 100.101.102.103.")
            return
        }
        engine?.setTailscaleIP(trimmed)
    }

    /// iOS can see the Tailscale VPN interface, unlike the other platforms.
    var detectedTailscaleIP: String? { NetworkInterfaces.tailscale() }

    /// Identity, signing and storage all working (HarmonyOS' Diagnostics).
    func runSelfTest() -> String {
        guard let engine else { return "Self-test failed: \(startupError ?? "engine not running")" }
        do {
            let identity = try KeychainIdentity.loadOrCreate()
            guard identity.publicKeyBase64 == engine.ownId else { return "Self-test failed: identity changed." }
            let entry = try EntrySigning.sign(content: "self-test", type: Wire.EntryType.text, identity: identity)
            guard EntrySigning.verified(entry) != nil else { return "Self-test failed: signature didn't verify." }
            return "Self-test passed — identity, signing, and storage all working."
        } catch {
            return "Self-test failed: \(error)"
        }
    }

    // MARK: - Toasts

    func showToast(_ message: String) {
        toast = Toast(message: message)
    }
}

extension AppModel: SyncEngineDelegate {
    nonisolated func syncEngine(_ engine: SyncEngine, didUpdate snapshot: EngineSnapshot) {
        MainActor.assumeIsolated {
            #if DEBUG
            if self.usingFixtures { return }
            #endif
            self.snapshot = snapshot
            self.refreshClipboardHint()
            self.requestsChanged(snapshot.pairingRequests)
        }
    }

    nonisolated func syncEngine(_ engine: SyncEngine, didReceive entry: ClipboardEntry, fileURL: URL?) {
        MainActor.assumeIsolated { self.received(entry, fileURL: fileURL) }
    }

    nonisolated func syncEngine(_ engine: SyncEngine, notice: String) {
        MainActor.assumeIsolated {
            // With the pairing sheet up, a notice is how pairing ended
            // ("Paired.", a cancelled request, a passcode auto-pair): show it
            // there too, instead of the dial's now-stale status.
            if self.pairingPresented {
                self.pairInProgress = false
                self.pairStatus = notice
            }
            self.showToast(notice)
        }
    }
}
