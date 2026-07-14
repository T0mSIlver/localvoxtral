import Foundation
import XCTest
@testable import localvoxtral

final class ClipboardPayloadMacroTests: XCTestCase {
    private let placeholder = ClipboardPayloadMacro.placeholder

    // MARK: - Marker detection

    func testDetectsEveryPhraseVariant() {
        let phrases = [
            // English bases.
            "paste the clipboard",
            "paste clipboard",
            "insert the clipboard",
            "insert clipboard",
            // English suffixes.
            "paste the clipboard here",
            "paste clipboard here",
            "insert the clipboard contents",
            "insert clipboard content",
            "paste the clipboard contents",
            // Case-insensitive.
            "Paste The Clipboard",
            "PASTE CLIPBOARD",
            "Insert The Clipboard Here",
            // French, hyphenated.
            "colle le presse-papiers",
            "colle le presse-papier",
            "insère le presse-papiers",
            "insère le presse-papier",
            // French, STT dropped the hyphen.
            "colle le presse papiers",
            "insère le presse papier",
        ]

        for phrase in phrases {
            let result = ClipboardPayloadMacro.replaceMarkersWithPlaceholder(
                in: "before \(phrase) after"
            )
            XCTAssertEqual(result.count, 1, "phrase should match once: \(phrase)")
            XCTAssertEqual(
                result.text,
                "before \(placeholder) after",
                "phrase should be fully consumed: \(phrase)"
            )
        }
    }

