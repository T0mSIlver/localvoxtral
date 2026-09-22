import Foundation
import XCTest

@testable import localvoxtral

/// The bounded ask-until-it-is-there schedule behind "Open the window at
/// launch" (#449). No real clock: the sleep is a closure that records what it
/// was asked to wait for and returns at once.
@MainActor
final class AppWindowOpenerTests: XCTestCase {
    @MainActor
    private final class Fake {
        var shows = 0
        var waits: [Duration] = []
        /// The attempt whose ask puts the window on screen. `Int.max` never.
        var appearsOnAttempt = 1
        /// Whether the window is up before any of this runs.
        var isAlreadyOnScreen = false

        var isOnScreen: Bool { isAlreadyOnScreen || shows >= appearsOnAttempt }

        func opener() -> AppWindowOpener {
            AppWindowOpener(
                show: { self.shows += 1 },
                isOnScreen: { self.isOnScreen },
                sleepFor: { self.waits.append($0) }
            )
        }
    }

    func testTheFirstAskIsUsuallyEnough() async {
        let fake = Fake()

        let attempt = await fake.opener().open()

        XCTAssertEqual(attempt, 1)
        XCTAssertEqual(fake.shows, 1)
        XCTAssertTrue(fake.waits.isEmpty)
    }

    /// The case this type exists for: the scene ignores the action until it is
    /// ready, so the send has to be repeated.
    func testItKeepsAskingUntilTheWindowIsThere() async {
        let fake = Fake()
        fake.appearsOnAttempt = 4

        let attempt = await fake.opener().open()

        XCTAssertEqual(attempt, 4)
        XCTAssertEqual(fake.shows, 4)
        // One wait per ask that did not land — the ask that works returns
        // without one.
        XCTAssertEqual(fake.waits, Array(repeating: AppWindowOpener.interval, count: 3))
    }

    func testItGivesUpRatherThanAskingForever() async {
        let fake = Fake()
        fake.appearsOnAttempt = .max

        let attempt = await fake.opener().open()

        XCTAssertNil(attempt)
        XCTAssertEqual(fake.shows, AppWindowOpener.attemptLimit)
    }

    /// A window already on screen is still asked for once — that ask is what
    /// brings it forward when the menu bar item's History is pressed while it
    /// sits behind another app.
    func testAWindowAlreadyOnScreenIsStillAskedForOnce() async {
        let fake = Fake()
        fake.isAlreadyOnScreen = true

        let attempt = await fake.opener().open()

        XCTAssertEqual(attempt, 1)
        XCTAssertEqual(fake.shows, 1)
        XCTAssertTrue(fake.waits.isEmpty)
    }
}
