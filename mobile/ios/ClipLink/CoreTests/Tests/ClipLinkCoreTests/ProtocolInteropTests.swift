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

    /// Ids are compared as text everywhere else, but our own must be spotted
    /// however a copy of it is spelt: .NET skips whitespace, Java needs no
    /// padding, and a padding character's spare bits decode either way.
    func testSameKeyIsFoundHoweverTheIdIsSpelt() throws {
        let id = SoftwareIdentity().publicKeyBase64
        let key = try XCTUnwrap(WireSignature.canonicalPublicKey(id))
        XCTAssertEqual(key.count, 64, "the raw point")
        XCTAssertTrue(WireSignature.isSameKey(id, id))

        let wrapped = stride(from: 0, to: id.count, by: 40).map { start -> String in
            let from = id.index(id.startIndex, offsetBy: start)
            return String(id[from..<id.index(from, offsetBy: min(40, id.count - start))])
        }.joined(separator: "\r\n")
        let respelt = [
            wrapped,
            " " + id + "\n",
            String(id.dropLast(2)), // no padding
            id.replacingOccurrences(of: "A", with: "A "),
        ]
        for copy in respelt {
            XCTAssertNotEqual(copy, id)
            XCTAssertEqual(WireSignature.canonicalPublicKey(copy), key, copy.debugDescription)
            XCTAssertTrue(WireSignature.isSameKey(copy, id), copy.debugDescription)
            XCTAssertTrue(WireSignature.isSameKey(id, copy), copy.debugDescription)
        }

        // 91 bytes end in one byte over: its last digit's low 4 bits are
        // spare. Any decoder that takes them set takes them as our key too.
        let digits = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        var chars = Array(id)
        XCTAssertTrue(id.hasSuffix("=="))
        let last = chars.count - 3
        let value = try XCTUnwrap(digits.firstIndex(of: chars[last]))
        XCTAssertEqual(value & 0x0F, 0)
        chars[last] = digits[value | 0x05]
        let spareBits = String(chars)
        if Data(base64Encoded: spareBits) == Data(base64Encoded: id) {
            XCTAssertTrue(WireSignature.isSameKey(spareBits, id))
        }

        // Anyone else's key, or no key at all, isn't ours.
        XCTAssertFalse(WireSignature.isSameKey(SoftwareIdentity().publicKeyBase64, id))
        XCTAssertFalse(WireSignature.isSameKey("", id))
        XCTAssertFalse(WireSignature.isSameKey("not a key", id))
        XCTAssertFalse(WireSignature.isSameKey(String(id.dropFirst(4)), id))
        XCTAssertNil(WireSignature.canonicalPublicKey(Data(repeating: 1, count: 91).base64EncodedString()))
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
        XCTAssertFalse(json.contains("DeviceName"))
    }

    func testHandshakeDeviceNameIsOptionalAndCapped() {
        let named = HandshakeMessage(ephemeralPublicKey: "E", identityPublicKey: "I", signature: "S", passphraseProof: nil, deviceName: "  Colour's iPhone  ")
        XCTAssertEqual(WireJSON.object(named.jsonString())?["DeviceName"] as? String, "Colour's iPhone", "trimmed, plain JSON string")
        XCTAssertEqual(HandshakeMessage.parse(named.jsonString())?.deviceName, "Colour's iPhone")
        // Older builds, and Windows' record with DeviceName = null.
        for json in [
            #"{"EphemeralPublicKey":"E","IdentityPublicKey":"I","Signature":"S"}"#,
            #"{"EphemeralPublicKey":"E","IdentityPublicKey":"I","Signature":"S","PassphraseProof":null,"DeviceName":null}"#,
            #"{"EphemeralPublicKey":"E","IdentityPublicKey":"I","Signature":"S","DeviceName":"   "}"#,
            #"{"EphemeralPublicKey":"E","IdentityPublicKey":"I","Signature":"S","DeviceName":42}"#,
        ] {
            let hs = HandshakeMessage.parse(json)
            XCTAssertNotNil(hs, json)
            XCTAssertNil(hs?.deviceName, json)
        }
        let long = String(repeating: "\u{E9}", count: 80)
        let parsed = HandshakeMessage.parse(WireJSON.string(["EphemeralPublicKey": "E", "IdentityPublicKey": "I", "Signature": "S", "DeviceName": long]))
        XCTAssertEqual(parsed?.deviceName, String(repeating: "\u{E9}", count: 64))
        let sent = HandshakeMessage(ephemeralPublicKey: "E", identityPublicKey: "I", signature: "S", passphraseProof: nil, deviceName: long)
        XCTAssertEqual(WireJSON.object(sent.jsonString())?["DeviceName"] as? String, String(repeating: "\u{E9}", count: 64))
    }

    func testPairingPayloadNameIsOptional() {
        XCTAssertEqual(PairingInfo.parse(#"{"PublicKey":"KEY","Address":"100.64.0.2","Name":" Desk PC "}"#),
                       PairingInfo(publicKey: "KEY", address: "100.64.0.2", name: "Desk PC"))
        XCTAssertNil(PairingInfo.parse(#"{"PublicKey":"KEY","Address":null,"Name":null}"#)?.name)
        XCTAssertNil(PairingInfo.parse(#"{"PublicKey":"KEY","Name":""}"#)?.name)
        XCTAssertEqual(WireJSON.object(PairingInfo(publicKey: "KEY", address: nil, name: "iPad").jsonString())?["Name"] as? String, "iPad")
        XCTAssertFalse(PairingInfo(publicKey: "KEY", address: "100.64.0.2").jsonString().contains("Name"))
        XCTAssertFalse(PairingInfo(publicKey: "KEY", address: nil, name: "  ").jsonString().contains("Name"))
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
        XCTAssertNil(d.name, "five-field beacons (older builds) have no name")
        // Senders always write all six fields, `-` for an unknown name.
        XCTAssertEqual(Beacon.build(tcpPort: 49000, deviceId: "K", proof: nil, address: "", pairing: false), "49000:K:-:-:-:-")
        XCTAssertEqual(Beacon.build(tcpPort: 49000, deviceId: "K", proof: "P", address: "100.1.2.3", pairing: true), "49000:K:P:100.1.2.3:1:-")
    }

    func testBeaconNameIsBase64InTheSixthField() {
        let built = Beacon.build(tcpPort: 49000, deviceId: "K", proof: nil, address: nil, pairing: false, name: "  Colour's PC  ")
        XCTAssertEqual(built, "49000:K:-:-:-:" + Data("Colour's PC".utf8).base64EncodedString(), "trimmed, then padded base64 of the UTF-8")
        XCTAssertEqual(Beacon.parse(built, senderIP: "10.0.0.2")?.name, "Colour's PC")

        // Non-ASCII round-trips, and base64 never adds a colon.
        let fancy = "Zo\u{EB}'s iPad \u{1F30D}"
        let b = Beacon.build(tcpPort: 49000, deviceId: "K", proof: "P", address: "100.1.2.3", pairing: true, name: fancy)
        XCTAssertEqual(b.split(separator: ":", omittingEmptySubsequences: false).count, 6)
        XCTAssertEqual(Beacon.parse(b, senderIP: "x"), Beacon(tcpPort: 49000, deviceId: "K", proof: "P", address: "100.1.2.3", pairing: true, name: fancy, senderIP: "x"))

        // Capped at 64 before encoding.
        let long = Beacon.build(tcpPort: 49000, deviceId: "K", proof: nil, address: nil, pairing: false, name: String(repeating: "n", count: 100))
        XCTAssertEqual(Beacon.parse(long, senderIP: "x")?.name, String(repeating: "n", count: 64))
        XCTAssertEqual(Beacon.build(tcpPort: 49000, deviceId: "K", proof: nil, address: nil, pairing: false, name: "   "), "49000:K:-:-:-:-")

        // Absent, `-`, empty, bad base64, bad UTF-8 or blank: unknown - and
        // the beacon itself still counts.
        let badUTF8 = Data([0xFF, 0xFE, 0x41]).base64EncodedString()
        let blank = Data("   ".utf8).base64EncodedString()
        for tail in ["", ":-", ":", ":%%%", ":QUJD", ":QUJD\n", ":\(badUTF8)", ":\(blank)"] {
            let parsed = Beacon.parse("49000:K:-:-:1" + tail, senderIP: "x")
            XCTAssertNotNil(parsed, tail)
            XCTAssertEqual(parsed?.pairing, true, tail)
            if tail.hasPrefix(":QUJD") {
                XCTAssertEqual(parsed?.name, "ABC")
            } else {
                XCTAssertNil(parsed?.name, tail)
            }
        }
    }

    func testNameEncodingMatchesTheOtherPlatformsByteForByte() {
        // Golden values from the Windows daemon's Discovery.EncodeName; the
        // Android and HarmonyOS encoders produce the same strings.
        let colour = "Colour's PC: \u{1F3A7} \u{FC}n\u{EF}c\u{F6}d\u{E9}"
        XCTAssertEqual(DeviceName.beaconField(colour), "Q29sb3VyJ3MgUEM6IPCfjqcgw7xuw69jw7Zkw6k=")
        XCTAssertEqual(DeviceName.fromBeaconField("Q29sb3VyJ3MgUEM6IPCfjqcgw7xuw69jw7Zkw6k="), colour)
        XCTAssertEqual(DeviceName.beaconField("\u{6211}\u{7684}\u{624B}\u{673A}"), "5oiR55qE5omL5py6")
        // 64 Unicode scalars: 64 emoji rather than 32 (UTF-16 units)...
        XCTAssertEqual(DeviceName.beaconField(String(repeating: "\u{1F600}", count: 70)), String(repeating: "8J+YgPCfmIDwn5iA", count: 21) + "8J+YgA==")
        // ...and 64 scalars rather than 64 Characters.
        XCTAssertEqual(DeviceName.beaconField(String(repeating: "e\u{301}", count: 40)), String(repeating: "ZcyB", count: 32))
        // System.Text.Json escapes everything outside ASCII, and the apostrophe.
        let hs = HandshakeMessage.parse(#"{"EphemeralPublicKey":"E","IdentityPublicKey":"I","Signature":"S","PassphraseProof":null,"DeviceName":"Colour\u0027s PC: \uD83C\uDFA7 \u00FCn\u00EFc\u00F6d\u00E9"}"#)
        XCTAssertEqual(hs?.deviceName, colour)
    }

    /// Peers choose their own names, so every way one arrives - beacon,
    /// handshake, pairing code, and what earlier builds stored - drops control
    /// characters and invisible bidi/format ones, then trims and caps.
    func testPeerNamesAreSanitisedOnEveryPath() throws {
        let hostile = "\u{FEFF} Desk\u{7}\n\u{7F}\u{85} PC\u{202E}\u{2066}\u{61C}\u{200B}\u{200D}\u{200E} \u{1F4BB}\u{2069}\u{202C}\t "
        let clean = "Desk PC \u{1F4BB}"
        XCTAssertEqual(DeviceName.sanitize(hostile), clean)
        XCTAssertEqual(Beacon.parse("49000:K:-:-:-:" + Data(hostile.utf8).base64EncodedString(), senderIP: "x")?.name, clean)
        XCTAssertEqual(HandshakeMessage.parse(WireJSON.string(["EphemeralPublicKey": "E", "IdentityPublicKey": "I", "Signature": "S", "DeviceName": hostile]))?.deviceName, clean)
        // Escaped, as System.Text.Json writes them.
        XCTAssertEqual(HandshakeMessage.parse(#"{"EphemeralPublicKey":"E","IdentityPublicKey":"I","Signature":"S","DeviceName":"\u202EDesk\u0007 PC\u200F"}"#)?.deviceName, "Desk PC")
        XCTAssertEqual(PairingInfo.parse(WireJSON.string(["PublicKey": "KEY", "Name": hostile]))?.name, clean)

        // Hidden characters alone are no name at all, and they go before the cap.
        XCTAssertNil(DeviceName.sanitize("\u{202E}\u{200B}\u{FEFF}\r\n"))
        XCTAssertEqual(DeviceName.sanitize(String(repeating: "\u{200B}", count: 100) + String(repeating: "n", count: 70)), String(repeating: "n", count: 64))
        // Everything visible stays: accents, combining marks, CJK, RTL letters, emoji.
        let fine = "Zo\u{EB}'s e\u{301} \u{6211}\u{7684} \u{5D0}\u{5D1} \u{1F1EC}\u{1F1E7}"
        XCTAssertEqual(DeviceName.sanitize(fine), fine)

        // A name an earlier build stored as it came is cleaned when read back.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trust-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [["publicKey": "A", "name": hostile]]).write(to: dir.appendingPathComponent("trusted_devices.json"))
        XCTAssertEqual(TrustStore(directory: dir).device("A")?.name, clean)
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

    /// Received and shared files are created under these names, and APFS
    /// takes at most 255 bytes of UTF-8: 240 bytes and 120 UTF-16 units, as
    /// on Android, with the extension kept, no character split, and never
    /// an empty name.
    func testFileNamesAreCappedInUTF8BytesAndNeverEmpty() {
        for blank in ["", " ", "...", ". .", " .. "] {
            XCTAssertEqual(FileStore.sanitize(blank), "file", blank.debugDescription)
        }
        XCTAssertFalse(FileStore.sanitize("\u{0}\n").isEmpty)
        XCTAssertEqual(FileStore.sanitize("report.pdf"), "report.pdf")
        XCTAssertEqual(FileStore.sanitize(".hidden. .txt"), "hidden. .txt")
        XCTAssertEqual(FileStore.sanitize("invoice\u{202E}txt.exe"), "invoice_txt.exe")

        // 200 CJK characters are 600 bytes: cut by bytes, not characters.
        let cjk = FileStore.sanitize(String(repeating: "文", count: 200) + ".txt")
        XCTAssertEqual(cjk, String(repeating: "文", count: 78) + ".txt")
        XCTAssertLessThanOrEqual(cjk.utf8.count, 240)

        // A four-byte scalar is two UTF-16 units: here 120 units cut first.
        let emoji = FileStore.sanitize(String(repeating: "😀", count: 100) + ".png")
        XCTAssertEqual(emoji, String(repeating: "😀", count: 58) + ".png")

        // A decomposed "é" (e + U+0301) never loses its accent.
        let accents = FileStore.sanitize(String(repeating: "e\u{301}", count: 150) + ".md")
        XCTAssertEqual(accents, String(repeating: "e\u{301}", count: 58) + ".md")
        XCTAssertEqual(accents.unicodeScalars.filter { $0 == "e" }.count, 58)
        XCTAssertEqual(accents.unicodeScalars.filter { $0 == "\u{301}" }.count, 58)

        // One character bigger than the whole cap leaves no stem: the fallback's.
        XCTAssertEqual(FileStore.sanitize("e" + String(repeating: "\u{301}", count: 300) + ".txt"), "file.txt")

        // An over-long extension isn't kept, and no stem ends in a dot or space.
        XCTAssertEqual(FileStore.sanitize(String(repeating: "a", count: 300) + "." + String(repeating: "x", count: 30)),
                       String(repeating: "a", count: 120))
        XCTAssertEqual(FileStore.sanitize(String(repeating: "a", count: 115) + " . . . . .jpg"),
                       String(repeating: "a", count: 115) + ".jpg")

        // The name that goes on the wire keeps within the caps too.
        let wire = SyncEngine.windowsSafeName(String(repeating: "文", count: 200) + ".txt")
        XCTAssertLessThanOrEqual(wire.utf8.count, 240)
        XCTAssertTrue(wire.hasSuffix(".txt"))
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

    func testDeletedStoreKeysBySignatureCapsAndPersists() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deleted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func entry(_ i: Int) -> ClipboardEntry {
            ClipboardEntry(content: "\(i)", type: "text", deviceId: "d", timestamp: "2026-09-28T10:00:00.0000001Z", signature: "sig\(i)")
        }
        // Every platform keys the same way: the signature as stored, else
        // DeviceId|Type|Timestamp|sha256(Content) for an unsigned entry.
        XCTAssertEqual(DeletedStore.key(of: entry(7)), "sig7")
        let unsigned = ClipboardEntry(content: "hi", type: "text", deviceId: "d", timestamp: "2026-09-28T10:00:00.0000001Z")
        XCTAssertEqual(DeletedStore.key(of: unsigned),
                       "d|text|2026-09-28T10:00:00.0000001Z|8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4")

        let store = DeletedStore(directory: dir)
        XCTAssertFalse(store.contains(entry(0)))
        store.add((0..<DeletedStore.cap).map(entry))
        store.add([entry(0)]) // deleted again: now the newest
        store.add([entry(DeletedStore.cap)]) // one over the cap: the oldest goes
        XCTAssertEqual(store.count, DeletedStore.cap)
        XCTAssertTrue(store.contains(entry(0)))
        XCTAssertFalse(store.contains(entry(1)))
        XCTAssertTrue(store.contains(entry(DeletedStore.cap)))

        // Persisted, and shared with the other process (the Share extension).
        let other = DeletedStore(directory: dir)
        XCTAssertEqual(other.removingDeleted([entry(1), entry(2), unsigned]).map(\.content), ["1", "hi"])
        other.add([unsigned])
        XCTAssertTrue(store.contains(unsigned), "picked up the other process's write")
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

    // MARK: device names & list order

    func testTrustStoreKeepsNamesAndAddressesIndependent() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trust-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TrustStore(directory: dir)
        store.trust("A", address: "192.168.1.5", name: "Desk PC")
        store.trust("A", address: "192.168.1.6")
        XCTAssertEqual(store.device("A"), TrustedDevice(publicKey: "A", address: "192.168.1.6", name: "Desk PC"), "an address update keeps the name")
        store.updateName("A", name: nil)
        store.updateName("A", name: "")
        store.trust("A", address: nil, name: nil)
        XCTAssertEqual(store.device("A")?.name, "Desk PC", "an unknown name never erases a known one")
        store.clearAddress("A")
        XCTAssertEqual(store.device("A"), TrustedDevice(publicKey: "A", address: nil, name: "Desk PC"), "clearing a stale address keeps the name")
        store.updateName("A", name: "Studio PC")
        XCTAssertNil(store.device("A")?.address, "a name update doesn't touch the address")
        store.trust("A", address: "10.0.0.2")
        store.updateName("Stranger", name: "Nope")
        XCTAssertFalse(store.isTrusted("Stranger"), "a name never adds trust")
        XCTAssertEqual(TrustStore(directory: dir).all, [TrustedDevice(publicKey: "A", address: "10.0.0.2", name: "Studio PC")], "persisted")
    }

    /// Every P-256 SPKI starts with the same 36 base64 characters, so ids are
    /// shown by the first 4 bytes of SHA-256 of their UTF-8 - byte for byte
    /// what the other ports show.
    func testDeviceFingerprintIsTheSameEverywhere() {
        XCTAssertEqual(DeviceLabel.fingerprint("abc"), "BA78·16BF")
        XCTAssertEqual(DeviceLabel.short("abc"), "Device BA78·16BF")
        let row = DeviceRow(deviceId: "abc", name: nil, trusted: false, connected: false, addresses: [], pairing: false, lastSeen: nil, nearby: false)
        XCTAssertEqual(row.shortId, "Device BA78·16BF")
        let a = SoftwareIdentity().publicKeyBase64
        let b = SoftwareIdentity().publicKeyBase64
        XCTAssertEqual(a.prefix(36), b.prefix(36), "why a prefix can't tell devices apart")
        XCTAssertNotEqual(DeviceLabel.fingerprint(a), DeviceLabel.fingerprint(b))
    }

    func testDeviceRowsSortByGroupThenNameThenIdOnly() {
        func row(_ id: String, _ name: String?, trusted: Bool, connected: Bool = false, lastSeen: Date? = nil) -> DeviceRow {
            DeviceRow(deviceId: id, name: name, trusted: trusted, connected: connected, addresses: [], pairing: false, lastSeen: lastSeen, nearby: connected)
        }
        let rows = [
            row("id5", nil, trusted: false, lastSeen: Date()),
            row("id4", "zebra", trusted: false),
            row("id3", nil, trusted: true, connected: true, lastSeen: Date()),
            row("id2", "Beta", trusted: true),
            row("id1", "alpha", trusted: true, lastSeen: .distantPast),
            row("id0", nil, trusted: true),
            row("id9", "beta", trusted: true),
        ]
        let expected = ["id1", "id2", "id9", "id0", "id3", "id4", "id5"]
        XCTAssertEqual(rows.sorted(by: DeviceRow.displayOrder).map(\.deviceId), expected,
                       "paired first; named (case-insensitive) before unnamed; ties and unnamed by id; never by connection or last seen")
        XCTAssertEqual(rows.reversed().sorted(by: DeviceRow.displayOrder).map(\.deviceId), expected, "insertion order doesn't matter")
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
