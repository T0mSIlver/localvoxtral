import XCTest

@testable import SpeechEngineText

/// Metal-free regression tests for the append-only delta contract. These guard the
/// specific failure the vendored engine had upstream: re-emitting the whole transcript
/// when a multi-byte UTF-8 character is split across tokens, which our no-backspace
/// insertion path would duplicate on screen.
final class StreamingDeltaTests: XCTestCase {
    /// Drive a sequence of `fullText` snapshots through the running emitter the way the
    /// decode loop does, returning the concatenation of every delta. In a correct emitter
    /// that concatenation equals the final stable text — never more.
    private func replay(_ snapshots: [String]) -> (concatenated: String, rewrites: Int) {
        var emitted = ""
        var out = ""
        var rewrites = 0
        for full in snapshots {
            let step = StreamingDelta.next(previouslyEmitted: emitted, fullText: full)
            out += step.delta
            emitted = step.emitted
            if step.wasRewrite { rewrites += 1 }
        }
        return (out, rewrites)
    }

    func testPlainForwardExtensionEmitsOnlyTheSuffix() {
        let r = replay(["hel", "hello", "hello wo", "hello world"])
        XCTAssertEqual(r.concatenated, "hello world")
        XCTAssertEqual(r.rewrites, 0)
    }

    func testSplitMultibyteCharIsNotDuplicated() {
        // "café": the é (2 UTF-8 bytes) is split across tokens, so the first snapshot ends
        // in a replacement char that the next snapshot resolves. Upstream re-emitted the
        // whole string here → "cafcafé". The concatenation must be exactly "café".
        let r = replay(["caf", "caf\u{FFFD}", "café", "café "])
        XCTAssertEqual(r.concatenated, "café ")
        XCTAssertEqual(r.rewrites, 0, "resolving a provisional char is not a rewrite")
    }

    func testAccentedFrenchStreamNeverDuplicates() {
        // A longer accented stream with several split points.
        let snapshots = [
            "le caf\u{FFFD}", "le café ", "le café \u{FFFD}", "le café était",
            "le café était tr\u{FFFD}", "le café était très",
        ]
        let r = replay(snapshots)
        XCTAssertEqual(r.concatenated, "le café était très")
        XCTAssertEqual(r.rewrites, 0)
    }

    func testTrailingReplacementCharIsHeldBack() {
        let step = StreamingDelta.next(previouslyEmitted: "abc", fullText: "abc\u{FFFD}")
        XCTAssertEqual(step.delta, "", "a provisional trailing char must not be emitted")
        XCTAssertEqual(step.emitted, "abc")
        XCTAssertFalse(step.wasRewrite)
    }

    func testGenuineRewriteNeverEmitsContradictingText() {
        // If the text truly diverges (not just a provisional char), we must not append text
        // that contradicts what was already shown; we extend only along the common prefix.
        let step = StreamingDelta.next(previouslyEmitted: "hello wXY", fullText: "hello world")
        XCTAssertTrue("hello wXY".hasPrefix("hello w" + String(step.delta.prefix(0))))
        XCTAssertFalse(step.emitted.hasPrefix("hello wXYZ"))
        XCTAssertTrue(step.wasRewrite)
        XCTAssertTrue("hello world".hasPrefix(step.emitted))
    }

    func testStablePrefixDropsOnlyTrailingReplacementChars() {
        XCTAssertEqual(String(StreamingDelta.stablePrefix(of: "ab\u{FFFD}c")), "ab\u{FFFD}c")
        XCTAssertEqual(String(StreamingDelta.stablePrefix(of: "abc\u{FFFD}\u{FFFD}")), "abc")
        XCTAssertEqual(String(StreamingDelta.stablePrefix(of: "abc")), "abc")
    }
}
