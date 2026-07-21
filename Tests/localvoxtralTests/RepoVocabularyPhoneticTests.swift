import XCTest
@testable import localvoxtral

final class RepoVocabularyPhoneticTests: XCTestCase {
    private func makeVocabulary(_ terms: [String]) -> RepoVocabulary {
        RepoVocabulary(terms: terms, branch: nil)
    }

    private func phonetic(_ transcript: String, terms: [String])
        -> RepoVocabularyMatcher.PhoneticOutcome
    {
        RepoVocabularyMatcher.phoneticCandidates(
            transcript: transcript,
            vocabulary: makeVocabulary(terms)
        )
    }

    // MARK: - Field regressions

    /// `clothes code` is one phonetic-key edit from `Claude Code`, not enough
    /// evidence to rewrite the user's bytes. It must nevertheless survive as
    /// an explicit possible-mishearing candidate for the model.
    func testClaudeCodeNearPhoneticHitIsVerificationOnly() {
        let outcome = RepoVocabularyMatcher.groundedCandidates(
            transcript: "open clothes code please",
            vocabulary: makeVocabulary(["Claude Code"])
        )

        XCTAssertTrue(outcome.entries.isEmpty)
        XCTAssertTrue(outcome.phoneticEntries.isEmpty)
        XCTAssertEqual(
            outcome.verificationCandidates,
            [ReplacementEntry(replaceWith: "Claude Code", matches: ["clothes code"])]
        )
    }

    /// `pain` and `pane` have equal full-length keys. The surrounding word
    /// makes the term eligible and preserves per-word alignment, so the sole
    /// exact-key owner is safe at the phonetic guess grade.
    func testTerminalPaneExactPhoneticHitPreApplies() {
        let transcript = "click the terminal pain"
        let outcome = RepoVocabularyMatcher.groundedCandidates(
            transcript: transcript,
            vocabulary: makeVocabulary(["terminal pane"])
        )

        XCTAssertTrue(outcome.entries.isEmpty)
        XCTAssertEqual(
            outcome.phoneticEntries,
            [ReplacementEntry(replaceWith: "terminal pane", matches: ["terminal pain"])]
        )
        XCTAssertEqual(
            RepoVocabularyMatcher.preapplying(entries: outcome.phoneticEntries, to: transcript),
            "click the terminal pane"
        )
    }

    /// A multi-word term that glues a stopword onto a short homophone must
    /// not silently rewrite prose: both the heard span and the agreeing key
    /// are too short for the pre-apply grade. The guess survives only as a
    /// verification pair.
    func testStopwordGluedShortHomophoneIsVerificationOnly() {
        let transcript = "the pain is here"
        let outcome = RepoVocabularyMatcher.groundedCandidates(
            transcript: transcript,
            vocabulary: makeVocabulary(["thePane"])
        )

        XCTAssertTrue(outcome.entries.isEmpty)
        XCTAssertTrue(outcome.phoneticEntries.isEmpty)
        XCTAssertEqual(
            outcome.verificationCandidates,
            [ReplacementEntry(replaceWith: "thePane", matches: ["the pain"])]
        )
        XCTAssertEqual(
            RepoVocabularyMatcher.preapplying(
                entries: outcome.phoneticEntries, to: transcript
            ),
            transcript
        )
    }

    /// A span the character tiers abstained on because two terms tied is
    /// contested: a phonetic guess on those same bytes must not silently
    /// rewrite them either, and demotes to verification.
    func testCharacterTierAmbiguityBlocksPhoneticPreApplyOnThatSpan() {
        let outcome = RepoVocabularyMatcher.groundedCandidates(
            transcript: "flush remainder then click the terminal pain",
            vocabulary: makeVocabulary([
                "flushRemainder",
                "terminal pane",
                "terminal_pains",
                "terminal painz",
            ])
        )

        XCTAssertEqual(
            outcome.entries,
            [ReplacementEntry(replaceWith: "flushRemainder", matches: ["flush remainder"])]
        )
        XCTAssertTrue(outcome.phoneticEntries.isEmpty)
        XCTAssertEqual(
            outcome.verificationCandidates,
            [ReplacementEntry(replaceWith: "terminal pane", matches: ["terminal pain"])]
        )
    }

    // MARK: - Eligibility and stronger-tier ownership

