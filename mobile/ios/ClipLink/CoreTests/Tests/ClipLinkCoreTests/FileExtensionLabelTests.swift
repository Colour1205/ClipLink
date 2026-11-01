import XCTest
@testable import ClipLinkCore

/// The extension a file card's footer shows on its right, the same on every
/// phone app: upper-case, no dot, nothing when there is none, it is too
/// long to be a kind, or it holds anything but letters and digits.
final class FileExtensionLabelTests: XCTestCase {

    func testTheExtensionIsUpperCaseWithoutTheDot() {
        XCTAssertEqual(SyncedItem.extensionLabel(forFileName: "report.pdf"), "PDF")
        XCTAssertEqual(SyncedItem.extensionLabel(forFileName: "IMG_0042.jpg"), "JPG")
        XCTAssertEqual(SyncedItem.extensionLabel(forFileName: "mix.M3u"), "M3U")
    }

    func testOnlyTheLastExtensionCounts() {
        XCTAssertEqual(SyncedItem.extensionLabel(forFileName: "backup.tar.gz"), "GZ")
        XCTAssertEqual(SyncedItem.extensionLabel(forFileName: ".bashrc"), "BASHRC")
    }

    func testAnExtensionIsOnlyLettersAndDigits() {
        XCTAssertNil(SyncedItem.extensionLabel(forFileName: "v1.2 beta"))
        XCTAssertNil(SyncedItem.extensionLabel(forFileName: "draft.v-2"))
        XCTAssertNil(SyncedItem.extensionLabel(forFileName: "track.mp\u{00B3}"))
    }

    func testNoExtensionShowsNothing() {
        XCTAssertNil(SyncedItem.extensionLabel(forFileName: "README"))
        XCTAssertNil(SyncedItem.extensionLabel(forFileName: "notes."))
        XCTAssertNil(SyncedItem.extensionLabel(forFileName: ""))
    }

    func testAnExtensionLongerThanEightIsPartOfTheName() {
        XCTAssertEqual(SyncedItem.extensionLabel(forFileName: "data.download"), "DOWNLOAD")
        XCTAssertNil(SyncedItem.extensionLabel(forFileName: "Meeting 10.30 tomorrow"))
    }

    func testOnlyFilesHaveOne() {
        let file = FilePayload(fileName: "photo.JPEG", fileHash: String(repeating: "a", count: 64), fileSize: 1)
        XCTAssertEqual(item(.file, content: file.jsonString(), payload: file).fileExtensionLabel, "JPEG")
        XCTAssertNil(item(.text, content: "see notes.txt").fileExtensionLabel)
        XCTAssertNil(item(.link, content: "https://example.com/a.pdf").fileExtensionLabel)
        XCTAssertNil(item(.image, content: "").fileExtensionLabel)
    }

    private func item(_ kind: SyncedItem.Kind, content: String, payload: FilePayload? = nil) -> SyncedItem {
        SyncedItem(
            id: content,
            entry: ClipboardEntry(content: content, type: Wire.EntryType.text, deviceId: "device", timestamp: "2026-10-13T14:20:05.1230000Z", signature: content),
            isOwn: false,
            kind: kind,
            filePayload: payload,
            fileAvailable: true,
            date: nil,
            sourceLabel: "device"
        )
    }
}
