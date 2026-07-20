import XCTest
@testable import localvoxtral

/// Realistic code-heavy clipboard buffers, not `String(repeating:)` padding.
///
/// This matters: filler made of one repeated character produces almost no
/// technical entities, so a matcher can look fast and accurate against it while
/// collapsing on a real 100k-line source file — which is exactly the input this
/// feature is for. These fixtures generate plausible Swift-ish source so entity
/// extraction, the containment sweep, and scoring all do real work.
enum CodeHeavyFixture {
    /// Source-file-shaped lines with paths, identifiers, flags, and URLs — the
    /// token shapes `PolishTokenGuard.protectedTokens` actually recognizes.
    static func lines(count: Int) -> [String] {
        (0..<count).map { index in
            switch index % 6 {
            case 0: return "import Foundation // module\(index)"
            case 1: return "    let handler\(index) = RequestHandler\(index)(retries: \(index % 7))"
            case 2: return "    // see Sources/Networking/Transport\(index).swift for details"
            case 3: return "    guard let url = URL(string: \"https://api.example.com/v\(index)/items\") else { return }"
            case 4: return "    process.arguments = [\"--timeout=\(index)\", \"--verbose\"]"
            default: return "    logger.debug(\"handled \\(index) events in Transport\(index).swift\")"
            }
        }
    }

    /// A code-heavy buffer of at least `minimumCharacters`, with `target`
    /// appended on its own line at the very END — so any head-truncating
    /// behavior loses it.
    static func buffer(minimumCharacters: Int, target: String) -> String {
        var text = ""
        var index = 0
        let body = lines(count: 4000)
        while text.count < minimumCharacters {
            text += body[index % body.count] + "\n"
            index += 1
        }
        return text + target + "\n"
    }
}

final class PolishContextPreparationTests: XCTestCase {
    private let transcript = "the crash in payment reconciler dot swift"
    private let target = "thrown from PaymentReconciler.swift line 88"

    private func grounds(_ preparation: PolishContextPreparation) -> Bool {
        preparation.grounding.entries.contains { $0.replaceWith == "PaymentReconciler.swift" }
    }

    // MARK: - Grounding depth

    /// The original regression: a term past character 2000 was invisible.
    func testTermPastTwoThousandCharactersOfCodeHeavyFillerStillGrounds() {
        let clipboard = CodeHeavyFixture.buffer(minimumCharacters: 2_000, target: target)
        XCTAssertGreaterThan(clipboard.count, 2_000)
        let prepared = PolishContextPreparation.prepare(
            text: clipboard,
            transcript: transcript,
            renderBudget: PolishContextBudget.totalCharacterBudget
        )
        XCTAssertTrue(grounds(prepared), "term past 2k must ground; got \(prepared.grounding.entries)")
    }

    /// The 20k compromise cap would have cut this one off. Code-heavy filler,
    /// so the containment sweep and entity extraction do real work.
    func testTermPastTwentyThousandCharactersOfCodeHeavyFillerStillGrounds() {
        let clipboard = CodeHeavyFixture.buffer(minimumCharacters: 20_000, target: target)
        XCTAssertGreaterThan(clipboard.count, 20_000)
        let prepared = PolishContextPreparation.prepare(
            text: clipboard,
            transcript: transcript,
            renderBudget: PolishContextBudget.totalCharacterBudget
        )
        XCTAssertTrue(grounds(prepared), "term past 20k must ground; got \(prepared.grounding.entries)")
    }

    /// Grounding must not depend on the term surviving into the rendered
    /// excerpt: the excerpt here is a tiny fraction of the buffer.
    func testGroundingSurvivesWhenTheExcerptIsAFractionOfTheBuffer() {
        let clipboard = CodeHeavyFixture.buffer(minimumCharacters: 20_000, target: target)
        let prepared = PolishContextPreparation.prepare(
            text: clipboard,
            transcript: transcript,
            renderBudget: 200
        )
        XCTAssertLessThanOrEqual(prepared.excerpt.count, 200)
        XCTAssertLessThan(prepared.excerpt.count, clipboard.count / 10)
        XCTAssertTrue(grounds(prepared))
    }

    // MARK: - Verbatim below budget / select above it

    func testBufferAtOrBelowTheBudgetIsAttachedVerbatim() {
        let clipboard = "error in UserSessionManager.swift\n\n  at line 42\n"
        let prepared = PolishContextPreparation.prepare(
            text: clipboard,
            transcript: "fix the user session manager",
            renderBudget: PolishContextBudget.totalCharacterBudget
        )
        XCTAssertEqual(prepared.excerpt, clipboard, "small content must reach the model as copied")
    }

