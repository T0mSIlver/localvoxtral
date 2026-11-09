import SpeechEngineText
import XCTest

final class SilentTailStopTests: XCTestCase {
    /// The 480 ms default: 6 delay tokens, the 17-token offline pad.
    func testTheDefaultDelayMatchesTheOfflinePad() {
        XCTAssertEqual(SilentTailStop.delayTokens(delayMs: 480), 6)
        XCTAssertEqual(SilentTailStop.rightPadTokens(delayMs: 480), 17)
        XCTAssertEqual(SilentTailStop.alignmentSamples(after: 2_560), 0)
        XCTAssertEqual(SilentTailStop.alignmentSamples(after: 2_561), 1_279)
    }

    /// No pad counts before the delay has passed the last real audio token, and a
    /// word token resets the run.
    func testStopsOnlyOnPadsInARowPastTheDelay() {
        // 10 real tokens + 32 left pad = position 42 ends the audio; the delay adds 6.
        var stop = SilentTailStop(
            realSamples: 10 * 1_280, delayMs: 480, leftPadTokens: 32,
            padTokens: 2, padTokenId: 32
        )
        XCTAssertEqual(stop.fromPosition, 48)
        let pad = 32, word = 1_000
        XCTAssertFalse(stop.observe(token: pad, position: 46))
        XCTAssertFalse(stop.observe(token: pad, position: 47))
        XCTAssertFalse(stop.observe(token: pad, position: 48))
        XCTAssertFalse(stop.observe(token: word, position: 49))
        XCTAssertFalse(stop.observe(token: pad, position: 50))
        XCTAssertTrue(stop.observe(token: pad, position: 51))
    }
}
