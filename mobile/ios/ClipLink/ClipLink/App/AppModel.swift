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

    /// Assigned only when it changed. The Synced tab, its cards, the dock and
    /// the toast window watch the small stores below instead (see MeState.swift).
    @Published private(set) var snapshot = EngineSnapshot() {
        didSet { updateStores() }
    }
    /// What the Me tab watches instead of `snapshot` (see MeState.swift).
    let me = MeStore()
    let logCount = LogCountStore()
    /// What the Synced tab watches, and the transfers its file cards show.
    let synced = SyncedStore()
    let transfers = TransfersStore()
    /// What the Devices tab watches.
    let devices = DevicesStore()
    let hint = ClipboardHintStore()
    let toasts = ToastStore()
    var toast: Toast? {
        get { toasts.toast }
        set { toasts.toast = newValue }
    }
    /// The pasteboard changed since we last looked ("New item" hint).
    var hasNewClipboardItem: Bool { hint.visible }
    @Published private(set) var startupError: String?
    @Published private(set) var identityIsHardwareBacked = false {
        didSet { me.setHardwareBacked(identityIsHardwareBacked) }
    }
    /// A request opened from its notification after the connection it came on
    /// is gone: Trust still saves the device, and it connects when it next can.
    @Published private(set) var offlineRequest: PairingRequest?

    /// True while the pairing sheet is on screen.
    @Published var pairingPresented = false {
        didSet {
            guard pairingPresented != oldValue else { return }
            // Somebody expects a request now: nothing stays held back, and it
            // is the moment to ask whether they may be told about one while
            // ClipLink is closed.
            if pairingPresented {
                engine?.liftRequestQuiet()
                // One round of discovery, as if pulled to refresh: without the
                // multicast entitlement iOS hears no broadcast beacons, so a
                // nearby device never paired before only shows under Devices ›
                // Nearby once a sweep has read it.
                engine?.refreshNetwork()
                #if DEBUG
                if !usingFixtures { Notifier.requestPairingAuthorizationIfNeeded() }
                #else
                Notifier.requestPairingAuthorizationIfNeeded()
                #endif
            }
            if !pairingPresented {
                engine?.cancelPairingSearch()
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
    /// Reads of the clipboard in flight. A received item waits for them
    /// (`applyAfterCapture`, the latest wins): written meanwhile it would
    /// replace the copy being read, which then never goes out.
    private var capturesInFlight = 0
    private var applyAfterCapture: (ClipboardEntry, URL?)?
    /// How often the user changed the clipboard themselves (copied in another
    /// app, or tapped Copy here), for the engine: a file that lands later must
    /// not replace what they chose meanwhile (see SyncEngine.clipboardGeneration).
    private var userClipboardGeneration = 0
    /// Items received so far: a picture still being checked off the main
    /// thread gives way to one that came after it (see `received`).
    private var receivedCount = 0
    /// Writes to the clipboard asked for so far: a picture still being decoded
    /// gives way to a later one (see `applyPicture`).
    private var clipboardRequests = 0
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
            updateStores()
        }
        #endif
        clipboard.onOwnWriteSettled = { [weak self] in self?.refreshClipboardHint() }
        pasteboardObserver = NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Not ClipLink's own write: the user copied something (split
                // view, or Universal Clipboard while ClipLink is open).
                if !self.clipboard.holdsOwnWrite { self.noteUserClipboardChange() }
                self.refreshClipboardHint()
            }
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
    }

    /// The App Group container shared with the Share extension (migrating
    /// anything stored before the group existed).
    static func storageDirectory() -> URL {
        SharedContainer.storageDirectory(migrateLegacy: true)
    }

    /// Each store republishes only when its own part changed.
    private func updateStores() {
        me.update(from: snapshot)
        logCount.update(snapshot.log.count)
        synced.update(from: snapshot)
        transfers.update(snapshot.transfers)
        devices.update(from: snapshot)
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
        // Back with the pairing sheet still up counts as opening it again.
        if pairingPresented { engine?.liftRequestQuiet() }

        #if DEBUG
        // Test hook: `-ClipLinkDebugOpenPairing` opens the pairing sheet at launch.
        if UserDefaults.standard.bool(forKey: "ClipLinkDebugOpenPairing"), !pairingPresented {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.pairingPresented = true }
        }
        #endif
        clipboard.discardStaleCounts()
        // A received item that arrived while we were away lands now, unless
        // the user copied something else in the meantime.
        var held: (ClipboardEntry, URL?)?
        if let (entry, url) = heldForForeground {
            heldForForeground = nil
            if settings.autoApply, clipboard.changeCount == changeCountAtBackground { held = (entry, url) }
        }
        if let before = changeCountAtBackground, before != clipboard.changeCount { noteUserClipboardChange() }
        changeCountAtBackground = nil
        refreshClipboardHint()

        if clipboard.neverLooked {
            // First launch: whatever is on the clipboard predates ClipLink,
            // and on iOS 16+ reading it would greet the user with "Allow
            // Paste?" before they've seen the app. Paste still sends it.
            clipboard.markSeen()
            refreshClipboardHint()
            if let (entry, url) = held { autoApply(entry, fileURL: url) }
        } else if settings.autoCapture, clipboard.hasUnseenChange {
            // The one moment iOS lets an app pick up the clipboard on its own
            // (on iOS 16+ this asks first, unless paste is allowed in Settings).
            // A copy made before the user left, never sent, goes out before
            // the held item replaces it.
            if let held { applyAfterCapture = held }
            captureFirst()
        } else if let (entry, url) = held {
            autoApply(entry, fileURL: url)
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
        // Stop looking for a scanned code's device: nobody is here to answer
        // it, and the grace period below keeps the node up for a while.
        engine?.cancelPairingSearch()
        // Time to finish in-flight transfers and close links cleanly (peers
        // then drop us at once instead of after their heartbeat timeout).
        // Each task is ended exactly once, by its own id: a completion from
        // an earlier trip to the background must not end this one.
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "ClipLink sync") { [weak self] in
            guard let self, self.backgroundTask == task else { return }
            guard let engine = self.engine else { return self.endBackgroundTask(task) }
            // Ended once the engine's queue is through what it was doing: a
            // store write holds a lock on a file in the shared container, and
            // iOS kills an app that is suspended holding one (0xdead10cc).
            // The backstop keeps a busy queue within the expiry window.
            engine.enterBackground(grace: 0) { [weak self] in self?.endBackgroundTask(task) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.endBackgroundTask(task) }
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
        // What the clipboard already holds is no news (see `received`).
        let news = received.filter { !holdsAlready($0) }
        guard !news.isEmpty, !isActive, settings.notifyBackgroundItems else { return }
        Notifier.notify(news) { [weak self] in self?.name(for: $0) ?? DeviceLabel.short($0) }
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
        hint.set(settings.noticeNewCopies && clipboard.hasUnseenChange)
    }

    func dismissClipboardHint() {
        clipboard.markSeen()
        refreshClipboardHint()
    }

    /// The prints of everything in the history, and of its newest entry (every
    /// one, if several share its time), from the engine itself: the snapshot
    /// can be a moment behind. Items the Share extension stored come in with
    /// the reload as the app comes back, just as the on-open capture runs, and
    /// an item sent a moment ago is in the history before it is in the list.
    private func historyPrints() async -> (all: Set<String>, newest: Set<String>) {
        guard let engine else { return (all: [], newest: []) }
        return await withCheckedContinuation { (continuation: CheckedContinuation<(all: Set<String>, newest: Set<String>), Never>) in
            engine.contentPrints(newest: 1) { all, newest in continuation.resume(returning: (all: all, newest: newest)) }
        }
    }

    /// Step 1 of sync-dedupe-spec 1.3, before reading: the clipboard still
    /// holds what ClipLink put there, so there is nothing to read (and no paste
    /// prompt) - in manual mode only while that is still in the history, since
    /// a Paste after a delete is a deliberate re-send.
    private func holdsOwnSyncedWrite(_ mode: CaptureMode) async -> Bool {
        guard clipboard.holdsOwnWrite else { return false }
        var historyKeys: Set<String> = []
        if mode == .manual { historyKeys = await historyPrints().all }
        return CaptureCheck.ownWrite(mode: mode, lastWrite: clipboard.lastWrite, historyKeys: historyKeys) == .already
    }

    /// Reads this device's clipboard and syncs it. `quiet` is the automatic
    /// on-open capture: silence instead of "nothing to sync".
    func captureAndSend(quiet: Bool) async {
        guard engine != nil else { return }
        let mode: CaptureMode = quiet ? .auto : .manual
        beginCapture()
        defer { endCapture() }
        if await holdsOwnSyncedWrite(mode) {
            clipboard.markSeen()
            refreshClipboardHint()
            return alreadySynced(quiet: quiet)
        }
        let serial = clipboard.writeSerial
        let capture = await clipboard.capture()
        refreshClipboardHint()
        guard let capture else {
            if !quiet { showToast(clipboard.lastCaptureDeclined ? "Paste wasn't allowed." : "Nothing on the clipboard to sync.") }
            return
        }
        let source = clipboard.lastCaptureSourceHash.map { Set(["f:" + $0]) } ?? []
        await classifyAndSend(capture, mode: mode, writeSerial: serial, alternates: source)
    }

    /// From the system Paste control (iOS 16+, `fromPasteboard`: a manual
    /// capture of the clipboard), or a drop or share-in (content that is not
    /// from the clipboard: only what every device already has is held back).
    func sendProviders(_ providers: [NSItemProvider], fromPasteboard: Bool) async {
        guard engine != nil else { return }
        guard fromPasteboard else {
            guard let capture = await clipboard.capture(from: providers) else { return showToast("Nothing ClipLink can sync there.") }
            return share(capture)
        }
        beginCapture()
        defer { endCapture() }
        // Before reading, as for the Paste button: a received picture FILE
        // would come back as a re-encoded PNG, a new item next to its own card.
        if await holdsOwnSyncedWrite(.manual) {
            clipboard.markSeen()
            refreshClipboardHint()
            return alreadySynced(quiet: false)
        }
        let serial = clipboard.writeSerial
        guard let capture = await clipboard.capture(from: providers) else { return showToast("Nothing ClipLink can sync there.") }
        clipboard.markSeen()
        refreshClipboardHint()
        await classifyAndSend(capture, mode: .manual, writeSerial: serial)
    }

    private func beginCapture() {
        capturesInFlight += 1
    }

    /// The automatic capture, counted in flight from now on: an item that
    /// arrives before the task starts waits for it too.
    private func captureFirst() {
        beginCapture()
        Task {
            await captureAndSend(quiet: true)
            endCapture()
        }
    }

    /// The last read in flight is done: an item that arrived meanwhile lands now.
    private func endCapture() {
        capturesInFlight -= 1
        guard capturesInFlight == 0, let (entry, url) = applyAfterCapture else { return }
        applyAfterCapture = nil
        autoApply(entry, fileURL: url)
    }

    /// Steps 2 to 5 of sync-dedupe-spec 1.3, once the clipboard has been read
    /// (`writeSerial` as it was before the read): what ClipLink last wrote or
    /// classified, and what the newest entry already is, is not sent again -
    /// pasting the same clipboard twice is one item, and so is copying what
    /// just arrived from a peer. Re-copying an older item goes out: that is how
    /// it gets back onto the other devices.
    private func classifyAndSend(_ capture: Capture, mode: CaptureMode, writeSerial: Int, alternates: Set<String> = []) async {
        let quiet = mode == .auto
        // Hashing (and fingerprinting) reads the whole thing: off the main actor.
        let (read, fingerprint) = await Self.prints(of: capture)
        let known = await historyPrints()
        // ClipLink wrote the clipboard while it was being read: what was read
        // may be what that write replaced. Its own write is synced already.
        guard clipboard.writeSerial == writeSerial else {
            ItemLoader.discard(capture)
            return
        }
        // A file that can't be hashed can't be compared either: the engine
        // says why it can't be sent.
        guard var print = read else { return transmit(capture, filter: nil, fingerprint: fingerprint) }
        print.alternates.formUnion(alternates)
        let verdict = CaptureCheck.classify(print, mode: mode, lastWrite: clipboard.lastWrite,
                                            historyKeys: known.all, newestKeys: known.newest)
        clipboard.noteLastWrite(print.all)
        guard verdict == .new else {
            ItemLoader.discard(capture)
            return alreadySynced(quiet: quiet)
        }
        transmit(capture, filter: nil, fingerprint: fingerprint)
    }

    /// A capture's print, and a picture's fingerprint (see `received`). Nil
    /// print for a file that can't be read.
    nonisolated private static func prints(of capture: Capture) async -> (CapturePrint?, ImageFingerprint?) {
        await Task.detached(priority: .userInitiated) { () -> (CapturePrint?, ImageFingerprint?) in
            switch capture {
            case .text(let text):
                return (CapturePrint.text(text), nil)
            case .image(let png):
                return (CapturePrint.image(png), ImageFingerprint(imageData: png))
            case .file(let url, _):
                return ((try? ContentHash.sha256Hex(fileAt: url)).map { CapturePrint.file(hash: $0) }, nil)
            }
        }.value
    }

    /// A share, a drop or a picked file: not from the clipboard, so neither the
    /// own-write nor the last-write check applies - only content every device
    /// already has (the newest entry) is not signed again (sync-dedupe-spec 1.4).
    private func share(_ capture: Capture) {
        guard let engine else { return ItemLoader.discard(capture) }
        engine.makeSendFilter(newest: 1) { [weak self] filter in
            Task {
                var fingerprint: ImageFingerprint?
                if case .image(let png) = capture {
                    fingerprint = await Task.detached(priority: .userInitiated) { ImageFingerprint(imageData: png) }.value
                }
                self?.transmit(capture, filter: filter, fingerprint: fingerprint)
            }
        }
    }

    /// Signs and sends. A picture bigger than `maxInlineImageBytes` as PNG goes
    /// as a file instead.
    private func transmit(_ capture: Capture, filter: SendFilter?, fingerprint: ImageFingerprint?) {
        guard let engine else { return ItemLoader.discard(capture) }
        switch capture {
        case .text(let text):
            engine.sendText(text, filter: filter) { [weak self] in self?.report($0) }
        case .image(let png):
            if let fingerprint { lastSentImage = (fingerprint, Date()) }
            guard png.count > Self.maxInlineImageBytes else {
                engine.sendImage(png: png, filter: filter) { [weak self] in self?.report($0) }
                return
            }
            Task {
                let url = ItemLoader.tempURL(named: "Image.png")
                let written = await Task.detached(priority: .userInitiated) { (try? png.write(to: url)) != nil }.value
                guard written else { return showToast("Couldn't store that image.") }
                engine.sendFile(at: url, name: "Image.png", moveIntoStore: true, filter: filter) { [weak self] in self?.report($0) }
            }
        case .file(let url, let name):
            engine.sendFile(at: url, name: name, moveIntoStore: true, filter: filter) { [weak self] in self?.report($0) }
        }
    }

    /// A manual paste of what is already synced says why nothing happened;
    /// the automatic capture stays silent.
    private func alreadySynced(quiet: Bool) {
        if !quiet { showToast("Already synced.") }
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
            share(.file(temp, name: name))
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
            return share(.file(temp, name: name))
        }
        Task {
            let limit = Self.maxInlineImageBytes
            let png = await Task.detached(priority: .userInitiated) { ItemLoader.inlinePNG(forImageFileAt: temp, maxBytes: limit) }.value
            guard let png else { return share(.file(temp, name: name)) }
            try? FileManager.default.removeItem(at: temp.deletingLastPathComponent())
            share(.image(png: png))
        }
    }

    /// Photos picked from the library (PHPicker hands over the original bytes,
    /// often a 12-48 MP HEIC): decoded and re-encoded off the main thread.
    func sendImageData(_ data: Data) {
        Task {
            let png = await Task.detached(priority: .userInitiated) { ItemLoader.pngData(fromImageData: data) }.value
            guard let png else { return showToast("Couldn't read that image.") }
            share(.image(png: png))
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
        receivedCount += 1
        // A picture compared with what was just sent, or with a picture
        // ClipLink last put on the clipboard, is decoded for it: megabytes,
        // off the main thread - the card's arrival is animating meanwhile.
        let sent = lastSentImage.flatMap { Date().timeIntervalSince($0.1) < 30 ? $0.0 : nil }
        let wantsPrint = clipboard.lastWrite.prints.contains { $0.hasPrefix("i:") }
        guard entry.type == Wire.EntryType.image, sent != nil || wantsPrint else {
            return handleReceived(entry, fileURL: fileURL, picturePrint: nil)
        }
        let order = receivedCount
        let content = entry.content
        Task {
            let (echo, print) = await Self.checkPicture(content, sentRecently: sent, wantsPrint: wantsPrint)
            // A newer item came meanwhile: it is the one the clipboard gets.
            guard order == receivedCount else { return }
            // Windows re-encoding our own image and sending it back.
            if echo { return }
            handleReceived(entry, fileURL: fileURL, picturePrint: print)
        }
    }

    /// Whether a received picture looks like the one just sent (`sentRecently`),
    /// and its print when `wantsPrint`.
    nonisolated private static func checkPicture(_ content: String, sentRecently: ImageFingerprint?, wantsPrint: Bool) async -> (echo: Bool, print: String?) {
        await Task.detached(priority: .userInitiated) { () -> (echo: Bool, print: String?) in
            guard let data = Data(base64Encoded: content) else { return (false, nil) }
            let echo = sentRecently.map { sent in ImageFingerprint(imageData: data)?.looksLike(sent) ?? false } ?? false
            return (echo, wantsPrint ? ContentPrint.image(data) : nil)
        }.value
    }

    /// A received item, once a picture has been checked (`picturePrint`, see
    /// `received`).
    private func handleReceived(_ entry: ClipboardEntry, fileURL: URL?, picturePrint: String?) {
        // What the clipboard already holds, as far as ClipLink knows - an older
        // peer echoing back what it was given, say: it is in Synced (as one card
        // with its twin), and is neither written there again nor announced.
        guard !holdsAlready(entry, picturePrint: picturePrint) else { return }
        guard settings.autoApply else { return }
        guard isActive else {
            heldForForeground = (entry, fileURL)
            return
        }
        // Wait for a read in flight; and a copy the user made while ClipLink is
        // open (split view, Universal Clipboard) that it has not looked at yet
        // goes out first - written over, it would never be synced.
        if capturesInFlight > 0 {
            applyAfterCapture = (entry, fileURL)
        } else if settings.autoCapture, clipboard.hasUnseenChange {
            applyAfterCapture = (entry, fileURL)
            captureFirst()
        } else {
            autoApply(entry, fileURL: fileURL)
        }
    }

    /// The entry's content is what ClipLink last wrote to the clipboard or last
    /// read off it (see LastWrite). Decodes a picture only when the last write
    /// was one, and not at all when its print is given (`picturePrint`).
    private func holdsAlready(_ entry: ClipboardEntry, picturePrint: String? = nil) -> Bool {
        // Something else was copied since: the record no longer says what is there.
        guard !clipboard.hasUnseenChange else { return false }
        let prints = clipboard.lastWrite.prints
        let kind: String
        switch entry.type {
        case Wire.EntryType.text: kind = "t:"
        case Wire.EntryType.image: kind = "i:"
        case Wire.EntryType.file: kind = "f:"
        default: return false
        }
        guard prints.contains(where: { $0.hasPrefix(kind) }) else { return false }
        let given = entry.type == Wire.EntryType.image ? picturePrint : nil
        guard let key = given ?? ContentPrint.key(of: entry) else { return false }
        return prints.contains(key)
    }

    /// "Copy received items automatically", minus big files (see
    /// maxAutoApplyFileBytes): those just stay in Synced. Silent: the item
    /// has already appeared in the list, and a toast on every arrival is
    /// noise.
    private func autoApply(_ entry: ClipboardEntry, fileURL: URL?) {
        if entry.type == Wire.EntryType.image {
            return applyPicture(content: entry.content, inlineURL: nil) { [weak self] _ in self?.refreshClipboardHint() }
        }
        // The bytes that are here, not the size the sender declared.
        if entry.type == Wire.EntryType.file, let fileURL,
           (ClipboardService.fileSize(at: fileURL) ?? Int64.max) > ClipboardService.maxAutoApplyFileBytes {
            return
        }
        // A picture still being decoded must not land over this one.
        clipboardRequests += 1
        if clipboard.apply(entry, fileURL: fileURL) {
            refreshClipboardHint()
        }
    }

    /// Puts a picture on the clipboard once it is decoded off the main thread
    /// (see ClipboardService.decodePicture) - unless something newer was meant
    /// for the clipboard meanwhile, or the user put something there: the
    /// latest wins, as when every write was immediate. `then` is told whether
    /// it went there; not at all when it gave way.
    private func applyPicture(content: String, inlineURL: URL?, then: @escaping (Bool) -> Void) {
        clipboardRequests += 1
        let request = clipboardRequests
        let generation = userClipboardGeneration
        Task {
            let picture = await ClipboardService.decodePicture(content: content, inlineURL: inlineURL)
            guard request == clipboardRequests, generation == userClipboardGeneration else { return }
            guard let picture else { return then(false) }
            clipboard.apply(picture)
            then(true)
        }
    }

    /// The user put something on the clipboard: tell the engine, so a file
    /// still on its way does not replace it when it lands.
    private func noteUserClipboardChange() {
        userClipboardGeneration += 1
        engine?.noteClipboardGeneration(userClipboardGeneration)
    }

    // MARK: - Items

    func copy(_ item: SyncedItem) {
        let url = item.filePayload.flatMap { engine?.blobURL(forHash: $0.fileHash) }
        if item.kind == .file, url == nil {
            showToast("That file hasn't finished transferring yet.")
            return
        }
        if item.kind == .file, let url, (ClipboardService.fileSize(at: url) ?? 0) > ClipboardService.maxPasteboardFileBytes {
            showToast("That file is too big for the clipboard — use Share or Save instead.")
            return
        }
        if item.kind == .image {
            applyPicture(content: item.entry.content, inlineURL: item.inlineURL) { [weak self] copied in
                guard let self else { return }
                guard copied else { return self.showToast("Couldn't copy that item.") }
                self.noteUserClipboardChange()
                self.refreshClipboardHint()
                self.showToast("Copied.")
            }
            return
        }
        clipboardRequests += 1
        if clipboard.apply(item.entry, fileURL: url) {
            noteUserClipboardChange()
            refreshClipboardHint()
            showToast("Copied.")
        } else {
            showToast("Couldn't copy that item.")
        }
    }

    /// Text the user selected and copied in an item's text (the system Copy):
    /// written like ClipLink's own Copy, so it is not read back and sent as a
    /// new item, and stays off Universal Clipboard (ClipLink syncs it).
    func copySelection(_ text: String) {
        clipboard.copyText(text)
        noteUserClipboardChange()
        refreshClipboardHint()
    }

    /// Deleting leaves the clipboard record alone: Paste after a delete sends
    /// the item again (CaptureCheck), while opening the app does not.
    func delete(_ item: SyncedItem) {
        engine?.deleteItem(id: item.id)
    }

    /// A stack in the Synced list was opened: tell the engine, which stops
    /// listing it (the view has already shown its items as ordinary cards).
    func expandGroup(_ id: String) {
        engine?.dissolveGroup(id: id)
    }

    func clearHistory() {
        // No toast: the list visibly empties, after a confirmation.
        engine?.clearHistory()
    }

    /// A shareable file for a file item: the file itself under its real name.
    /// Nil for anything else, or while transferring. (A picture: see
    /// `pictureShareURL`.)
    func shareURL(for item: SyncedItem) -> URL? {
        guard item.kind == .file, let payload = item.filePayload else { return nil }
        return engine?.exportURL(for: payload)
    }

    /// A picture written out as a file of its own type, for the share sheet:
    /// decoded and written off the main thread. Named for its content, so two
    /// pictures never share a name and sharing one again reuses its file.
    func pictureShareURL(for item: SyncedItem) async -> URL? {
        guard item.kind == .image else { return nil }
        let content = item.entry.content
        let inlineURL = item.inlineURL
        let name = "ClipLink Image " + String((item.contentKey ?? ContentHash.sha256Hex(Data(item.id.utf8))).suffix(12))
        guard let picture = await ClipboardService.decodePicture(content: content, inlineURL: inlineURL) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            let ext = UTType(picture.type)?.preferredFilenameExtension ?? "png"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).\(ext)")
            return (try? picture.data.write(to: url, options: .atomic)) != nil ? url : nil
        }.value
    }

    /// A file item's picture, memory-mapped. Nil for anything else.
    func imageData(for item: SyncedItem) -> Data? {
        guard item.kind == .file, let payload = item.filePayload, Self.isImageFileName(payload.fileName),
              let url = engine?.blobURL(forHash: payload.fileHash) else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// An item's picture, for Photos: a picture item's decoded off the main
    /// thread, an image file's memory-mapped.
    func pictureData(for item: SyncedItem) async -> Data? {
        guard item.kind == .image else { return imageData(for: item) }
        return await ClipboardService.decodePicture(content: item.entry.content, inlineURL: item.inlineURL)?.data
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

    /// Another device's pairing QR code, read by the system camera or a scanner
    /// app, opened ClipLink with its link (https://cliplink.uaena.io/pair/#...,
    /// see PairingLink): show the pairing sheet and start pairing, as if the code
    /// had been scanned in the app. (Both devices still have to trust each other -
    /// the code only says where to dial.)
    func openPairingLink(_ url: URL) {
        let link = url.absoluteString
        guard PairingLink.isLink(link) else { return }
        pairingPresented = true
        pair(with: link)
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
        noteUserClipboardChange()
        showToast("Device ID copied.")
    }

    func copyPairingInfo() {
        clipboard.copyText(snapshot.pairingPayload)
        noteUserClipboardChange()
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
            // Unchanged (a beacon from a device whose row says nothing new):
            // nothing that watches the model is redrawn.
            if self.snapshot != snapshot { self.snapshot = snapshot }
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