    func testBufferAboveTheBudgetIsSelectedNotTruncated() {
        let clipboard = CodeHeavyFixture.buffer(minimumCharacters: 30_000, target: target)
        let prepared = PolishContextPreparation.prepare(
            text: clipboard,
            transcript: transcript,
            renderBudget: PolishContextBudget.totalCharacterBudget
        )
        XCTAssertLessThanOrEqual(prepared.excerpt.count, PolishContextBudget.totalCharacterBudget)
        XCTAssertFalse(
            clipboard.hasPrefix(prepared.excerpt),
            "a head-prefix excerpt would mean selection never ran"
        )
        XCTAssertTrue(
            prepared.excerpt.contains("PaymentReconciler.swift"),
            "selection must keep the transcript-relevant tail line"
        )
    }

    /// `prepared` (nonisolated async, off the main actor) must return exactly
    /// what the synchronous core does, at every size.
    func testAsyncEntryPointAgreesWithTheSynchronousCore() async {
        for minimum in [100, PolishContextBudget.totalCharacterBudget + 1, 30_000] {
            let clipboard = CodeHeavyFixture.buffer(minimumCharacters: minimum, target: target)
            let sync = PolishContextPreparation.prepare(
                text: clipboard,
                transcript: transcript,
                renderBudget: PolishContextBudget.totalCharacterBudget
            )
            let viaEntryPoint = await PolishContextPreparation.prepared(
                text: clipboard,
                transcript: transcript,
                renderBudget: PolishContextBudget.totalCharacterBudget
            )
            XCTAssertEqual(viaEntryPoint.excerpt, sync.excerpt, "minimum=\(minimum)")
            XCTAssertEqual(viaEntryPoint.grounding, sync.grounding, "minimum=\(minimum)")
        }
    }

    func testEmptyClipboardPreparesToNothing() {
        let prepared = PolishContextPreparation.prepare(
            text: "",
            transcript: transcript,
            renderBudget: 6000
        )
        XCTAssertEqual(prepared, PolishContextPreparation.empty)
    }

    // MARK: - Oversized single line

    /// A pathological one-line buffer (a minified bundle, a base64 blob) is
    /// bigger than the budget and cannot be split. It must render nothing
    /// rather than a truncated fragment — but it must STILL ground, because
    /// matching does not care about line structure.
    func testOversizedSingleLineIsTruncatedWithAMarkerWithinTheCap() {
        let blob = String(repeating: "a", count: 20_000) + " PaymentReconciler.swift "
            + String(repeating: "b", count: 20_000)
        let prepared = PolishContextPreparation.prepare(
            text: blob,
            transcript: transcript,
            renderBudget: 500
        )
        XCTAssertLessThanOrEqual(prepared.excerpt.count, 500, "the cap is a hard contract")
        XCTAssertFalse(prepared.excerpt.isEmpty, "the allocation must not be silently wasted")
        XCTAssertTrue(
            prepared.excerpt.hasSuffix(PolishContextExcerptSelector.elisionMarker),
            "an unmarked cut reads as a complete line; got: \(prepared.excerpt.suffix(20))"
        )
        XCTAssertTrue(grounds(prepared), "grounding is line-structure independent")
    }

    /// A cap too small to hold even the marker must still honor the cap.
    func testTruncationMarkerNeverPushesPastATinyCap() {
        let blob = String(repeating: "a", count: 5_000)
        for cap in [1, 2, 3, 4, 8] {
            let prepared = PolishContextPreparation.prepare(
                text: blob, transcript: transcript, renderBudget: cap
            )
            XCTAssertLessThanOrEqual(prepared.excerpt.count, cap, "cap=\(cap)")
        }
    }

    /// The same blob with one short relevant line after it: the oversized line
    /// is skipped, and the line that fits still renders.
    func testOversizedLineIsSkippedSoALaterFittingLineStillRenders() {
        let blob = String(repeating: "a", count: 20_000)
        let prepared = PolishContextPreparation.prepare(
            text: blob + "\n" + target,
            transcript: transcript,
            renderBudget: 500
        )
        XCTAssertTrue(prepared.excerpt.contains("PaymentReconciler.swift"))
        XCTAssertLessThanOrEqual(prepared.excerpt.count, 500)
    }

    // MARK: - Entity extraction is not per-line