    func testMarkerToleratesSurroundingPunctuation() {
        let result = ClipboardPayloadMacro.replaceMarkersWithPlaceholder(
            in: "here's the error — paste clipboard — I think it's the retry logic"
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(
            result.text,
            "here's the error — \(placeholder) — I think it's the retry logic"
        )
    }

    func testLongestMatchConsumesSuffix() {
        // "here" is consumed by the marker, not left dangling as prose.
        let result = ClipboardPayloadMacro.replaceMarkersWithPlaceholder(
            in: "read this paste the clipboard here please"
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.text, "read this \(placeholder) please")
    }

    func testMultipleMarkersEachBecomeAPlaceholder() {
        let result = ClipboardPayloadMacro.replaceMarkersWithPlaceholder(
            in: "paste clipboard and also insert clipboard"
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.text, "\(placeholder) and also \(placeholder)")
    }

    func testNegativeCasesDoNotMatch() {
        let negatives = [
            "clipboard history is broken",   // no paste/insert verb
            "copy-paste the code please",    // paste, but of "the code", no clipboard
            "let me paste the code here",    // paste, no clipboard
            "the clipboard is full today",   // clipboard, no verb
            "insertion sort in clipboard.js", // "insert" embedded in a word
        ]
        for input in negatives {
            XCTAssertTrue(
                ClipboardPayloadMacro.detectMarkers(in: input).isEmpty,
                "should not match: \(input)"
            )
        }
    }

    func testAcceptedOvermatchOfContentSuffix() {
        // Documented, acceptable over-match: "content" is a suffix, so this
        // consumes "paste the clipboard content" and leaves " of the file".
        let result = ClipboardPayloadMacro.replaceMarkersWithPlaceholder(
            in: "paste the clipboard content of the file"
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.text, "\(placeholder) of the file")
    }

    // MARK: - Payload formatting

    func testInlineForShortSingleLinePayload() {
        let out = ClipboardPayloadMacro.substitutePayload(
            in: "run \(placeholder) now", payload: "config.yaml"
        )
        XCTAssertEqual(out, "run `config.yaml` now")
    }

    /// The agent prompt asks the model to format environment variables as
    /// code, so real inference consistently returns the placeholder inside a
    /// Markdown code span. Substitution must consume that model-added wrapper
    /// instead of producing a doubled code span.
    func testBacktickedPlaceholderDoesNotDoubleWrapInlinePayload() {
        let out = ClipboardPayloadMacro.substitutePayload(
            in: "run `\(placeholder)` now", payload: "config.yaml"
        )
        XCTAssertEqual(out, "run `config.yaml` now")
    }

    /// The same wrapper is especially damaging for multi-line payloads: if it
    /// survives around the generated fence, the committed Markdown contains
    /// dangling inline-code delimiters around a block.
    func testBacktickedPlaceholderDoesNotWrapFencedPayload() {
        let out = ClipboardPayloadMacro.substitutePayload(
            in: "inspect `\(placeholder)` now", payload: "line1\nline2"
        )
        XCTAssertEqual(out, "inspect \n```\nline1\nline2\n```\n now")
    }

    func testInlineStripsSurroundingWhitespace() {
        let out = ClipboardPayloadMacro.substitutePayload(
            in: "x \(placeholder) y", payload: "  abc  "
        )
        XCTAssertEqual(out, "x `abc` y")
    }

    func testInlineThresholdBoundary() {
        let sixty = String(repeating: "a", count: 60)
        let sixtyOne = String(repeating: "a", count: 61)

        let inline = ClipboardPayloadMacro.substitutePayload(
            in: placeholder, payload: sixty
        )
        XCTAssertEqual(inline, "`\(sixty)`")

        let fenced = ClipboardPayloadMacro.substitutePayload(
            in: placeholder, payload: sixtyOne
        )
        XCTAssertEqual(fenced, "```\n\(sixtyOne)\n```")
    }

    func testMultiLinePayloadIsFencedWithSurroundingNewlines() {
        // Placeholder mid-line: fence gains a leading and trailing newline.
        let out = ClipboardPayloadMacro.substitutePayload(
            in: "a \(placeholder) b", payload: "line1\nline2"
        )
        XCTAssertEqual(out, "a \n```\nline1\nline2\n```\n b")
    }

    func testFenceHonorsExistingLineBoundaries() {
        // Placeholder already alone on its line: no doubled blank lines.
        let out = ClipboardPayloadMacro.substitutePayload(
            in: "a\n\(placeholder)\nb", payload: "line1\nline2"
        )
        XCTAssertEqual(out, "a\n```\nline1\nline2\n```\nb")
    }

    func testCapAppendsTruncationMarkerInsideFence() {
        let big = String(repeating: "a", count: 8100)
        let out = ClipboardPayloadMacro.substitutePayload(in: placeholder, payload: big)

        XCTAssertTrue(out.hasPrefix("```\n"))
        XCTAssertTrue(out.hasSuffix("\n```"))
        XCTAssertTrue(out.contains(ClipboardPayloadMacro.truncationMarker))
        // Exactly the head cap survives as a contiguous run; the rest is dropped.
        let cap = ClipboardPayloadMacro.payloadCharacterCap
        XCTAssertTrue(out.contains(String(repeating: "a", count: cap)))
        XCTAssertFalse(out.contains(String(repeating: "a", count: cap + 1)))
    }

    // MARK: - Fence collision (CommonMark)

    func testPayloadWithTripleBacktickBlockGetsLongerOuterFence() {
        // The payload itself contains a fenced block: the outer fence must be
        // longer (max run 3 → fence 4) so the inner ``` can't close it early,
        // and the payload round-trips intact between the outer fences.
        let payload = "error in:\n```\nlet x = 1\n```\ndone"
        let out = ClipboardPayloadMacro.substitutePayload(in: placeholder, payload: payload)
        XCTAssertEqual(out, "````\n\(payload)\n````")
    }

    func testShortPayloadWithBacktickIsFencedNotInline() {
        // Short and single-line, but a backtick inside would break a single-
        // backtick inline wrap: fenced instead.
        let out = ClipboardPayloadMacro.substitutePayload(
            in: "x \(placeholder) y", payload: "run `ls` now"
        )
        XCTAssertEqual(out, "x \n```\nrun `ls` now\n```\n y")
    }

    func testFenceIsOneLongerThanLongestBacktickRun() {
        // A 5-backtick run inside the payload → 6-backtick outer fence.
        let payload = "before\n`````\nafter"
        let out = ClipboardPayloadMacro.substitutePayload(in: placeholder, payload: payload)
        XCTAssertEqual(out, "``````\n\(payload)\n``````")
    }

    // MARK: - Standalone placeholder count

    func testStandalonePlaceholderCount() {
        XCTAssertEqual(ClipboardPayloadMacro.standalonePlaceholderCount(in: "no marker"), 0)
        XCTAssertEqual(
            ClipboardPayloadMacro.standalonePlaceholderCount(in: "a \(placeholder) b"), 1
        )
        XCTAssertEqual(
            ClipboardPayloadMacro.standalonePlaceholderCount(
                in: "\(placeholder) and \(placeholder)"
            ),
            2
        )
        // Sentence punctuation is not a body char: still standalone.
        XCTAssertEqual(
            ClipboardPayloadMacro.standalonePlaceholderCount(in: "see \(placeholder)."), 1
        )
        // A body char glued to either side is corruption, not an occurrence —
        // same boundary rule as PolishTokenGuard.
        XCTAssertEqual(
            ClipboardPayloadMacro.standalonePlaceholderCount(in: "x\(placeholder) y"), 0
        )
        XCTAssertEqual(
            ClipboardPayloadMacro.standalonePlaceholderCount(in: "\(placeholder)S y"), 0
        )
    }

    func testNoPlaceholderLeavesTextUnchanged() {
        let out = ClipboardPayloadMacro.substitutePayload(
            in: "no marker here", payload: "abc"
        )
        XCTAssertEqual(out, "no marker here")
    }

    func testSubstitutesEveryPlaceholderOccurrence() {
        let out = ClipboardPayloadMacro.substitutePayload(
            in: "\(placeholder) and \(placeholder)", payload: "x.txt"
        )
        XCTAssertEqual(out, "`x.txt` and `x.txt`")
    }

    // MARK: - Token-guard interplay (the deliberate trick)

    /// The placeholder is env-var-shaped, so `PolishTokenGuard` already treats
    /// it as a protected token with ZERO guard changes. This pins that so a
    /// future guard-recognizer change can't silently break the macro.
    func testPlaceholderIsAProtectedToken() {
        XCTAssertEqual(
            PolishTokenGuard.protectedTokens(in: "x \(placeholder) y"),
            [placeholder]
        )
    }

    /// If the polish model deletes the placeholder, the guard falls back to the
    /// placeholder-bearing working text — the macro survives the LLM.
    func testGuardFallsBackWhenModelDropsPlaceholder() {
        let original = "x \(placeholder) y"
        let result = PolishTokenGuard.verifyAndRepair(polished: "x y", original: original)
        XCTAssertEqual(result.outcome, .fallback(missing: [placeholder]))
        XCTAssertEqual(result.text, original)
    }
}
