import Foundation
import XCTest
@testable import localvoxtral

/// Unit tests for the pure sweep decision logic (issue #23 Stage 1).
///
/// `LiveAutoPasteSweep.computeDecision` is the load-bearing safety property of
/// the feature: it is the gate that prevents the sweep from corrupting user
/// text. These tests pin down its span-location arithmetic and — critically —
/// its content-verification guard, without any Accessibility I/O.
final class LiveAutoPasteSweepTests: XCTestCase {
    // MARK: - Happy path (apply)

    func testApply_whenSpanContentMatchesRawText() {
        // Field contains "prefix" + the raw session text + " suffix". The
        // tracked span starts at offset 7 and is 18 UTF-16 units long
        // ("call me dash later"). The dictionary changes it.
        let decision = LiveAutoPasteSweep.computeDecision(
            rawText: "call me dash later",
            processedText: "call me - later",
            fieldValue: "prefix call me dash later suffix",
            startCaret: 7,
            insertedUTF16Length: 18
        )

        XCTAssertEqual(
            decision,
            .apply(replacement: "call me - later", location: 7, length: 18)
        )
    }

    func testApply_preservesSurroundingTextByReplacingOnlyTheSpan() {
        // The decision only describes the span; the surrounding text is
        // preserved by the AX value-write (verified separately). Here we
        // confirm the span is exactly the raw text's length, not the whole
        // field.
        let decision = LiveAutoPasteSweep.computeDecision(
            rawText: "dash",
            processedText: "-",
            fieldValue: "alpha dash beta",
            startCaret: 6,
            insertedUTF16Length: 4
        )

        XCTAssertEqual(decision, .apply(replacement: "-", location: 6, length: 4))
    }

    // MARK: - No change

    func testSkip_whenProcessedTextEqualsRawText() {
        let decision = LiveAutoPasteSweep.computeDecision(
            rawText: "no matches here",
            processedText: "no matches here",
            fieldValue: "no matches here",
            startCaret: 0,
            insertedUTF16Length: 16
        )

        if case .skip(let reason) = decision {
            XCTAssertTrue(reason.contains("equals raw text"))
        } else {
            XCTFail("expected .skip, got \(decision)")
        }
    }

    // MARK: - Nothing tracked

    func testSkip_whenInsertedLengthIsZero() {
        let decision = LiveAutoPasteSweep.computeDecision(
            rawText: "dash",
            processedText: "-",
            fieldValue: "dash",
            startCaret: 0,
            insertedUTF16Length: 0
        )

        if case .skip(let reason) = decision {
            XCTAssertTrue(reason.contains("no text tracked"))
        } else {
            XCTFail("expected .skip, got \(decision)")
        }
    }

    // MARK: - Content mismatch (the critical safety guard)

    func testSkip_whenUserEditedInsideTheSpan() {
        // The user manually edited "dash" to "DASH" inside the tracked span.
        // The sweep must NOT proceed — revising would destroy the user's edit.
        let decision = LiveAutoPasteSweep.computeDecision(
            rawText: "call me dash later",
            processedText: "call me - later",
            fieldValue: "call me DASH later",
            startCaret: 0,
            insertedUTF16Length: 19
        )

        if case .skip(let reason) = decision {
            XCTAssertTrue(reason.contains("does not match"))
        } else {
            XCTFail("expected .skip for content mismatch, got \(decision)")
        }
    }

    func testSkip_whenFieldAutoCorrectedTheTypedText() {
        // The field auto-corrected "teh" to "the" after it was typed. The span
        // no longer contains what we inserted.
        let decision = LiveAutoPasteSweep.computeDecision(
            rawText: "teh",
            processedText: "the",
            fieldValue: "the",
            startCaret: 0,
            insertedUTF16Length: 3
        )

        if case .skip = decision {
            // expected
        } else {
            XCTFail("expected .skip for auto-corrected content, got \(decision)")
        }
    }

    func testSkip_whenFieldContentIsShorterThanTrackedSpan() {
        // The user deleted characters, so the field is shorter than the tracked
        // span. Even after clamping, the substring won't match rawText.
        let decision = LiveAutoPasteSweep.computeDecision(
            rawText: "hello world",
            processedText: "hello-world",
            fieldValue: "hello wor",
            startCaret: 0,
            insertedUTF16Length: 11
        )

        if case .skip = decision {
            // expected
        } else {
            XCTFail("expected .skip for truncated field, got \(decision)")
        }
    }

    func testSkip_whenSpanOffsetIsStaleDueToPriorUserInsertion() {
        // The user typed two characters BEFORE the session span, shifting
        // everything right. The tracked startCaret (0) now points at text that
        // isn't our rawText, so the content guard catches it.
        let decision = LiveAutoPasteSweep.computeDecision(
            rawText: "dash",
            processedText: "-",
            fieldValue: "abdash",
            startCaret: 0,
            insertedUTF16Length: 4
        )

        if case .skip = decision {
            // expected — substring at [0,4) is "abda" != "dash"
        } else {
            XCTFail("expected .skip for stale offset, got \(decision)")
        }
    }

    // MARK: - Defensive clamping

    func testClampsStartCaretBeyondFieldLength() {
        // startCaret is past the end of the field. Clamped to fieldLength (0
        // for an empty field), the substring is empty and won't match a
        // non-empty rawText → skip.
        let decision = LiveAutoPasteSweep.computeDecision(
            rawText: "dash",
            processedText: "-",
            fieldValue: "",
            startCaret: 100,
            insertedUTF16Length: 4
        )

        if case .skip = decision {
            // expected
        } else {
            XCTFail("expected .skip for out-of-bounds caret, got \(decision)")
        }
    }

    func testApply_whenStartCaretIsNegative_clampsToZero() {
        // A negative caret (shouldn't happen but defensive) clamps to 0, and if
        // the span content matches, the sweep proceeds.
        let decision = LiveAutoPasteSweep.computeDecision(
            rawText: "dash",
            processedText: "-",
            fieldValue: "dash",
            startCaret: -5,
            insertedUTF16Length: 4
        )

        XCTAssertEqual(decision, .apply(replacement: "-", location: 0, length: 4))
    }
}
