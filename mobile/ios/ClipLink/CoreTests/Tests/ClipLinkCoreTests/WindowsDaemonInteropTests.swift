import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import XCTest
@testable import ClipLinkCore

/// The iOS engine against the REAL Windows daemon code (windows/daemon, built
/// for macOS with only platform shims - see CoreTests/DaemonHarness). Every
/// byte the daemon sends or checks comes from its own PeerConnection,
/// SigningService, PassphraseAuth, Discovery, HistoryAccess and
/// System.Text.Json - including the trimmed-timestamp behaviour.
///
/// Skipped unless CLIPLINK_DOTNET (path to a .NET 10 `dotnet`) and
/// CLIPLINK_DAEMON_DLL (the built harness) are set; CoreTests/run-daemon-interop.sh
/// builds the harness and sets both.
final class WindowsDaemonInteropTests: XCTestCase {

    // MARK: - Daemon process

    final class Daemon {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let home: URL
        let label: String
        let tcpPort: UInt16
        let udpPort: UInt16
        private let lock = NSLock()
        private var lines: [String] = []
        private var partial = Data()
        private(set) var deviceId = ""

        init(label: String, tcpPort: UInt16, udpPort: UInt16, beaconTargets: String, passcode: String?, identity: P256.Signing.PrivateKey) throws {
            let env = ProcessInfo.processInfo.environment
            guard let dotnet = env["CLIPLINK_DOTNET"], let dll = env["CLIPLINK_DAEMON_DLL"] else { throw XCTSkip("daemon harness not configured") }
            self.label = label
            self.tcpPort = tcpPort
            self.udpPort = udpPort
            home = FileManager.default.temporaryDirectory.appendingPathComponent("cliplink-daemon-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            process.executableURL = URL(fileURLWithPath: dotnet)
            process.arguments = [dll, label, String(tcpPort)]
            var childEnv = env
            childEnv["HOME"] = home.path
            // .NET on macOS ignores HOME for ApplicationData; the harness reads this instead.
            childEnv["CLIPLINK_APPDATA"] = home.path
            childEnv["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
            childEnv["CLIPLINK_UDP_PORT"] = String(udpPort)
            childEnv["CLIPLINK_BEACON_TARGETS"] = beaconTargets
            childEnv["CLIPLINK_TAILSCALE_IP"] = ""
            childEnv["CLIPLINK_IDENTITY_PKCS8_B64"] = identity.derRepresentation.base64EncodedString()
            childEnv["CLIPLINK_PASSCODE"] = passcode ?? ""
            process.environment = childEnv
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stdout
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                self?.consume(handle.availableData)
            }
            try process.run()
        }

        private func consume(_ data: Data) {
            lock.lock()
            partial.append(data)
            while let newline = partial.firstIndex(of: 0x0A) {
                let line = String(decoding: partial[partial.startIndex..<newline], as: UTF8.self)
                partial.removeSubrange(partial.startIndex...newline)
                lines.append(line)
                if line.hasPrefix("Device ID (public key): ") { deviceId = String(line.dropFirst(24)) }
                if ProcessInfo.processInfo.environment["CLIPLINK_ECHO_DAEMON"] != nil { print("[daemon \(label)] \(line)") }
            }
            lock.unlock()
        }

        var output: [String] { lock.lock(); defer { lock.unlock() }; return lines }

        func send(_ command: String) {
            stdin.fileHandleForWriting.write(Data((command + "\n").utf8))
        }

        func copyText(_ text: String) { send("copytext " + Data(text.utf8).base64EncodedString()) }

        /// One JSON request per connection over the daemon's named pipe
        /// (a Unix socket in $TMPDIR on macOS) - exactly what the tray does.
        func ipc(_ command: String, _ payload: String? = nil) -> String? {
            // The daemon's pipe is single-instance and re-created after every
            // request, so a connect can land in the gap: retry briefly.
            for _ in 0..<40 {
                if let reply = ipcOnce(command, payload) { return reply }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return nil
        }

        private func ipcOnce(_ command: String, _ payload: String?) -> String? {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("CoreFxPipe_ClipboardDaemonIPC_\(label)").path
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                let bytes = Array(path.utf8.prefix(raw.count - 1))
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard ok == 0 else { return nil }
            var request: [String: Any] = ["Command": command]
            if let payload { request["Payload"] = payload }
            let line = WireJSON.string(request) + "\n"
            _ = line.withCString { write(fd, $0, strlen($0)) }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return nil }
            return String(decoding: buffer[0..<n], as: UTF8.self)
        }

        func stop() {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: home)
        }

