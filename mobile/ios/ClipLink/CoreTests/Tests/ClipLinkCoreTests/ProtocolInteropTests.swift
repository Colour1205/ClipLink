import CryptoKit
import XCTest
@testable import ClipLinkCore

/// The places this port must agree byte-for-byte with Windows, Android and
/// HarmonyOS, where being wrong fails SILENTLY (a signature that just doesn't
/// verify, a key that just doesn't match) rather than loudly.
final class ProtocolInteropTests: XCTestCase {

    private var vectors: [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(InteropVectors.json.utf8)) as! [String: Any]
    }

    // MARK: identity / signatures

    func testDeviceIdIsSpkiWithTheStandardP256Header() {
        let id = SoftwareIdentity().publicKeyBase64
        XCTAssertEqual(id.count, 124, "91-byte SPKI DER is 124 base64 chars on every platform")
        XCTAssertTrue(id.hasPrefix("MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE"))
        XCTAssertFalse(id.contains(":"), "beacon splitting depends on this")
    }

    func testSameKeyGivesTheSameIdAsOpenSSL() throws {
        let raw = Data(hex: vectors["identityRawPrivHex"] as! String)
        let identity = SoftwareIdentity(privateKey: try P256.Signing.PrivateKey(rawRepresentation: raw))
        XCTAssertEqual(identity.publicKeyBase64, vectors["identitySpkiB64"] as! String)
    }

    func testVerifiesForeignRawSignaturesIncludingHighS() {
        let spki = vectors["identitySpkiB64"] as! String
        let sigs = vectors["signatures"] as! [[String: String]]
        XCTAssertGreaterThan(vectors["highSCount"] as! Int, 5, "fixture must actually exercise high-S")
        for s in sigs {
            XCTAssertTrue(WireSignature.verify(publicKeyBase64: spki, data: Data(s["msg"]!.utf8), signatureBase64: s["sigB64"]), s["msg"]!)
            XCTAssertFalse(WireSignature.verify(publicKeyBase64: spki, data: Data((s["msg"]! + "x").utf8), signatureBase64: s["sigB64"]))
        }
    }

    func testOwnSignaturesAreRaw64Bytes() throws {
        let identity = SoftwareIdentity()
        let sig = try identity.sign(Data("x".utf8))
        XCTAssertEqual(sig.count, 64)
        XCTAssertTrue(WireSignature.verify(publicKeyBase64: identity.publicKeyBase64, data: Data("x".utf8), rawSignature: sig))
    }

    func testMalformedSignatureInputsReturnFalseNotThrow() {
        let id = SoftwareIdentity().publicKeyBase64
        XCTAssertFalse(WireSignature.verify(publicKeyBase64: "not base64!", data: Data(), signatureBase64: "AAAA"))
        XCTAssertFalse(WireSignature.verify(publicKeyBase64: id, data: Data(), signatureBase64: nil))
        XCTAssertFalse(WireSignature.verify(publicKeyBase64: id, data: Data(), rawSignature: Data(count: 70)))
    }

    // MARK: handshake / session

    func testSessionKeyMatchesOpenSSL() throws {
        let mine = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: vectors["ecdhAPrivHex"] as! String))
        let theirs = Data(base64Encoded: vectors["ecdhBSpkiB64"] as! String)!
        let key = try HandshakeCrypto.sessionKey(myEphemeral: mine, theirEphemeralSPKI: theirs)
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }.hexString, vectors["sessionKeyHex"] as! String)
    }

    func testHandshakeSignatureOverEphemeralSpkiVerifies() {
        let spki = Data(base64Encoded: vectors["ecdhBSpkiB64"] as! String)!
        XCTAssertTrue(WireSignature.verify(publicKeyBase64: vectors["identitySpkiB64"] as! String, data: spki, signatureBase64: vectors["handshakeSigB64"] as? String))
    }

    func testOpensForeignGcmLinesWithTagBeforeCiphertext() throws {
        let cipher = SessionCipher(keyBytes: Data(hex: vectors["sessionKeyHex"] as! String))
        XCTAssertEqual(try cipher.open(vectors["gcmPackedB64"] as! String), vectors["gcmPlain"] as! String)
    }

    func testSealProducesNonceTagCiphertextLayout() throws {
        let keyBytes = Data((0..<32).map { UInt8($0) })
        let cipher = SessionCipher(keyBytes: keyBytes)
        let line = try cipher.seal("hello")
        let packed = Data(base64Encoded: line)!
        XCTAssertEqual(packed.count, 12 + 16 + 5)
        // Re-open by hand using the documented layout.
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: packed.prefix(12)), ciphertext: packed.suffix(5), tag: packed.subdata(in: 12..<28))
        XCTAssertEqual(String(data: try AES.GCM.open(box, using: SymmetricKey(data: keyBytes)), encoding: .utf8), "hello")
        XCTAssertFalse(line.contains("\n"))
    }

    func testTamperedLineThrows() throws {
        let cipher = SessionCipher(keyBytes: Data(count: 32))
        var packed = Data(base64Encoded: try cipher.seal("hello"))!
        packed[packed.count - 1] ^= 0x01
        XCTAssertThrowsError(try cipher.open(packed.base64EncodedString()))
        XCTAssertThrowsError(try cipher.open("short"))
    }

    // MARK: passcode

    func testPbkdf2PublishedVectors() {
        let p = Data("password".utf8), s = Data("salt".utf8)
        XCTAssertEqual(PassphraseAuth.pbkdf2SHA256(password: p, salt: s, iterations: 1, keyLength: 32).hexString,
                       "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        XCTAssertEqual(PassphraseAuth.pbkdf2SHA256(password: p, salt: s, iterations: 4096, keyLength: 32).hexString,
                       "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    }

    func testPassphraseKeyAndProofMatchOpenSSLWithRealParameters() {
        let key = PassphraseAuth.deriveKey(passphrase: vectors["pbkdf2Passphrase"] as! String)
        XCTAssertEqual(key.hexString, vectors["pbkdf2KeyHex"] as! String)
        let id = vectors["identitySpkiB64"] as! String
        XCTAssertEqual(PassphraseAuth.proof(key: key, deviceId: id), vectors["proofB64"] as! String)
        XCTAssertTrue(PassphraseAuth.verifyProof(key: key, deviceId: id, proofBase64: vectors["proofB64"] as? String))
        XCTAssertFalse(PassphraseAuth.verifyProof(key: key, deviceId: id + "x", proofBase64: vectors["proofB64"] as? String))
        XCTAssertFalse(PassphraseAuth.verifyProof(key: key, deviceId: id, proofBase64: "%%%"))
    }

    // MARK: timestamps

    func testNowMatchesDotNetRoundTripShapeAndSurvivesTrimming() {
        let pattern = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$"#)
        for i in 0..<500 {
            let ts = DotNetTimestamp.now(Date(timeIntervalSince1970: 1_790_000_000 + Double(i) * 0.1))
            XCTAssertEqual(pattern.numberOfMatches(in: ts, range: NSRange(ts.startIndex..., in: ts)), 1, ts)
            XCTAssertNotEqual(ts.dropLast().last, "0", "last digit must survive System.Text.Json trimming: \(ts)")
            XCTAssertEqual(DotNetTimestamp.canonical(ts), ts, "our own text is already canonical")
        }
    }

    func testCanonicalReversesSystemTextJsonTrimming() {
        XCTAssertEqual(DotNetTimestamp.canonical("2026-09-26T12:34:56.12345Z"), "2026-09-26T12:34:56.1234500Z")
        XCTAssertEqual(DotNetTimestamp.canonical("2026-09-26T12:34:56Z"), "2026-09-26T12:34:56.0000000Z")
        XCTAssertEqual(DotNetTimestamp.canonical("2026-09-26T12:34:56.1+02:00"), "2026-09-26T12:34:56.1000000+02:00")
        XCTAssertNil(DotNetTimestamp.canonical("yesterday"))
        XCTAssertNil(DotNetTimestamp.canonical("2026-09-26T12:34:56.12345678Z"))
    }

    func testOrderingHandlesTrimmedFractionsAndOffsets() {
        XCTAssertTrue(DotNetTimestamp.isEarlier("2026-09-26T12:34:56.12345Z", than: "2026-09-26T12:34:56.1234567Z"))
        XCTAssertTrue(DotNetTimestamp.isEarlier("2026-09-26T14:00:00.0000000+02:00", than: "2026-09-26T12:00:00.0000001Z"))
        XCTAssertFalse(DotNetTimestamp.isEarlier("2026-09-26T12:00:00.0000001Z", than: "2026-09-26T14:00:00.0000000+02:00"))
    }

    func testTrimmedWindowsEntryVerifiesAndIsStoredCanonical() {
        for key in ["trimmed", "trimmedWhole"] {
            let t = vectors[key] as! [String: String]
            let wire = ClipboardEntry(content: t["content"]!, type: "text", deviceId: vectors["identitySpkiB64"] as! String, timestamp: t["wireTs"]!, signature: t["sigB64"]!)
            let verified = EntrySigning.verified(wire)
            XCTAssertNotNil(verified, key)
            XCTAssertEqual(verified?.timestamp, t["signedTs"]!, "must keep the text that actually verified")
            var forged = wire
            forged.content += "!"
            XCTAssertNil(EntrySigning.verified(forged))
        }
    }

    func testSignedEntryRoundTripsThroughJSON() throws {
        let identity = SoftwareIdentity()
        let entry = try EntrySigning.sign(content: "multi\nline \"quoted\" / slash é 🌍", type: Wire.EntryType.text, identity: identity)
        let parsed = ClipboardEntry.parse(entry.jsonString())
        XCTAssertEqual(parsed, entry)
        XCTAssertEqual(EntrySigning.verified(parsed!), entry)
    }

    // MARK: JSON shapes

    func testJsonKeysArePascalCase() {
        let entry = ClipboardEntry(content: "a", type: "text", deviceId: "id", timestamp: "t", signature: nil)
        let obj = WireJSON.object(entry.jsonString())!
        XCTAssertEqual(Set(obj.keys), ["Content", "Type", "DeviceId", "Timestamp", "Signature"])
        XCTAssertTrue(obj["Signature"] is NSNull)

        let env = WireJSON.object(Envelope(type: "entry", payload: entry.jsonString()).jsonString())!
        XCTAssertTrue(env["Payload"] is String, "Payload must be a JSON string, never a nested object")

        let chunk = WireJSON.object(FileChunkMessage(fileHash: "AB", chunkIndex: 3, isLast: true, dataBase64: "AA==").jsonString())!
        XCTAssertEqual(chunk["IsLast"] as? Bool, true)
        XCTAssertEqual((chunk["ChunkIndex"] as? NSNumber)?.intValue, 3)
        XCTAssertTrue(FileChunkMessage(fileHash: "AB", chunkIndex: 0, isLast: false, dataBase64: "").jsonString().contains("\"IsLast\":false"))
    }

    func testParsesWindowsShapedMessages() {
        // Exactly what System.Text.Json writes for these records.
        let entry = ClipboardEntry.parse(#"{"Content":"a\/b","Type":"text","DeviceId":"id","Timestamp":"2026-09-26T12:34:56.12345Z","Signature":null}"#)
        XCTAssertEqual(entry?.content, "a/b")
        XCTAssertNil(entry?.signature)
        XCTAssertEqual(FilePayload.parse(#"{"FileName":"r.pdf","FileHash":"E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855","FileSize":1234567890123}"#),
                       FilePayload(fileName: "r.pdf", fileHash: "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855", fileSize: 1_234_567_890_123))
        XCTAssertEqual(PairingInfo.parse(#"{"PublicKey":"KEY","Address":null}"#), PairingInfo(publicKey: "KEY", address: nil))
        XCTAssertEqual(PairingInfo.parse(#"  {"PublicKey":"KEY","Address":"100.64.0.2"} "#)?.address, "100.64.0.2")
        XCTAssertNil(PairingInfo.parse("192.168.1.20"))
        let hs = HandshakeMessage.parse(#"{"EphemeralPublicKey":"E","IdentityPublicKey":"I","Signature":"S","PassphraseProof":null}"#)
        XCTAssertEqual(hs, HandshakeMessage(ephemeralPublicKey: "E", identityPublicKey: "I", signature: "S", passphraseProof: nil))
        XCTAssertNil(HandshakeMessage.parse(#"{"EphemeralPublicKey":"E","IdentityPublicKey":"","Signature":"S"}"#))
        XCTAssertNil(Envelope.parse("not json"))
        XCTAssertEqual(ClipboardEntry.parseList(#"[{"Type":"text","DeviceId":"d","Timestamp":"t"},{"bogus":1},3]"#)?.count, 1)
        XCTAssertNil(ClipboardEntry.parseList(#"{"not":"an array"}"#))
    }

    func testHandshakeOmitsProofWhenAbsent() {
        let json = HandshakeMessage(ephemeralPublicKey: "E", identityPublicKey: "I", signature: "S", passphraseProof: nil).jsonString()
        XCTAssertFalse(json.contains("PassphraseProof"))
    }

    // MARK: beacon

    func testBeaconFullFormAndDashes() {
        let b = Beacon.parse("49000:SOMEKEY:SOMEPROOF:100.64.0.1:1", senderIP: "192.168.1.5")
        XCTAssertEqual(b, Beacon(tcpPort: 49000, deviceId: "SOMEKEY", proof: "SOMEPROOF", address: "100.64.0.1", pairing: true, senderIP: "192.168.1.5"))
        let d = Beacon.parse("49000:SOMEKEY:-:-:-", senderIP: "10.0.0.2")!
        XCTAssertNil(d.proof); XCTAssertNil(d.address); XCTAssertFalse(d.pairing)
        let legacy = Beacon.parse("49000:SOMEKEY:-", senderIP: "10.0.0.2")!
        XCTAssertNil(legacy.address); XCTAssertFalse(legacy.pairing)
        XCTAssertNil(Beacon.parse("", senderIP: "x"))
        XCTAssertNil(Beacon.parse("garbage", senderIP: "x"))
        XCTAssertNil(Beacon.parse("notaport:KEY:-", senderIP: "x"))
        XCTAssertNil(Beacon.parse("49000::-", senderIP: "x"))
        XCTAssertEqual(Beacon.build(tcpPort: 49000, deviceId: "K", proof: nil, address: "", pairing: false), "49000:K:-:-:-")
        XCTAssertEqual(Beacon.build(tcpPort: 49000, deviceId: "K", proof: "P", address: "100.1.2.3", pairing: true), "49000:K:P:100.1.2.3:1")
    }

    // MARK: framing

    func testFramerHandlesCRLFSplitsAndEmptyLines() throws {
        var f = LineFramer(maxLineBytes: 1024)
        XCTAssertEqual(try f.append(Data("ab".utf8)), [])
        XCTAssertEqual(try f.append(Data("c\r\n\nde".utf8)).map { String(data: $0, encoding: .utf8)! }, ["abc"])
        XCTAssertEqual(try f.append(Data("f\n\r\ng\n".utf8)).map { String(data: $0, encoding: .utf8)! }, ["def", "g"])
        XCTAssertEqual(f.bufferedByteCount, 0)
    }

    func testFramerRejectsOversizedHandshakeLine() {
        var f = LineFramer(maxLineBytes: 1_000, firstLineMaxBytes: 8)
        XCTAssertThrowsError(try f.append(Data("0123456789".utf8)), "a stranger can't make us buffer past the first-line cap")
        var g = LineFramer(maxLineBytes: 1_000, firstLineMaxBytes: 8)
        XCTAssertThrowsError(try g.append(Data("0123456789\n".utf8)))
    }

    func testFramerSkipsOversizedSessionLinesAndRecovers() throws {
        var f = LineFramer(maxLineBytes: 8, firstLineMaxBytes: 8)
        XCTAssertEqual(try f.append(Data("hello\n".utf8)).count, 1)
        // A huge line arrives in pieces: dropped without being buffered...
        XCTAssertEqual(try f.append(Data("0123456789".utf8)), [])
        XCTAssertEqual(f.bufferedByteCount, 0)
        XCTAssertEqual(try f.append(Data("abcdef".utf8)), [])
        // ...and framing resumes after its newline.
        XCTAssertEqual(try f.append(Data("xyz\nok\n".utf8)).map { String(data: $0, encoding: .utf8)! }, ["ok"])
        XCTAssertEqual(try f.append(Data("0123456789\nfine\n".utf8)).map { String(data: $0, encoding: .utf8)! }, ["fine"])
        XCTAssertEqual(f.droppedLines, 2)
    }

    func testWindowsSafeFileNames() {
        XCTAssertEqual(SyncEngine.windowsSafeName("Notes 10:30?.txt"), "Notes 10_30_.txt")
        XCTAssertEqual(SyncEngine.windowsSafeName("con.txt"), "_con.txt")
        XCTAssertEqual(SyncEngine.windowsSafeName("LPT1"), "_LPT1")
        XCTAssertEqual(SyncEngine.windowsSafeName("report. "), "report")
        XCTAssertEqual(SyncEngine.windowsSafeName("a\\b/c.pdf"), "a_b_c.pdf")
    }

    func testHistoryBatchAddDedupsAndReportsOnlySurvivors() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir, fileStore: FileStore(directory: dir))
        func entry(_ i: Int) -> ClipboardEntry {
            ClipboardEntry(content: "\(i)", type: "text", deviceId: "d", timestamp: String(format: "2026-09-27T10:00:%02d.0000001Z", i), signature: "s\(i)")
        }
        let batch = (0..<30).map(entry) + [entry(29)]
        let fresh = store.add(contentsOf: batch)
        XCTAssertEqual(store.entries.count, Wire.historyCap)
        XCTAssertEqual(fresh.count, Wire.historyCap, "the 5 oldest were evicted straight away and aren't 'new'")
        XCTAssertEqual(Set(fresh.map(\.content)), Set((5..<30).map(String.init)))
        XCTAssertTrue(store.add(contentsOf: batch).isEmpty)
        // A second store instance (the other process) sees and merges.
        let other = HistoryStore(directory: dir, fileStore: FileStore(directory: dir))
        other.add(entry(40))
        XCTAssertTrue(store.add(entry(41)))
        XCTAssertTrue(store.entries.contains { $0.content == "40" }, "merged the other process's write instead of overwriting it")
    }

    func testTieBreakerIsOrdinal() {
        // Ordinal: uppercase sorts before lowercase. A culture-aware compare
        // puts 'k' before 'Q' and makes both sides (or neither) dial.
        XCTAssertTrue(DeviceOrder.isOrdinallyLess("MFkQ", "MFkk"))
        XCTAssertFalse(DeviceOrder.isOrdinallyLess("MFkk", "MFkQ"))
        XCTAssertFalse(DeviceOrder.isOrdinallyLess("A", "A"))
        XCTAssertTrue(DeviceOrder.isOrdinallyLess("A", "AB"))
        XCTAssertTrue(DeviceOrder.isOrdinallyLess("+", "/"))
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

final class JSONRobustnessTests: XCTestCase {
    /// FileHash is peer-controlled and becomes a path component: anything
    /// but 64 hex digits must be refused before it gets near the filesystem.
    func testFileHashesMustBeSHA256Hex() {
        let good = String(repeating: "a1", count: 32)
        XCTAssertNotNil(FileRequestMessage.parse(#"{"FileHash":"\#(good.uppercased())"}"#))
        for bad in ["../../trusted_devices.json", "..", "", String(repeating: "a", count: 63), String(repeating: "g", count: 64), good + "/x"] {
            XCTAssertNil(FileRequestMessage.parse(WireJSON.string(["FileHash": bad])), bad)
            XCTAssertNil(FileChunkMessage.parse(WireJSON.string(["FileHash": bad, "ChunkIndex": 0, "IsLast": true, "DataBase64": ""])), bad)
            XCTAssertNil(FilePayload.parse(WireJSON.string(["FileName": "x", "FileHash": bad, "FileSize": 1])), bad)
        }
        XCTAssertFalse(FileStore.key("../../history.json").contains("/"))
        XCTAssertFalse(FileStore.key("..").contains("."))
    }

    func testOneLoneSurrogateDoesNotSinkTheWholeBatch() {
        let good = #"{"Content":"ok","Type":"text","DeviceId":"d","Timestamp":"t","Signature":"s"}"#
        let bad = #"{"Content":"broken \uD800 text","Type":"text","DeviceId":"d","Timestamp":"t2","Signature":"s"}"#
        let pair = #"{"Content":"emoji 😀","Type":"text","DeviceId":"d","Timestamp":"t3","Signature":"s"}"#
        let list = ClipboardEntry.parseList("[\(good),\(bad),\(pair)]")
        XCTAssertEqual(list?.count, 3)
        XCTAssertEqual(list?[2].content, "emoji 😀", "valid surrogate pairs are untouched")
        XCTAssertEqual(list?[1].content, "broken \u{FFFD} text")
    }
}
