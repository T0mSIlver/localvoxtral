import AppKit
import XCTest
@testable import localvoxtral

@MainActor
final class PolishContextClipboardReaderTests: XCTestCase {
    // MARK: - Sensitive-type skips

    func testConcealedTypeReturnsNil() {
        let stub = PasteboardStub(string: "hunter2", types: [.nsPasteboardConcealed, .string])
        XCTAssertNil(PolishContextClipboardReader.readClipboardContext(from: stub))
    }

    func testTransientTypeReturnsNil() {
        let stub = PasteboardStub(string: "one-shot", types: [.nsPasteboardTransient, .string])
        XCTAssertNil(PolishContextClipboardReader.readClipboardContext(from: stub))
    }

    // F4: the Settings enrollment-token / remote-command Copy actions write
    // through this helper, and the type set it declares must be exactly what
    // the harvester's own rules skip. Asserted through the write seam — a
    // live pasteboard (even a named one) needs the host's pasteboard server,
    // which the CI runner does not have.
    func testConcealedWriterDeclaresConcealedAndTheHarvesterRefusesIt() {
        let recorder = PasteboardWriteRecorder()
        ConcealedPasteboardWriter.write("LVX-ENROLL-hunter2", to: recorder)
        XCTAssertEqual(recorder.cleared, 1, "the token must replace, not join, prior contents")
        XCTAssertEqual(
            recorder.writes.map(\.string), ["LVX-ENROLL-hunter2", ""],
            "the copy itself must still work — the user needs the token"
        )
        XCTAssertEqual(recorder.writes.map(\.type), [.string, .nsPasteboardConcealed])

        // The declared type set, fed back through the reader: this is the
        // link that makes 'concealed' mean 'harvester skips it'.
        let stub = PasteboardStub(
            string: "LVX-ENROLL-hunter2", types: recorder.writes.map(\.type)
        )
        XCTAssertNil(
            PolishContextClipboardReader.readClipboardContext(from: stub),
            "a concealed token must never reach polish clipboard context"
        )
    }

    // MARK: - Empty / missing string

    func testNoStringReturnsNil() {
        let stub = PasteboardStub(string: nil)
        XCTAssertNil(PolishContextClipboardReader.readClipboardContext(from: stub))
    }

    func testEmptyStringReturnsNil() {
        let stub = PasteboardStub(string: "")
        XCTAssertNil(PolishContextClipboardReader.readClipboardContext(from: stub))
    }

    func testWhitespaceOnlyStringReturnsNil() {
        let stub = PasteboardStub(string: "   \n\t  ")
        XCTAssertNil(PolishContextClipboardReader.readClipboardContext(from: stub))
    }

    // MARK: - Retention

    /// Capture retains; selection happens later against the transcript. The
    /// old `prefix(2000)` head cap is gone: 2500 characters of clipboard is
    /// retained whole, so vocabulary matching can still see character 2400.
    func testRetainsTextWellBeyondTheOldTwoThousandCharacterCap() {
        let raw = String(repeating: "a", count: 2500)
        let stub = PasteboardStub(string: raw)
        let context = PolishContextClipboardReader.readClipboardContext(from: stub)
        XCTAssertEqual(context?.retainedText.count, 2500)
        XCTAssertEqual(context?.retainedText, raw)
        XCTAssertEqual(context?.originalCharacterCount, 2500)
    }

    /// The safety cap is an anti-pathology bound, not a prompt budget: it only
    /// engages far above any hand-copied snippet.
    func testCapsRetainedTextAtTheSafetyCapAndReportsOriginalCount() {
        let raw = String(
            repeating: "a",
            count: PolishContextClipboardReader.retentionCharacterCap + 500
        )
        let stub = PasteboardStub(string: raw)
        let context = PolishContextClipboardReader.readClipboardContext(from: stub)
        XCTAssertEqual(
            context?.retainedText.count,
            PolishContextClipboardReader.retentionCharacterCap
        )
        XCTAssertEqual(
            context?.originalCharacterCount,
            PolishContextClipboardReader.retentionCharacterCap + 500
        )
    }

    func testShortClipboardIsRetainedExactly() {
        let stub = PasteboardStub(string: "abc")
        let context = PolishContextClipboardReader.readClipboardContext(from: stub)
        XCTAssertEqual(context?.retainedText, "abc")
        XCTAssertEqual(context?.originalCharacterCount, 3)
        XCTAssertEqual(context?.provenanceSummary(renderedCharacterCount: 3), "clipboard:3ch")
    }

    // MARK: - Full retained text feeds vocabulary matching