        var dataDir: URL { home.appendingPathComponent("ClipboardDaemon") }
    }

    // MARK: - Helpers

    private var daemons: [Daemon] = []
    private var engines: [(SyncEngine, URL)] = []
    private var recorder = EngineIntegrationTests.Recorder()
    private static var portBase: UInt16 = 49800

    override func tearDown() {
        engines.forEach { $0.0.shutdown(); try? FileManager.default.removeItem(at: $0.1) }
        engines.removeAll()
        daemons.forEach { $0.stop() }
        daemons.removeAll()
        Thread.sleep(forTimeInterval: 0.5)
        super.tearDown()
    }

    private func wait(_ what: String, timeout: TimeInterval = 25, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("timed out waiting for: \(what)\n--- daemon output ---\n\(daemons.last?.output.suffix(40).joined(separator: "\n") ?? "")", file: file, line: line)
    }

    enum Order { case iOSDials, daemonDials }

    /// A daemon key and an iOS identity such that the requested side is the
    /// designated dialer (the ordinally LARGER id dials).
    private func identities(_ order: Order) -> (P256.Signing.PrivateKey, SoftwareIdentity) {
        while true {
            let daemonKey = P256.Signing.PrivateKey()
            let ios = SoftwareIdentity()
            let daemonId = daemonKey.publicKey.derRepresentation.base64EncodedString()
            let iosDials = DeviceOrder.shouldDial(peerId: daemonId, ownId: ios.publicKeyBase64)
            if iosDials == (order == .iOSDials) { return (daemonKey, ios) }
        }
    }

    /// Starts a daemon and an iOS engine wired to each other on loopback.
    /// `daemonBeaconsReachIOS: false` models iOS without the multicast
    /// entitlement: it never hears the daemon's (broadcast) beacons.
    private func start(order: Order, passcode: String?, daemonBeaconsReachIOS: Bool) throws -> (Daemon, SyncEngine) {
        let base = Self.portBase
        Self.portBase += 10
        let (daemonKey, iosIdentity) = identities(order)
        let daemonTCP = base, daemonUDP = base + 1, iosTCP = base + 2, iosUDP = base + 3
        let daemon = try Daemon(
            label: "t\(base)", tcpPort: daemonTCP, udpPort: daemonUDP,
            beaconTargets: daemonBeaconsReachIOS ? "127.0.0.1:\(iosUDP)" : "127.0.0.1:9",
            passcode: passcode, identity: daemonKey
        )
        daemons.append(daemon)
        wait("daemon started") { !daemon.deviceId.isEmpty }
        XCTAssertEqual(daemon.deviceId, daemonKey.publicKey.derRepresentation.base64EncodedString(), "same SPKI device id as .NET")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cliplink-ios-\(UUID().uuidString)")
        var config = EngineConfig(storageDirectory: dir)
        config.listenPort = iosTCP
        config.discoveryPort = iosUDP
        config.peerPort = daemonTCP
        config.peerDiscoveryPort = daemonUDP
        config.enableBroadcast = false
        config.enableSweeps = false
        config.extraBeaconTargets = ["127.0.0.1"]
        let engine = SyncEngine(config: config, identity: iosIdentity, secrets: MemorySecretStore())
        recorder = EngineIntegrationTests.Recorder()
        engine.delegate = recorder
        engines.append((engine, dir))
        if let passcode {
            let done = expectation(description: "passcode")
            engine.setPassphrase(passcode) { _ in done.fulfill() }
            wait(for: [done], timeout: 10)
        }
        engine.enterForeground()
        return (daemon, engine)
    }

    private func applied(_ daemon: Daemon, text: String) -> Bool {
        daemon.output.contains("APPLY text " + Data(text.utf8).base64EncodedString())
    }

    private func assertNoRejections(_ daemon: Daemon, file: StaticString = #filePath, line: UInt = #line) {
        let bad = daemon.output.filter { $0.contains("invalid signature") || $0.contains("failed hash verification") || $0.contains("HARNESS-ERROR") }
        XCTAssertTrue(bad.isEmpty, "daemon rejected something:\n\(bad.joined(separator: "\n"))", file: file, line: line)
    }

