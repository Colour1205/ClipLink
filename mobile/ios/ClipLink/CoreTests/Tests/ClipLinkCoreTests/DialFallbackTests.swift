import XCTest
@testable import ClipLinkCore

/// When a trusted device that should have dialled this one is dialled from here instead.
final class DialFallbackTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testADeviceIsGivenTimeToDialFirst() {
        var fallback = DialFallback()
        XCTAssertFalse(fallback.due("A", now: start))
        XCTAssertFalse(fallback.due("A", now: start.addingTimeInterval(DialFallback.wait - 1)))
        XCTAssertTrue(fallback.due("A", now: start.addingTimeInterval(DialFallback.wait)))
    }

    func testAfterADialItIsLeftAloneForAWhileThenTriedAgain() {
        var fallback = DialFallback()
        _ = fallback.due("A", now: start)
        let first = start.addingTimeInterval(DialFallback.wait)
        XCTAssertTrue(fallback.due("A", now: first))
        XCTAssertFalse(fallback.due("A", now: first.addingTimeInterval(DialFallback.every - 1)))
        XCTAssertTrue(fallback.due("A", now: first.addingTimeInterval(DialFallback.every)))
    }

    func testConnectingStartsTheCountAgainAndDevicesAreCountedSeparately() {
        var fallback = DialFallback()
        _ = fallback.due("A", now: start)
        _ = fallback.due("B", now: start)
        let later = start.addingTimeInterval(DialFallback.wait)
        XCTAssertTrue(fallback.due("A", now: later))
        fallback.connected("A")
        XCTAssertFalse(fallback.due("A", now: later))
        XCTAssertTrue(fallback.due("B", now: later))
    }
}
