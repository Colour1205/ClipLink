import XCTest
@testable import ClipLinkCore

/// The pairing QR code is a link to the website's /pair page with the pairing
/// info after the # (see PairingLink). The vector below was made by the Windows
/// app's PairingLink.cs; every platform has to read it, and make it the same way.
final class PairingLinkTests: XCTestCase {

    private let json = #"{"PublicKey":"MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEexample+/key==","Address":"100.101.102.103","Name":"我的电脑 PC"}"#

    private let windowsLink =
        "https://cliplink.uaena.io/pair/#eyJQdWJsaWNLZXkiOiJNRmt3RXdZSEtvWkl6ajBDQVFZSUtvWkl6ajBEQVFjRFFnQUVleGFtcGxlKy9rZXk9PSIsIkFkZHJlc3MiOiIxMDAuMTAxLjEwMi4xMDMiLCJOYW1lIjoi5oiR55qE55S16ISRIFBDIn0"

    func testMakesTheSameLinkTheWindowsAppDoes() {
        XCTAssertEqual(PairingLink.wrap(json), windowsLink)
    }

    func testReadsTheLinkTheWindowsAppMakes() {
        XCTAssertEqual(PairingLink.unwrap(windowsLink), json)
    }

    func testALinkAndItsInfoRoundTripNonASCIINamesIncluded() {
        let info = #"{"PublicKey":"K","Name":"iPhone 我的"}"#
        XCTAssertEqual(PairingLink.unwrap(PairingLink.wrap(info)), info)
    }

    func testHttpUpperCaseAndAMissingSlashAreStillTheLink() {
        let info = String(windowsLink.dropFirst(PairingLink.prefix.count))
        XCTAssertEqual(PairingLink.unwrap("HTTP://CLIPLINK.UAENA.IO/pair#\(info)"), json)
        XCTAssertEqual(PairingLink.unwrap("  https://cliplink.uaena.io/pair/#\(info)\n"), json)
        // Padding is not needed, but not wrong either (this info needs one =).
        XCTAssertEqual(PairingLink.unwrap("https://cliplink.uaena.io/pair/#\(info)="), json)
    }

    func testAnythingElseIsLeftAsItWas() {
        for text in [
            json,
            "192.168.1.20",
            "192.168.1.20:49000",
            "https://example.com/pair/#abc",
            "https://cliplink.uaena.io/",
            "https://cliplink.uaena.io/pair/",
            "https://cliplink.uaena.io/pair/#!!!",
            "https://cliplink.uaena.io/pair/#_w", // base64 of a lone 0xFF: not UTF-8
        ] {
            XCTAssertEqual(PairingLink.unwrap(text), text, text)
        }
    }

    func testIsLinkTellsAPairingLinkFromOtherText() {
        XCTAssertTrue(PairingLink.isLink(windowsLink))
        XCTAssertTrue(PairingLink.isLink("https://cliplink.uaena.io/pair#abc"))
        XCTAssertFalse(PairingLink.isLink("https://cliplink.uaena.io/"))
        XCTAssertFalse(PairingLink.isLink("https://cliplink.uaena.io/download#abc"))
        XCTAssertFalse(PairingLink.isLink("https://evil.example/pair/#abc"))
        XCTAssertFalse(PairingLink.isLink(json))
    }

    func testThePairingInfoParserTakesTheLinkAndTheBareJSONAlike() throws {
        let fromLink = try XCTUnwrap(PairingInfo.parse(windowsLink))
        XCTAssertEqual(fromLink.publicKey, "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEexample+/key==")
        XCTAssertEqual(fromLink.address, "100.101.102.103")
        XCTAssertEqual(fromLink.name, "我的电脑 PC")
        XCTAssertEqual(PairingInfo.parse(json), fromLink)
        XCTAssertNil(PairingInfo.parse("https://cliplink.uaena.io/pair/#!!!"))
    }

    func testACodeMadeByThisAppReadsBackThroughTheLink() {
        let made = PairingInfo(publicKey: "KEY", address: "100.64.0.1", name: "iPhone").jsonString()
        XCTAssertEqual(PairingInfo.parse(PairingLink.wrap(made)), PairingInfo.parse(made))
    }
}
