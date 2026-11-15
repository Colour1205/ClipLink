import XCTest
@testable import ClipLinkCore

/// Content prints (design/sync-dedupe-spec.md): the shared test vectors every
/// platform checks, what a capture is held back for, and one card per content
/// in the Synced list. All local: nothing here is on the wire.
final class ContentPrintTests: XCTestCase {

    private let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    private let lines = "683376e290829b482c2655745caffa7a1dccfa10afaa62dac2b42dd6c68d0f83"

    // MARK: - norm and the text print (rule 5 vectors)

    func testNormChangesLineEndingsAndOneTrailingNewlineOnly() {
        XCTAssertEqual(ContentPrint.norm("abc"), "abc")
        XCTAssertEqual(ContentPrint.norm("abc\n"), "abc")
        XCTAssertEqual(ContentPrint.norm("abc\r\n"), "abc")
        XCTAssertEqual(ContentPrint.norm("abc\n\n"), "abc\n", "one trailing newline only")
        XCTAssertEqual(ContentPrint.norm("line1\r\nline2"), "line1\nline2")
        XCTAssertEqual(ContentPrint.norm("line1\rline2\r"), "line1\nline2")
        XCTAssertEqual(ContentPrint.norm("  abc  "), "  abc  ", "spaces stay")
        XCTAssertEqual(ContentPrint.norm("日本語\r\n"), "日本語")
        XCTAssertEqual(ContentPrint.norm("a\r\n\r\n"), "a\n")
        XCTAssertEqual(ContentPrint.norm("\n"), "")
        XCTAssertEqual(ContentPrint.norm("\r\r\n"), "\n", "a lone CR, then a CRLF")
    }