    func testShortSingleWordClaudeDoesNotMatchCloseOrClothes() {
        for transcript in ["please close this", "fold the clothes please"] {
            XCTAssertEqual(phonetic(transcript, terms: ["Claude"]), .empty, transcript)
        }
    }

    func testShortSingleWordPaneDoesNotMatchPain() {
        XCTAssertEqual(phonetic("the pain is visible", terms: ["pane"]), .empty)
    }

    func testAllCommonHeardWordsNeverFire() {
        XCTAssertEqual(phonetic("in the", terms: ["innThy"]), .empty)
    }

    func testIdenticalGramBelongsToExactTier() {
        XCTAssertEqual(
            phonetic("open terminal pane", terms: ["terminal pane"]),
            .empty
        )
    }

    func testEditDistanceOneGramBelongsToFuzzyTier() {
        XCTAssertEqual(
            phonetic("open terminal pan", terms: ["terminal pane"]),
            .empty
        )
    }

    // MARK: - Confidence demotions

    /// Two local spellings sharing an exact pronunciation cannot choose each
    /// other by vocabulary order. Both remain suggestions and neither edits.
    func testExactPhoneticAmbiguityEmitsBothAsVerification() {
        let outcome = phonetic(
            "refresh the nite cash",
            terms: ["night cache", "knight cache"]
        )

        XCTAssertTrue(outcome.preApply.isEmpty)
        XCTAssertEqual(
            outcome.verification,
            [
                ReplacementEntry(replaceWith: "knight cache", matches: ["nite cash"]),
                ReplacementEntry(replaceWith: "night cache", matches: ["nite cash"]),
            ]
        )
    }

    /// Pronunciation cannot establish that an unspoken extension belongs in
    /// the transcript, even for an otherwise exact and unique key.
    func testUnspokenExtensionDemotesExactPhoneticHit() {
        let outcome = phonetic(
            "open terminal pain coat",
            terms: ["terminal_pane.code"]
        )

        XCTAssertTrue(outcome.preApply.isEmpty)
        XCTAssertEqual(
            outcome.verification,
            [
                ReplacementEntry(
                    replaceWith: "terminal_pane.code",
                    matches: ["terminal pain coat"]
                ),
            ]
        )
    }

    // MARK: - Word-unit splitting

    func testPhoneticWordUnitsSplitRepositoryAndIdentifierBoundaries() {
        XCTAssertEqual(
            RepoVocabularyMatcher.phoneticWordUnits(of: "useAuth.ts"),
            ["use", "Auth", "ts"]
        )
        XCTAssertEqual(
            RepoVocabularyMatcher.phoneticWordUnits(of: "src/session_sync/HTTP2Client"),
            ["src", "session", "sync", "HTTP", "2Client"]
        )
        XCTAssertEqual(
            RepoVocabularyMatcher.phoneticWordUnits(of: "alpha-beta gamma"),
            ["alpha", "beta", "gamma"]
        )
    }

    func testPhoneticWordUnitsDropEmptyAndNonLetterUnits() {
        XCTAssertEqual(RepoVocabularyMatcher.phoneticWordUnits(of: "///__--"), [])
        XCTAssertEqual(
            RepoVocabularyMatcher.phoneticWordUnits(of: "model2/123/_pane"),
            ["model", "pane"]
        )
    }

    func testIndexEligibilityIncludesLongSinglesAndPhrasesButSkipsLongIdentifiers() {
        let vocabulary = makeVocabulary([
            "configuration",
            "short",
            "oneTwo",
            "oneTwoThreeFourFive",
        ])

        XCTAssertEqual(
            vocabulary.phoneticCandidates.map(\.term),
            ["configuration", "oneTwo"]
        )
        XCTAssertTrue(
            vocabulary.phoneticBuckets.values.flatMap { $0 }
                .allSatisfy { $0.variant.count >= 4 }
        )
    }

    // MARK: - Bounds and in-source precedence

