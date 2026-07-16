import XCTest
@testable import localvoxtral

final class PolishContextGroundingTests: XCTestCase {
    private func candidate(
        _ source: PolishContextSource,
        _ entries: [(exact: String, heard: [String])],
        fallbackOnly: Bool = false
    ) -> PolishContextGrounding.Candidate {
        PolishContextGrounding.Candidate(
            source: source,
            entries: entries.map { ReplacementEntry(replaceWith: $0.exact, matches: $0.heard) },
            isFallbackOnly: fallbackOnly
        )
    }

    // MARK: - Agreement

    /// Two sources proposing the SAME term for the same span corroborate each
    /// other. One entry out, not two identical ones.
    func testIdenticalTermForTheSameSpanCollapsesToOneEntry() {
        let merged = PolishContextGrounding.merge([
            candidate(.repository, [(exact: "useAuth.ts", heard: ["use auth dot ts"])]),
            candidate(.clipboard, [(exact: "useAuth.ts", heard: ["use auth dot ts"])]),
        ])
        XCTAssertEqual(merged.all.count, 1)
        XCTAssertEqual(merged.all.first?.replaceWith, "useAuth.ts")
        XCTAssertEqual(merged.all.first?.matches, ["use auth dot ts"])
    }

    /// Agreement attributes the term to the earlier rank ONCE — it must not be
    /// rendered under two prompt headers.
    func testAgreedTermIsAttributedToTheEarlierRankOnly() {
        let merged = PolishContextGrounding.merge([
            candidate(.clipboard, [(exact: "useAuth.ts", heard: ["use auth dot ts"])]),
            candidate(.repository, [(exact: "useAuth.ts", heard: ["use auth dot ts"])]),
        ])
        XCTAssertEqual(merged.entries(from: .repository).count, 1)
        XCTAssertTrue(merged.entries(from: .clipboard).isEmpty)
    }

    /// Sources may have heard the same span written differently; that must
    /// still corroborate rather than pass by.
    func testAgreementIsDetectedAcrossSpanSpellingDifferences() {
        let merged = PolishContextGrounding.merge([
            candidate(.repository, [(exact: "useAuth.ts", heard: ["use auth dot ts"])]),
            candidate(.clipboard, [(exact: "useAuth.ts", heard: ["use-auth dot ts"])]),
        ])
        XCTAssertEqual(merged.all.count, 1, "one term, one entry")
        XCTAssertEqual(
            merged.all.first?.matches, ["use auth dot ts", "use-auth dot ts"],
            "both literal spans survive: pre-application matches literal bytes"
        )
    }

    // MARK: - Conflict

    /// The core safety rule: nothing here can tell which source is right, and
    /// pre-applying the wrong bytes edits words the user did not say.
    func testSameSpanMappingToDistinctTermsAbstainsEntirely() {
        let merged = PolishContextGrounding.merge([
            candidate(.repository, [(exact: "useAuth.ts", heard: ["use auth dot ts"])]),
            candidate(.clipboard, [(exact: "useAuth.tsx", heard: ["use auth dot ts"])]),
        ])
        XCTAssertTrue(merged.all.isEmpty, "a contested span must ground to nothing")
        XCTAssertTrue(merged.entries(from: .repository).isEmpty)
        XCTAssertTrue(merged.entries(from: .clipboard).isEmpty)
    }

    /// Abstention is surgical: it removes the contested span, not the whole
    /// source's useful work.
    func testConflictOnOneSpanLeavesOtherSpansGrounded() {
        let merged = PolishContextGrounding.merge([
            candidate(.repository, [
                (exact: "useAuth.ts", heard: ["use auth dot ts"]),
                (exact: "PaymentReconciler.swift", heard: ["payment reconciler dot swift"]),
            ]),
            candidate(.clipboard, [(exact: "useAuth.tsx", heard: ["use auth dot ts"])]),
        ])
        XCTAssertEqual(merged.all.map(\.replaceWith), ["PaymentReconciler.swift"])
    }

    /// A conflict is per-SPAN, not per-term: two sources may legitimately
    /// propose different terms for different spans.
    func testDistinctSpansWithDistinctTermsBothSurvive() {
        let merged = PolishContextGrounding.merge([
            candidate(.repository, [(exact: "useAuth.ts", heard: ["use auth dot ts"])]),
            candidate(.clipboard, [(exact: "Session.swift", heard: ["session dot swift"])]),
        ])
        XCTAssertEqual(merged.all.count, 2)
        XCTAssertEqual(merged.entries(from: .repository).map(\.replaceWith), ["useAuth.ts"])
        XCTAssertEqual(merged.entries(from: .clipboard).map(\.replaceWith), ["Session.swift"])
    }