    func testTextPrintsMatchTheSharedVectors() {
        XCTAssertEqual(ContentPrint.text("abc"), "t:" + abc)
        XCTAssertEqual(ContentPrint.text("abc\n"), "t:" + abc)
        XCTAssertEqual(ContentPrint.text("abc\r\n"), "t:" + abc)
        XCTAssertEqual(ContentPrint.text("abc\n\n"), "t:edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb")
        XCTAssertEqual(ContentPrint.text("line1\r\nline2"), "t:" + lines)
        XCTAssertEqual(ContentPrint.text("line1\rline2\r"), "t:" + lines)
        XCTAssertEqual(ContentPrint.text("  abc  "), "t:e1df0bfff7ba8ed81085b91ad7dde5d31777855835b80db6d99b56ef9f3aaa6b")
        XCTAssertEqual(ContentPrint.text("日本語\r\n"), "t:77710aedc74ecfa33685e33a6c7df5cc83004da1bdcef7fb280f5c2b2e97e0a5")
        XCTAssertEqual(ContentPrint.text("a\r\n\r\n"), "t:87428fc522803d31065e7bce3cf03fe475096631e5e07bbd7a0fde60c4cf25c7")
        XCTAssertEqual(ContentPrint.text("\n"), "t:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    // MARK: - contentKey

    private func entry(_ content: String, _ type: String) -> ClipboardEntry {
        ClipboardEntry(content: content, type: type, deviceId: "device", timestamp: "2026-10-13T14:20:05.1230000Z", signature: "sig")
    }

    func testTheKeyOfAnEntryIsItsContentsPrint() {
        XCTAssertEqual(ContentPrint.key(of: entry("abc\r\n", Wire.EntryType.text)), "t:" + abc)

        // A picture: the decoded bytes, not the base64.
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(ContentPrint.key(of: entry(png.base64EncodedString(), Wire.EntryType.image)),
                       "i:0f4636c78f65d3639ece5a064b5ae753e3408614a14fb18ab4d7540d2c248543")
        XCTAssertEqual(ContentPrint.image(png), ContentPrint.key(of: entry("iVBORw==", Wire.EntryType.image)))

        // A file: its hash in lower case, whoever spelt it.
        let upper = String(repeating: "AB", count: 32)
        let lower = String(repeating: "ab", count: 32)
        let fromIOS = FilePayload(fileName: "a.bin", fileHash: upper, fileSize: 1).jsonString()
        let fromAndroid = FilePayload(fileName: "b.bin", fileHash: lower, fileSize: 1).jsonString()
        XCTAssertEqual(ContentPrint.key(of: entry(fromIOS, Wire.EntryType.file)), "f:" + lower)
        XCTAssertEqual(ContentPrint.key(of: entry(fromAndroid, Wire.EntryType.file)), "f:" + lower)
        XCTAssertEqual(ContentPrint.file(hash: upper), "f:" + lower)
        // The empty file's hash never collides with the empty text: the kind differs.
        XCTAssertNotEqual(ContentPrint.file(hash: "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"), ContentPrint.text(""))
    }

    func testAKeyThatCannotBeWorkedOutIsNil() {
        XCTAssertNil(ContentPrint.key(of: entry("not base64!", Wire.EntryType.image)))
        XCTAssertNil(ContentPrint.key(of: entry("{not json", Wire.EntryType.file)))
        XCTAssertNil(ContentPrint.key(of: entry(#"{"FileName":"a","FileHash":"abc","FileSize":1}"#, Wire.EntryType.file)), "not 64 hex digits")
        XCTAssertNil(ContentPrint.key(of: entry("x", "unknown")))
        XCTAssertNil(ContentPrint.file(hash: "xyz"))
    }

    // MARK: - newest(n)

    func testNewestTakesTheLatestAndEveryOneTiedWithTheLast() {
        func at(_ seconds: TimeInterval, _ name: String) -> ClipboardEntry {
            ClipboardEntry(content: name, type: Wire.EntryType.text, deviceId: "d", timestamp: DotNetTimestamp.now(Date(timeIntervalSince1970: seconds)))
        }
        let list = [at(10, "a"), at(30, "b"), at(20, "c"), at(30, "d")]
        XCTAssertEqual(ContentPrint.newest(list, count: 1, timestamp: { $0.timestamp }).map(\.content), ["b", "d"], "two at the same moment")
        XCTAssertEqual(ContentPrint.newest(list, count: 3, timestamp: { $0.timestamp }).map(\.content), ["b", "d", "c"])
        XCTAssertEqual(ContentPrint.newest(list, count: 9, timestamp: { $0.timestamp }).count, 4)
        XCTAssertTrue(ContentPrint.newest(list, count: 0, timestamp: { $0.timestamp }).isEmpty)
        XCTAssertTrue(ContentPrint.newest([ClipboardEntry](), count: 1, timestamp: { $0.timestamp }).isEmpty)
    }

    // MARK: - LastWrite and its migration

    func testLastWriteRoundTripsAndComesFromTheOldSingleHash() {
        let record = LastWrite(prints: ["t:" + abc, "i:00"])
        XCTAssertEqual(LastWrite.load(json: record.jsonString(), legacyHash: "ignored"), record, "the new record wins")
        XCTAssertEqual(LastWrite.load(json: nil, legacyHash: "ABC123"), LastWrite(prints: ["x:abc123"]))
        XCTAssertEqual(LastWrite.load(json: nil, legacyHash: nil), LastWrite())
        XCTAssertEqual(LastWrite.load(json: "garbage", legacyHash: ""), LastWrite())
    }

    func testALegacyPrintMatchesTheRawHashOfACapture() {
        // Older builds stored sha256 of the exact text.
        let crlf = "abc\r\n"
        let legacy = LastWrite.load(json: nil, legacyHash: ContentHash.sha256Hex(Data(crlf.utf8)))
        XCTAssertTrue(legacy.contains(.text(crlf)))
        XCTAssertFalse(legacy.contains(.text("abc")), "the raw hash of other text")
        // A file's old entry was its lowercased hash.
        let hash = String(repeating: "CD", count: 32)
        XCTAssertTrue(LastWrite.load(json: nil, legacyHash: hash.lowercased()).contains(.file(hash: hash)))
        // And the new prints match by content.
        XCTAssertTrue(LastWrite(prints: [ContentPrint.text("abc")]).contains(.text(crlf)))
    }

    // MARK: - Classifying a capture (rule 1.3)

    private let a = CapturePrint.text("A")
    private let b = CapturePrint.text("B")

    func testTheOwnWriteCheckBeforeReading() {
        let wrote = LastWrite(prints: [a.print])
        XCTAssertEqual(CaptureCheck.ownWrite(mode: .auto, lastWrite: wrote, historyKeys: []), .already, "never read back on its own")
        XCTAssertEqual(CaptureCheck.ownWrite(mode: .manual, lastWrite: wrote, historyKeys: [a.print]), .already, "Paste: already synced")
        XCTAssertNil(CaptureCheck.ownWrite(mode: .manual, lastWrite: wrote, historyKeys: [b.print]), "deleted since: Paste reads and sends it again")
    }

    func testWhatClipLinkLastWroteOrSentIsHeldBack() {
        let wrote = LastWrite(prints: [a.print])
        XCTAssertEqual(CaptureCheck.classify(a, mode: .auto, lastWrite: wrote, historyKeys: [], newestKeys: []), .already)
        XCTAssertEqual(CaptureCheck.classify(a, mode: .manual, lastWrite: wrote, historyKeys: [a.print], newestKeys: []), .already)
        XCTAssertEqual(CaptureCheck.classify(a, mode: .manual, lastWrite: wrote, historyKeys: [], newestKeys: []), .new, "deleted, then pasted: a deliberate re-send")
        XCTAssertEqual(CaptureCheck.classify(b, mode: .auto, lastWrite: wrote, historyKeys: [], newestKeys: []), .new)
    }

    func testWhatTheNewestEntryAlreadyIsIsHeldBack() {
        // Received but not applied (auto-apply off, or held while away), shared and
        // also copied, or carried over by Universal Clipboard once it is here.
        XCTAssertEqual(CaptureCheck.classify(a, mode: .auto, lastWrite: LastWrite(), historyKeys: [a.print], newestKeys: [a.print]), .already)
        XCTAssertEqual(CaptureCheck.classify(a, mode: .manual, lastWrite: LastWrite(), historyKeys: [a.print], newestKeys: [a.print]), .already)
        XCTAssertEqual(CaptureCheck.classify(.text("A\r\n"), mode: .auto, lastWrite: LastWrite(), historyKeys: [a.print], newestKeys: [a.print]), .already, "line endings aside")
    }

    func testReCopyingAnOlderItemGoesOut() {
        // A, then B was copied (or received): A again is a deliberate re-copy.
        let afterB = LastWrite(prints: [b.print])
        XCTAssertEqual(CaptureCheck.classify(a, mode: .auto, lastWrite: afterB, historyKeys: [a.print, b.print], newestKeys: [b.print]), .new)
        XCTAssertEqual(CaptureCheck.classify(a, mode: .manual, lastWrite: afterB, historyKeys: [a.print, b.print], newestKeys: [b.print]), .new)
    }

    func testAPictureIsAlsoTheFileWithItsBytes() {
        // A photo file just shared (or received), copied as well: read off the
        // clipboard as JPEG and re-encoded, it still goes by the original bytes.
        let jpeg = Data([0xFF, 0xD8, 0xFF])
        let fileKey = "f:" + ContentHash.sha256Hex(jpeg)
        var reencoded = CapturePrint.image(Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(CaptureCheck.classify(reencoded, mode: .auto, lastWrite: LastWrite(), historyKeys: [fileKey], newestKeys: [fileKey]), .new)
        reencoded.alternates.insert(fileKey)
        XCTAssertEqual(CaptureCheck.classify(reencoded, mode: .auto, lastWrite: LastWrite(), historyKeys: [fileKey], newestKeys: [fileKey]), .already)
        XCTAssertTrue(LastWrite(prints: reencoded.all).contains(reencoded))

        // A PNG is the PNG file too.
        let png = CapturePrint.image(jpeg)
        XCTAssertEqual(png.all, ["i:" + ContentHash.sha256Hex(jpeg), fileKey])
    }

    func testALegacyRecordStillHoldsBackTheSameClipboard() {
        let legacy = LastWrite.load(json: nil, legacyHash: ContentHash.sha256Hex(Data("A".utf8)))
        XCTAssertEqual(CaptureCheck.classify(a, mode: .auto, lastWrite: legacy, historyKeys: [], newestKeys: []), .already)
    }

    // MARK: - One card per content (rule 2)

    private func item(_ id: String, key: String?) -> SyncedItem {
        SyncedItem(
            id: id,
            entry: ClipboardEntry(content: id, type: Wire.EntryType.text, deviceId: "device", timestamp: "2026-10-13T14:20:05.1230000Z", signature: id),
            isOwn: false,
            kind: .text,
            filePayload: nil,
            fileAvailable: true,
            date: nil,
            sourceLabel: "device",
            contentKey: key
        )
    }

    func testTheTopmostTwinIsShownAndAnItemWithNoKeyIsNobodysTwin() {
        // A plain timeline (after a restart): the newest wins.
        let list = [item("new", key: "t:x"), item("other", key: "t:y"), item("old", key: "t:x"), item("n1", key: nil), item("n2", key: nil)]
        XCTAssertEqual(StackPlanner.rows(items: list, groups: []).map(\.id), ["new", "other", "n1", "n2"])
    }

    func testALiveTwinOnTopHidesTheOlderCard() {
        // By the clock "old" is newer, but the live item arrived last and is on top.
        let list = [item("old", key: "t:x"), item("live", key: "t:x"), item("other", key: "t:y")]
        let groups = [BatchGroup(id: "b", memberIDs: ["live"])]
        XCTAssertEqual(StackPlanner.rows(items: list, groups: groups).map(\.id), ["live", "other"])
    }

    func testAStackIsCountedFromTheMembersLeftAndItsFrontCanGiveWay() {
        let list = [item("live", key: "t:c"), item("c", key: "t:c"), item("m1", key: "t:m1"), item("m2", key: "t:m2")]
        let stack = BatchGroup(id: "s", memberIDs: ["c", "m1", "m2"], frontID: "c")
        let live = BatchGroup(id: "l", memberIDs: ["live"])
        // The live twin of the front: the next member leads, two are left.
        var rows = StackPlanner.rows(items: list, groups: [stack, live])
        XCTAssertEqual(rows.map(\.id), ["live", "m1"])
        XCTAssertEqual(rows[1].stack?.memberIDs, ["m1", "m2"])

        // Down to one: a plain card.
        let twins = [item("live", key: "t:m1"), item("c", key: "t:m1"), item("m1", key: "t:m1"), item("m2", key: "t:m2")]
        rows = StackPlanner.rows(items: twins, groups: [stack, live])
        XCTAssertEqual(rows.map(\.id), ["live", "m2"])
        XCTAssertNil(rows[1].stack, "a stack left with one member is a card")

        // A provisional stack keeps its announced size.
        let provisional = BatchGroup(id: "p", memberIDs: ["c"], expectedSize: 5, frontID: "c")
        rows = StackPlanner.rows(items: [item("c", key: "t:c")], groups: [provisional])
        XCTAssertEqual(rows.first?.stack?.hiddenCount, 4)
    }
}