    // MARK: - Tests

    /// Passcode auto-trust in both tie-breaker directions, with and without
    /// iOS hearing the daemon's beacons, then text both ways and history
    /// catch-up of daemon entries whose timestamps System.Text.Json trimmed.
    func testPasscodeAutoPairAndTextSyncAllDirections() throws {
        for order in [Order.daemonDials, .iOSDials] {
            for hearsBeacons in [true, false] {
                let (daemon, engine) = try start(order: order, passcode: "correct horse", daemonBeaconsReachIOS: hearsBeacons)
                let label = "\(order) hearsBeacons=\(hearsBeacons)"

                // Captured on "Windows" before the phone connects: reaches iOS
                // only via history_batch, with a trimmed timestamp.
                daemon.copyText("from windows before connect ✓")
                wait("daemon recorded it [\(label)]") { daemon.output.contains { $0.contains("detected local text change") } }

                if order == .iOSDials && !hearsBeacons {
                    // iOS can't hear the daemon and must dial: give it the
                    // address, as a user would via Pair by Address.
                    var outcome: PairOutcome?
                    engine.pair(with: "127.0.0.1:\(daemon.tcpPort)") { outcome = $0 }
                    wait("pair outcome [\(label)]") { outcome != nil }
                    XCTAssertEqual(outcome, .passcode("127.0.0.1"), label)
                }
                wait("connected [\(label)]") { recorder.connectedCount == 1 }
                wait("history caught up [\(label)]") { recorder.items.contains { $0.entry.content == "from windows before connect ✓" } }
                let caught = recorder.items.first { $0.entry.content == "from windows before connect ✓" }!
                XCTAssertNotNil(DotNetTimestamp.canonical(caught.entry.timestamp))
                XCTAssertEqual(caught.entry.timestamp, DotNetTimestamp.canonical(caught.entry.timestamp), "stored canonical, so it re-relays verifiably")

                // iOS -> daemon
                let text = "from iOS \(label)\nsecond line \"quoted\" / é 😀"
                engine.sendText(text)
                wait("daemon applied iOS text [\(label)]") { applied(daemon, text: text) }
                // The real daemon's echo check: re-reading what it applied must not re-broadcast.
                daemon.copyText(text)
                wait("daemon suppressed its echo [\(label)]") { daemon.output.contains("ECHO-SUPPRESSED text") }

                // daemon -> iOS (live entry)
                daemon.copyText("live from windows \(label)")
                wait("iOS received live entry [\(label)]") { recorder.receivedEntries.contains { $0.0.content == "live from windows \(label)" } }

                assertNoRejections(daemon)
                tearDown()
            }
        }
    }

    func testFilesAndImagesBothWays() throws {
        let (daemon, engine) = try start(order: .daemonDials, passcode: "pw", daemonBeaconsReachIOS: false)
        wait("connected") { recorder.connectedCount == 1 }

        // iOS -> daemon: multi-chunk file
        let iosBytes = Data((0..<(Wire.fileChunkSize * 2 + 777)).map { _ in UInt8.random(in: 0...255) })
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("ios-\(UUID().uuidString).bin")
        try iosBytes.write(to: src)
        engine.sendFile(at: src, name: "from iOS.bin", moveIntoStore: false)
        let expectedHash = ContentHash.sha256Hex(iosBytes).uppercased()
        wait("daemon applied iOS file") { daemon.output.contains { $0 == "APPLY file from iOS.bin \(expectedHash) \(expectedHash)" } }
        // Re-copying the received file on "Windows" must be echo-suppressed -
        // only true because iOS sends the hash in uppercase.
        let stored = daemon.dataDir.appendingPathComponent("filestore\(daemon.label)/\(expectedHash)")
        daemon.send("copyfile \(stored.path)")
        wait("daemon suppressed file echo") { daemon.output.contains("ECHO-SUPPRESSED file") }

        // daemon -> iOS: multi-chunk file (UPPERCASE hash on the wire)
        let winBytes = Data((0..<(Wire.fileChunkSize * 3 + 5)).map { _ in UInt8.random(in: 0...255) })
        let winFile = FileManager.default.temporaryDirectory.appendingPathComponent("report from windows.pdf")
        try winBytes.write(to: winFile)
        daemon.send("copyfile \(winFile.path)")
        wait("iOS received daemon file") { recorder.receivedEntries.contains { $0.0.type == "file" && $0.1 != nil } }
        let got = recorder.receivedEntries.first { $0.0.type == "file" }!
        XCTAssertEqual(try Data(contentsOf: got.1!), winBytes)
        XCTAssertEqual(FilePayload.parse(got.0.content)?.fileName, "report from windows.pdf")

        // iOS -> daemon image (inline base64)
        let png = Self.makePNG()
        engine.sendImage(png: png)
        wait("daemon applied image") { daemon.output.contains("APPLY image \(ContentHash.sha256Hex(png).uppercased()) \(png.count)") }

        // daemon -> iOS image
        let winPNG = FileManager.default.temporaryDirectory.appendingPathComponent("win-\(UUID().uuidString).png")
        try Self.makePNG(red: 0).write(to: winPNG)
        daemon.send("copyimage \(winPNG.path)")
        wait("iOS received image") { recorder.receivedEntries.contains { $0.0.type == "image" } }
        XCTAssertEqual(Data(base64Encoded: recorder.receivedEntries.first { $0.0.type == "image" }!.0.content), try Data(contentsOf: winPNG))

        assertNoRejections(daemon)
    }