    /// The regression this guards: the selector used to call the entity
    /// recognizer (nine `NSRegularExpression` passes) on EVERY line, re-deriving
    /// per line what `candidateOutcome` had just extracted from the whole
    /// buffer. On a 50k-line paste that is ~450k regex executions.
    ///
    /// Asserted as a budget rather than a stopwatch: selection over a large
    /// many-line buffer must cost about the same as ONE whole-buffer extraction
    /// plus linear scanning. If per-line regex work returns, selection alone
    /// blows past the extraction it is compared against, because it would be
    /// doing that same extraction thousands of times over.
    func testSelectionOverManyLinesCostsNoMoreThanOneWholeBufferExtraction() {
        let lines = CodeHeavyFixture.lines(count: 20_000)
        let text = lines.joined(separator: "\n") + "\n" + target
        XCTAssertGreaterThan(lines.count, 10_000, "the fixture must be many-line to be meaningful")

        // One whole-buffer extraction — the work that legitimately must happen.
        let extractionStart = ContinuousClock.now
        let outcome = ClipboardVocabulary.candidateOutcome(
            transcript: transcript, clipboardText: text
        )
        let extractionCost = ContinuousClock.now - extractionStart

        // Selection over the same buffer, given the terms extraction produced.
        let selectionStart = ContinuousClock.now
        let excerpt = PolishContextExcerptSelector.select(
            text: text,
            transcript: transcript,
            characterCap: PolishContextBudget.totalCharacterBudget,
            groundingTerms: outcome.entries.map(\.replaceWith)
        )
        let selectionCost = ContinuousClock.now - selectionStart

        XCTAssertFalse(excerpt.isEmpty)
        // Generous multiple: this is a shape assertion (linear scans vs. tens of
        // thousands of regex sweeps), not a benchmark. Per-line extraction over
        // 20k lines exceeded whole-buffer extraction by orders of magnitude.
        XCTAssertLessThan(
            selectionCost, extractionCost * 5,
            "selection cost \(selectionCost) vs one extraction \(extractionCost) — per-line entity extraction is back"
        )
    }

    /// Selection must not need the recognizer at all: given the terms, scoring
    /// is literal/normalized containment plus word overlap.
    func testSelectionWithGroundingTermsKeepsTheRelevantLine() {
        let text = CodeHeavyFixture.buffer(minimumCharacters: 20_000, target: target)
        let excerpt = PolishContextExcerptSelector.select(
            text: text,
            transcript: transcript,
            characterCap: 300,
            groundingTerms: ["PaymentReconciler.swift"]
        )
        XCTAssertTrue(
            excerpt.contains("PaymentReconciler.swift"),
            "a supplied grounding term must dominate scoring; got: \(excerpt)"
        )
    }

    // MARK: - Cancellation

    /// `prepared` is a structured child of the caller, so cancelling the commit
    /// must abandon it. The earlier `Task.detached` severed exactly this: a
    /// detached task has no parent and ran the full sweep regardless.
    func testCancelledSelectionIsAbandonedRatherThanRunToCompletion() async {
        let text = CodeHeavyFixture.buffer(minimumCharacters: 200_000, target: target)

        // Gate the work behind a suspension the test controls, so cancellation
        // is guaranteed to land BEFORE selection starts. Cancelling a running
        // task and hoping to win the race would be a flaky test.
        // Locals, not `self.transcript`: capturing XCTestCase self in an
        // escaping `sending` Task closure is a Swift 6 error.
        let spoken = transcript
        let (gate, opener) = AsyncStream<Void>.makeStream()
        // Goes through `prepared` — the production entry point — so that
        // reintroducing `Task.detached` inside it (which would sever
        // cancellation) fails this test rather than passing it.
        let task = Task { () -> PolishContextPreparation in
            for await _ in gate { break }
            return await PolishContextPreparation.prepared(
                text: text,
                transcript: spoken,
                renderBudget: PolishContextBudget.totalCharacterBudget
            )
        }
        task.cancel()
        opener.yield()
        opener.finish()

        let result = await task.value
        XCTAssertEqual(
            result.excerpt, "",
            "a cancelled preparation must bail at its first batch check, not sweep 200k characters"
        )
    }

    /// The same buffer, NOT cancelled, does produce an excerpt — otherwise the
    /// test above would pass for the wrong reason.
    func testUncancelledSelectionOverTheSameBufferDoesProduceAnExcerpt() {
        let text = CodeHeavyFixture.buffer(minimumCharacters: 200_000, target: target)
        let excerpt = PolishContextExcerptSelector.select(
            text: text,
            transcript: transcript,
            characterCap: PolishContextBudget.totalCharacterBudget,
            groundingTerms: ["PaymentReconciler.swift"]
        )
        XCTAssertFalse(excerpt.isEmpty)
    }

    // MARK: - Determinism

    func testPreparationIsDeterministic() {
        let clipboard = CodeHeavyFixture.buffer(minimumCharacters: 25_000, target: target)
        let first = PolishContextPreparation.prepare(
            text: clipboard, transcript: transcript, renderBudget: 1500
        )
        for _ in 0..<5 {
            let again = PolishContextPreparation.prepare(
                text: clipboard, transcript: transcript, renderBudget: 1500
            )
            XCTAssertEqual(again.excerpt, first.excerpt)
            XCTAssertEqual(again.grounding, first.grounding)
        }
    }
}
