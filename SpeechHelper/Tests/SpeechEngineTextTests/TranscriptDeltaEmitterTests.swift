import XCTest

@testable import SpeechEngineText

/// Metal-free regression tests for `TranscriptDeltaEmitter` — the wrapper the realtime
/// server uses to turn the upstream engine's FULL transcript snapshots into an append-only
/// wire stream. This is the layer that replaced the previously vendored engine's internal
/// LOCAL FIX #6: upstream's own `Delta` re-emits the whole transcript on a non-prefix step,
/// and our no-backspace insertion path would duplicate that. These tests feed the emitter
/// the same `session.text` snapshots the server does and assert the wire output is
/// append-only and never duplicates.
final class TranscriptDeltaEmitterTests: XCTestCase {
    /// Drive a sequence of full-transcript snapshots through the emitter exactly as
    /// `RealtimeSpeechServer.dispatch` does (one `emit(fullText:)` per step/finish),
    /// returning the concatenation of every delta actually put on the wire.
    private func replay(_ snapshots: [String]) -> (wire: String, emitter: TranscriptDeltaEmitter) {
        var emitter = TranscriptDeltaEmitter()
        var wire = ""
        for full in snapshots {
            wire += emitter.emit(fullText: full)
        }
        return (wire, emitter)
    }

    func testPlainForwardExtensionEmitsOnlyTheSuffix() {
        let r = replay(["hel", "hello", "hello wo", "hello world"])
        XCTAssertEqual(r.wire, "hello world")
        XCTAssertEqual(r.emitter.rewriteCount, 0)
        XCTAssertEqual(r.emitter.emittedText, r.wire, "emittedText must equal the wire concatenation")
    }

    func testSplitMultibyteCharIsNotDuplicated() {
        // "café": the é (2 UTF-8 bytes) is split across tokens, so the first snapshot ends in
        // a replacement char that the next resolves. Upstream's raw delta would re-emit the
        // whole string here → "cafcafé". The wire must be exactly "café ".
        let r = replay(["caf", "caf\u{FFFD}", "café", "café "])
        XCTAssertEqual(r.wire, "café ")
        XCTAssertFalse(r.wire.contains("caf caf"), "a resolving multi-byte char must not duplicate")
        XCTAssertEqual(r.emitter.rewriteCount, 0, "resolving a provisional char is not a rewrite")
        XCTAssertEqual(r.emitter.emittedText, r.wire)
    }

    func testNonPrefixRewriteIsHeldBackNotDuplicated() {
        // A genuine non-prefix rewrite mid-stream (the exact shape the append-only contract
        // guards): once "hello wXY" is on the wire, the engine snapshots "hello world". The
        // consumer already typed "hello wXY" and can't un-type it, so the emitter must NOT
        // re-emit the whole snapshot (that would type "hello wXYorld"). It holds, flags a
        // rewrite, and the following identical snapshot adds nothing.
        let r = replay(["hello wXY", "hello world", "hello world"])
        XCTAssertEqual(r.wire, "hello wXY")
        XCTAssertNotEqual(r.wire, "hello wXYworld", "a rewrite must never be appended verbatim")
        XCTAssertNotEqual(r.wire, "hello wXYorld", "a rewrite must never garble across steps")
        XCTAssertEqual(r.emitter.rewriteCount, 2)
        XCTAssertEqual(r.emitter.emittedText, r.wire, "emittedText must never move backwards")
    }

    func testMixedStreamWithRewriteAndSplitCharStaysAppendOnly() {
        // Non-prefix rewrite AND a split multi-byte char in one stream. The wire must remain a
        // strict forward extension at every step and equal `emittedText` at the end.
        let snapshots = ["le", "le caf\u{FFFD}", "le café", "le cafX", "le café était"]
        var emitter = TranscriptDeltaEmitter()
        var wire = ""
        for full in snapshots {
            let before = wire
            let delta = emitter.emit(fullText: full)
            wire += delta
            XCTAssertTrue(wire.hasPrefix(before), "wire must only ever grow (append-only) at \(full)")
            XCTAssertEqual(emitter.emittedText, wire, "invariant emittedText == wire at \(full)")
        }
        XCTAssertFalse(wire.contains("\u{FFFD}"), "no provisional char ever reaches the wire")
        XCTAssertGreaterThan(emitter.rewriteCount, 0, "the 'le cafX' divergence must register as a rewrite")
    }

    func testFinishAfterHeldBackTrailingCharDoesNotEmitReplacementChar() {
        // Audio can cut off mid multi-byte char: the final snapshot still carries a trailing
        // U+FFFD. The emitter (like the server's finish() path) holds it back; the final
        // `emittedText` — used for the transcript.done payload — never contains it.
        let r = replay(["caf", "café", "café \u{FFFD}"])
        XCTAssertEqual(r.wire, "café ")
        XCTAssertFalse(r.emitter.emittedText.contains("\u{FFFD}"))
        XCTAssertEqual(r.emitter.rewriteCount, 0)
    }
}