    /// The regression the old `prefix(2000)` head cap caused: a term the user
    /// copied at character ~4000 was invisible to grounding. Retained capture
    /// makes it groundable again.
    func testTermBeyondTheOldTwoThousandCharacterCapStillGrounds() {
        let filler = String(repeating: "unrelated boilerplate prose. ", count: 150)
        XCTAssertGreaterThan(filler.count, 2000, "the term must sit past the old cap")
        let stub = PasteboardStub(string: filler + "\nthrown from PaymentReconciler.swift\n")

        let context = PolishContextClipboardReader.readClipboardContext(from: stub)
        let retained = context?.retainedText ?? ""
        XCTAssertEqual(retained.count, filler.count + 37)
        let outcome = ClipboardVocabulary.candidateOutcome(
            transcript: "the crash in payment reconciler dot swift",
            clipboardText: retained
        )
        XCTAssertTrue(
            outcome.entries.contains { $0.replaceWith == "PaymentReconciler.swift" },
            "a term past character 2000 must still ground; got: \(outcome.entries)"
        )
    }

    /// Rendering and matching are different budgets. The excerpt the model sees
    /// may be a few hundred characters and need not contain the term at all —
    /// grounding is input-side and pre-applies the exact bytes anyway.
    func testMatchingUsesCompleteTextEvenWhenTheRenderedExcerptIsSmaller() {
        let filler = String(repeating: "unrelated boilerplate prose. ", count: 150)
        let clipboard = filler + "\nthrown from PaymentReconciler.swift\n"
        let stub = PasteboardStub(string: clipboard)
        let context = PolishContextClipboardReader.readClipboardContext(from: stub)
        let retained = context?.retainedText ?? ""
        let transcript = "the crash in payment reconciler dot swift"

        // A cap far below the clipboard size: the excerpt is a strict subset.
        let excerpt = PolishContextExcerptSelector.select(
            text: retained,
            transcript: transcript,
            characterCap: 120
        )
        XCTAssertLessThan(excerpt.count, retained.count, "the excerpt must be a reduction")

        // Matching runs over the COMPLETE retained text regardless.
        let outcome = ClipboardVocabulary.candidateOutcome(
            transcript: transcript,
            clipboardText: retained
        )
        XCTAssertTrue(outcome.entries.contains { $0.replaceWith == "PaymentReconciler.swift" })

        // And the exact bytes reach the transcript through pre-application.
        let grounded = RepoVocabularyMatcher.preapplying(
            entries: outcome.entries,
            to: transcript
        )
        XCTAssertTrue(
            grounded.contains("PaymentReconciler.swift"),
            "grounding must survive excerpt reduction; got: \(grounded)"
        )
    }

    /// Small clipboard + room in the budget ⇒ the model sees it exactly as
    /// copied, no selection machinery in the way.
    func testSmallClipboardIsAttachedVerbatimWhenTheBudgetFits() {
        let clipboard = "error in UserSessionManager.swift\n\n  at line 42\n"
        let stub = PasteboardStub(string: clipboard)
        let context = PolishContextClipboardReader.readClipboardContext(from: stub)
        let retained = context?.retainedText ?? ""
        let allocation = PolishContextBudget.allocate(demands: [.clipboard: retained.count])
        let excerpt = PolishContextExcerptSelector.select(
            text: retained,
            transcript: "fix the user session manager",
            characterCap: allocation[.clipboard] ?? 0
        )
        XCTAssertEqual(excerpt, clipboard)
    }

    // MARK: - Control-character stripping

    func testStripsControlCharsButKeepsNewlineAndTab() {
        // NUL and bell dropped; tab and newline preserved.
        let stub = PasteboardStub(string: "a\u{0000}b\tc\nd\u{0007}e")
        let context = PolishContextClipboardReader.readClipboardContext(from: stub)
        XCTAssertEqual(context?.retainedText, "ab\tc\nde")
        XCTAssertEqual(context?.originalCharacterCount, 7)
    }
}

/// Shared pasteboard stub with call counters. Used by the reader unit tests and
/// the view-model clipboard-context tests (`PolishTokenGuardTests.swift`), so
/// the "never read when off" privacy assertion can inspect the call counts.
@MainActor
final class PasteboardStub: PasteboardReading {
    var stubbedTypes: [NSPasteboard.PasteboardType]?
    var stubbedString: String?
    private(set) var typesCallCount = 0
    private(set) var stringCallCount = 0

    init(string: String? = nil, types: [NSPasteboard.PasteboardType]? = nil) {
        self.stubbedString = string
        self.stubbedTypes = types
    }

    func types() -> [NSPasteboard.PasteboardType]? {
        typesCallCount += 1
        return stubbedTypes
    }

    func string() -> String? {
        stringCallCount += 1
        return stubbedString
    }
}

/// Recorder for the write seam (`PasteboardWriting`): what the concealed copy
/// path put on the pasteboard, in order.
@MainActor
private final class PasteboardWriteRecorder: PasteboardWriting {
    private(set) var cleared = 0
    private(set) var writes: [(string: String, type: NSPasteboard.PasteboardType)] = []

    @discardableResult
    func clearContents() -> Int {
        cleared += 1
        return cleared
    }

    @discardableResult
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        writes.append((string: string, type: dataType))
        return true
    }
}
