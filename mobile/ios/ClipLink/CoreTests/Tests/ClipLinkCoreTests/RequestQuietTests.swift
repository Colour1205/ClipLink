import XCTest
@testable import ClipLinkCore

/// Which devices' pairing requests are held back, for how long, and what lifts it.
final class RequestQuietTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testAnUnknownDeviceIsNotQuiet() {
        var quiet = RequestQuiet()
        XCTAssertEqual(quiet.state(of: "A", now: start), .notQuiet)
    }

    func testAnIgnoredDeviceIsQuietForAWhileThenNot() {
        var quiet = RequestQuiet()
        quiet.quiet("A", for: RequestQuiet.afterIgnored, now: start)
        XCTAssertEqual(quiet.state(of: "A", now: start), .ignored)
        XCTAssertEqual(quiet.state(of: "B", now: start), .notQuiet)
        XCTAssertEqual(quiet.state(of: "A", now: start.addingTimeInterval(RequestQuiet.afterIgnored - 1)), .ignored)
        XCTAssertEqual(quiet.state(of: "A", now: start.addingTimeInterval(RequestQuiet.afterIgnored)), .notQuiet)
    }

    func testARemovedDeviceIsQuietLongerAndSaysItWasRemoved() {
        var quiet = RequestQuiet()
        quiet.quiet("A", for: RequestQuiet.afterRemoved, removed: true, now: start)
        XCTAssertEqual(quiet.state(of: "A", now: start.addingTimeInterval(RequestQuiet.afterIgnored + 1)), .removed)
        XCTAssertEqual(quiet.state(of: "A", now: start.addingTimeInterval(RequestQuiet.afterRemoved)), .notQuiet)
    }

    func testALaterReasonReplacesTheEarlierOne() {
        var quiet = RequestQuiet()
        quiet.quiet("A", for: RequestQuiet.afterIgnored, now: start)
        quiet.quiet("A", for: RequestQuiet.afterRemoved, removed: true, now: start)
        XCTAssertEqual(quiet.state(of: "A", now: start), .removed)
    }

    func testReleaseLiftsOneDeviceAndClearLiftsAll() {
        var quiet = RequestQuiet()
        quiet.quiet("A", for: RequestQuiet.afterIgnored, now: start)
        quiet.quiet("B", for: RequestQuiet.afterIgnored, now: start)
        quiet.release("A")
        XCTAssertEqual(quiet.state(of: "A", now: start), .notQuiet)
        XCTAssertEqual(quiet.state(of: "B", now: start), .ignored)
        quiet.clear()
        XCTAssertEqual(quiet.state(of: "B", now: start), .notQuiet)
    }
}
