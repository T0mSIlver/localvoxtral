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

    func testStreamEndingInUnresolvedReplacementCharHoldsItBack() {
        // The stream's FINAL snapshot still carries a trailing U+FFFD that never resolves
        // (audio cut off mid multi-byte char). `stablePrefix` must hold it back: the running
        // concatenation ends at the stable text, the provisional char is never emitted, and
        // no rewrite is flagged (dropping a trailing provisional char is not a divergence).
        let r = replay(["caf", "café", "café \u{FFFD}"])
        XCTAssertEqual(r.concatenated, "café ")
        XCTAssertFalse(r.concatenated.contains("\u{FFFD}"), "a provisional trailing char must never be emitted")
        XCTAssertEqual(r.rewrites, 0)
    }

    func testShrinkToProperPrefixHoldsInsteadOfReEmitting() {
        // `fullText` gets SHORTER — shrinking to a proper prefix of what was already emitted.
        // The consumer has typed the longer text and can't un-type it, so this is the
        // `wasRewrite` hold path (a shorter, not same-length, divergence): emit nothing, keep
        // `emitted` pinned to what was typed, flag the rewrite. Re-emitting would garble.
        let step = StreamingDelta.next(previouslyEmitted: "hello world", fullText: "hello")
        XCTAssertEqual(step.delta, "", "a shrink must not re-emit")
        XCTAssertEqual(step.emitted, "hello world", "emitted must never move backwards")
        XCTAssertTrue(step.wasRewrite)
    }

    func testGenuineRewriteHoldsInsteadOfMovingEmittedBackwards() {
        // On a true divergence we must NOT shrink `emitted` (the consumer already typed it and
        // can't un-type). Emit nothing, keep `emitted` == what was typed, flag the rewrite.
        let step = StreamingDelta.next(previouslyEmitted: "hello wXY", fullText: "hello world")
        XCTAssertEqual(step.delta, "")
        XCTAssertEqual(step.emitted, "hello wXY", "emitted must never move backwards")
        XCTAssertTrue(step.wasRewrite)
    }

    func testRewriteThenExtensionNeverGarblesAcrossSteps() {
        // The regression the module exists to prevent: a rewrite followed by more text must not
        // append a suffix onto stale on-screen text. Before the fix this produced "hello wXYorld".
        let r = replay(["hello wXY", "hello world", "hello world"])
        XCTAssertNotEqual(r.concatenated, "hello wXYorld")
        // Append-only invariant: the running concatenation is always a prefix of itself over time
        // and never contains contradicting interleaving. Here it holds at "hello wXY".
        XCTAssertEqual(r.concatenated, "hello wXY")
        XCTAssertEqual(r.rewrites, 2)
    }

    func testEmittedPlusDeltaAlwaysEqualsEmitted_invariant() {
        // The core invariant, checked over a mixed sequence incl. a divergence.
        var emitted = ""
        for full in ["ab", "abc", "abX", "abcd", "abcde"] {
            let step = StreamingDelta.next(previouslyEmitted: emitted, fullText: full)
            XCTAssertEqual(emitted + step.delta, step.emitted, "invariant violated at fullText=\(full)")
            emitted = step.emitted
        }
    }

    func testStablePrefixDropsOnlyTrailingReplacementChars() {
        XCTAssertEqual(String(StreamingDelta.stablePrefix(of: "ab\u{FFFD}c")), "ab\u{FFFD}c")
        XCTAssertEqual(String(StreamingDelta.stablePrefix(of: "abc\u{FFFD}\u{FFFD}")), "abc")
        XCTAssertEqual(String(StreamingDelta.stablePrefix(of: "abc")), "abc")
    }
}