    /// Conflict beats agreement: two sources agreeing does not license
    /// overriding a third that disagrees on the same span.
    func testAgreementBetweenTwoSourcesDoesNotOutvoteAThirdOnTheSameSpan() {
        let merged = PolishContextGrounding.merge([
            candidate(.repository, [(exact: "useAuth.ts", heard: ["use auth dot ts"])]),
            candidate(.terminal, [(exact: "useAuth.ts", heard: ["use auth dot ts"])]),
            candidate(.clipboard, [(exact: "useAuth.tsx", heard: ["use auth dot ts"])]),
        ])
        XCTAssertTrue(merged.all.isEmpty, "this merge abstains, it does not vote")
    }

    // MARK: - Fallback yields to a solid hit

    func testFallbackOnlyGuessIsDroppedWhenAnotherSourceHasASolidHitOnTheSpan() {
        let merged = PolishContextGrounding.merge([
            candidate(.repository, [(exact: "useAuth.ts", heard: ["use auth dot ts"])]),
            candidate(
                .clipboard,
                [(exact: "useAuthHook.tsx", heard: ["use auth dot ts"])],
                fallbackOnly: true
            ),
        ])
        XCTAssertEqual(
            merged.all.map(\.replaceWith), ["useAuth.ts"],
            "the guess must yield rather than contest the solid hit into abstention"
        )
    }

    /// Order-independent: the guess still yields when it is presented first.
    func testFallbackYieldsRegardlessOfCandidateOrder() {
        let merged = PolishContextGrounding.merge([
            candidate(
                .clipboard,
                [(exact: "useAuthHook.tsx", heard: ["use auth dot ts"])],
                fallbackOnly: true
            ),
            candidate(.repository, [(exact: "useAuth.ts", heard: ["use auth dot ts"])]),
        ])
        XCTAssertEqual(merged.all.map(\.replaceWith), ["useAuth.ts"])
    }

    /// A guess on an UNCONTESTED span is still useful — it is dropped only
    /// where a better-grounded source covers the same span.
    func testFallbackSurvivesOnASpanNoSolidSourceCovers() {
        let merged = PolishContextGrounding.merge([
            candidate(.repository, [(exact: "useAuth.ts", heard: ["use auth dot ts"])]),
            candidate(
                .clipboard,
                [(exact: "PaymentReconciler.swift", heard: ["paint reconciler dot swift"])],
                fallbackOnly: true
            ),
        ])
        XCTAssertEqual(
            Set(merged.all.map(\.replaceWith)),
            ["useAuth.ts", "PaymentReconciler.swift"]
        )
    }

    /// Two guesses disagreeing on one span is still a conflict — being a guess
    /// does not exempt it from abstention.
    func testTwoFallbackGuessesConflictingOnASpanAbstain() {
        let merged = PolishContextGrounding.merge([
            candidate(.repository, [(exact: "useAuth.ts", heard: ["use auth dot ts"])],
                      fallbackOnly: true),
            candidate(.clipboard, [(exact: "useAuth.tsx", heard: ["use auth dot ts"])],
                      fallbackOnly: true),
        ])
        XCTAssertTrue(merged.all.isEmpty)
    }

    // MARK: - Shape and determinism

    func testEmptyCandidatesMergeToNothing() {
        XCTAssertTrue(PolishContextGrounding.merge([]).all.isEmpty)
        XCTAssertTrue(
            PolishContextGrounding.merge([candidate(.clipboard, [])]).all.isEmpty
        )
    }

    func testSingleSourcePassesThroughUnchanged() {
        let merged = PolishContextGrounding.merge([
            candidate(.clipboard, [
                (exact: "useAuth.ts", heard: ["use auth dot ts"]),
                (exact: "Session.swift", heard: ["session dot swift"]),
            ]),
        ])
        XCTAssertEqual(merged.all.map(\.replaceWith), ["useAuth.ts", "Session.swift"])
        XCTAssertEqual(merged.entries(from: .clipboard).count, 2)
    }

    func testMergeIsDeterministic() {
        let candidates = [
            candidate(.clipboard, [
                (exact: "Session.swift", heard: ["session dot swift"]),
                (exact: "useAuth.ts", heard: ["use auth dot ts"]),
            ]),
            candidate(.repository, [
                (exact: "useAuth.ts", heard: ["use auth dot ts"]),
                (exact: "Payment.swift", heard: ["payment dot swift"]),
            ]),
        ]
        let first = PolishContextGrounding.merge(candidates)
        for _ in 0..<25 {
            XCTAssertEqual(PolishContextGrounding.merge(candidates), first)
        }
    }

    /// Entries come out in source-rank order regardless of the caller's order.
    func testEntriesAreOrderedBySourceRank() {
        let merged = PolishContextGrounding.merge([
            candidate(.clipboard, [(exact: "Session.swift", heard: ["session dot swift"])]),
            candidate(.repository, [(exact: "useAuth.ts", heard: ["use auth dot ts"])]),
        ])
        XCTAssertEqual(merged.all.map(\.replaceWith), ["useAuth.ts", "Session.swift"])
    }
}