    /// The tray's Pairing window flow over the daemon's real IPC: pairing mode
    /// on both sides, a pairing handshake, and Accept on BOTH devices.
    func testQRStylePairingWithAcceptOnBothSides() throws {
        for order in [Order.daemonDials, .iOSDials] {
            let (daemon, engine) = try start(order: order, passcode: nil, daemonBeaconsReachIOS: order == .iOSDials)
            XCTAssertNotNil(daemon.ipc("set_pairing_mode", "1"), "IPC reachable")
            engine.setPairingOpen(true)

            wait("iOS shows the pairing prompt [\(order)]") { recorder.pairingRequest?.deviceId == daemon.deviceId }
            var pendingOnDaemon = ""
            wait("daemon has a pending request [\(order)]") {
                let reply = daemon.ipc("get_pending_pairing") ?? ""
                pendingOnDaemon = reply
                return reply.contains("MFkw")
            }
            XCTAssertTrue(pendingOnDaemon.contains(engine.ownId.replacingOccurrences(of: "+", with: "\\u002B")), "daemon's pending peer is this iPhone")

            XCTAssertEqual(recorder.connectedCount, 0, "nothing flows before both accept")
            XCTAssertTrue(daemon.ipc("accept_pairing")?.contains("paired") == true)
            engine.acceptPairing()
            wait("connected [\(order)]") { recorder.connectedCount == 1 }

            engine.sendText("paired via QR flow \(order)")
            wait("daemon applied [\(order)]") { applied(daemon, text: "paired via QR flow \(order)") }
            daemon.copyText("hello back \(order)")
            wait("iOS received [\(order)]") { recorder.receivedEntries.contains { $0.0.content == "hello back \(order)" } }
            assertNoRejections(daemon)
            tearDown()
        }
    }

    /// Untrusting on "Windows" closes the link; the iPhone notices and does
    /// not flap (it backs off a peer that immediately hangs up on it).
    func testDaemonUntrustDisconnectsAndIPhoneBacksOff() throws {
        let (daemon, engine) = try start(order: .iOSDials, passcode: nil, daemonBeaconsReachIOS: true)
        XCTAssertNotNil(daemon.ipc("trust_device", PairingInfo(publicKey: engine.ownId, address: "127.0.0.1").jsonString()))
        engine.trustDevice(daemon.deviceId)
        wait("connected") { recorder.connectedCount == 1 }
        _ = daemon.ipc("untrust_device", engine.ownId)
        wait("iOS saw the disconnect") { recorder.connectedCount == 0 }
        // Beacons keep arriving; count how often iOS redials in 12 s.
        let before = daemon.output.filter { $0.contains("rejected or incomplete") }.count
        RunLoop.main.run(until: Date().addingTimeInterval(12))
        let redials = daemon.output.filter { $0.contains("rejected or incomplete") }.count - before
        XCTAssertLessThanOrEqual(redials, 3, "iPhone should back off instead of redialling every beacon")
    }

    // MARK: - PNG

    static func makePNG(red: UInt8 = 200) -> Data {
        let width = 64, height = 48
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = red; pixels[i + 1] = UInt8(x * 4); pixels[i + 2] = UInt8(y * 5); pixels[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