    func testVerificationCapAndOrderAreDeterministic() {
        let terms = [
            "alphaPane.code",
            "bravoPane.code",
            "deltaPane.code",
            "gammaPane.code",
            "sigmaPane.code",
            "tangoPane.code",
        ]
        let transcript = [
            "alpha pain coat",
            "bravo pain coat",
            "delta pain coat",
            "gamma pain coat",
            "sigma pain coat",
            "tango pain coat",
        ].joined(separator: " then ")
        let expected = [
            ReplacementEntry(replaceWith: "alphaPane.code", matches: ["alpha pain coat"]),
            ReplacementEntry(replaceWith: "bravoPane.code", matches: ["bravo pain coat"]),
            ReplacementEntry(replaceWith: "deltaPane.code", matches: ["delta pain coat"]),
            ReplacementEntry(replaceWith: "gammaPane.code", matches: ["gamma pain coat"]),
        ]

        XCTAssertEqual(phonetic(transcript, terms: terms).verification, expected)
        XCTAssertEqual(phonetic(transcript, terms: terms).verification, expected)
    }

    func testSolidSpanDropsPhoneticSuggestionOnTheSameNormalizedHeardBytes() {
        let outcome = RepoVocabularyMatcher.groundedCandidates(
            transcript: "open clothes code please",
            vocabulary: makeVocabulary(["clothes code", "Claude Code"])
        )

        XCTAssertEqual(
            outcome.entries,
            [ReplacementEntry(replaceWith: "clothes code", matches: ["clothes code"])]
        )
        XCTAssertTrue(outcome.phoneticEntries.isEmpty)
        XCTAssertTrue(outcome.verificationCandidates.isEmpty)
    }

    // MARK: - Aligned fallback verification demotions

    func testAlignedMarginFailureDemotesBestAndRunnerUp() {
        let vocabulary = makeVocabulary(["AuthService.ts", "AuthServices.ts"])
        let outcome = RepoVocabularyMatcher.alignedFallbackOutcome(
            transcript: "Open auth sir vice here.",
            vocabulary: vocabulary
        )

        XCTAssertNil(outcome.approved)
        XCTAssertEqual(outcome.verification.count, 2)
        XCTAssertEqual(
            Set(outcome.verification.map(\.replaceWith)),
            Set(["AuthService.ts", "AuthServices.ts"])
        )
        XCTAssertNil(
            RepoVocabularyMatcher.alignedFallbackEntry(
                transcript: "Open auth sir vice here.",
                vocabulary: vocabulary
            )
        )
    }

    func testAlignedNearScoreDemotesBestCandidate() {
        let vocabulary = makeVocabulary(["abcdefghij"])
        let outcome = RepoVocabularyMatcher.alignedFallbackOutcome(
            transcript: "abcx efyy",
            vocabulary: vocabulary
        )

        XCTAssertNil(outcome.approved)
        XCTAssertEqual(
            outcome.verification,
            [ReplacementEntry(replaceWith: "abcdefghij", matches: ["abcx efyy"])]
        )
        XCTAssertNil(
            RepoVocabularyMatcher.alignedFallbackEntry(
                transcript: "abcx efyy",
                vocabulary: vocabulary
            )
        )
    }

    func testAlignedUnspokenExtensionDemotesBestCandidate() {
        let vocabulary = makeVocabulary(["UserSessionManager.swift"])
        let outcome = RepoVocabularyMatcher.alignedFallbackOutcome(
            transcript: "Fix the user session manager.",
            vocabulary: vocabulary
        )

        XCTAssertNil(outcome.approved)
        XCTAssertEqual(
            outcome.verification,
            [
                ReplacementEntry(
                    replaceWith: "UserSessionManager.swift",
                    matches: ["user session manager"]
                ),
            ]
        )
        XCTAssertNil(
            RepoVocabularyMatcher.alignedFallbackEntry(
                transcript: "Fix the user session manager.",
                vocabulary: vocabulary
            )
        )
    }

    func testAlignedSingleWordLengthInflationRemainsHardDrop() {
        let vocabulary = makeVocabulary(["useAuth.ts"])
        let outcome = RepoVocabularyMatcher.alignedFallbackOutcome(
            transcript: "Ouvreusot.ts maintenant.",
            vocabulary: vocabulary
        )

        XCTAssertNil(outcome.approved)
        XCTAssertTrue(outcome.verification.isEmpty)
    }

    func testAlignedWrapperStillReturnsApprovedFallback() {
        XCTAssertEqual(
            RepoVocabularyMatcher.alignedFallbackEntry(
                transcript: "Open uzoft.ts and add a null check.",
                vocabulary: makeVocabulary(["useAuth.ts"])
            ),
            ReplacementEntry(replaceWith: "useAuth.ts", matches: ["uzoft.ts"])
        )
    }
}
