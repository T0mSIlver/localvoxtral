import XCTest
@testable import localvoxtralCore

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

    /// Each hit below is real evidence of a mishearing but too weak to rewrite
    /// the user's bytes, so it must survive only as a possible-mishearing
    /// candidate for the model: no entry, no phonetic pre-apply, the
    /// transcript untouched.
    func testNearHitsAreOfferedToTheModelAndNeverWritten() {
        let cases: [(name: String, transcript: String, terms: [String], offered: ReplacementEntry)] = [
            // `clothes code` is one phonetic-key edit from `Claude Code`.
            (
                "ClaudeCodeNearPhoneticHit", "open clothes code please", ["Claude Code"],
                ReplacementEntry(replaceWith: "Claude Code", matches: ["clothes code"])
            ),
            // `pain` and `pane` have equal full-length keys, the strongest
            // phonetic evidence there is. It still only nominates.
            (
                "TerminalPaneExactPhoneticHit", "click the terminal pain", ["terminal pane"],
                ReplacementEntry(replaceWith: "terminal pane", matches: ["terminal pain"])
            ),
            // A multi-word term that glues a stopword onto a short homophone:
            // both the heard span and the agreeing key are too short for the
            // pre-apply grade.
            (
                "StopwordGluedShortHomophone", "the pain is here", ["thePane"],
                ReplacementEntry(replaceWith: "thePane", matches: ["the pain"])
            ),
        ]
        for (name, transcript, terms, offered) in cases {
            let outcome = RepoVocabularyMatcher.groundedCandidates(
                transcript: transcript,
                vocabulary: makeVocabulary(terms)
            )

            XCTAssertTrue(outcome.entries.isEmpty, name)
            XCTAssertTrue(outcome.phoneticEntries.isEmpty, name)
            XCTAssertEqual(outcome.verificationCandidates, [offered], name)
            XCTAssertEqual(
                RepoVocabularyMatcher.preapplying(
                    entries: outcome.entries + outcome.phoneticEntries, to: transcript
                ),
                transcript,
                name
            )
        }
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

    /// Terms the phonetic tier must leave alone: too short a single word,
    /// only common heard words, or a gram a stronger tier already owns.
    func testPhoneticTierAbstainsWhereItIsNotEligibleOrAStrongerTierOwnsTheGram() {
        let cases: [(name: String, transcript: String, terms: [String])] = [
            ("ShortSingleWordClaudeVsClose", "please close this", ["Claude"]),
            ("ShortSingleWordClaudeVsClothes", "fold the clothes please", ["Claude"]),
            ("ShortSingleWordPaneVsPain", "the pain is visible", ["pane"]),
            ("AllCommonHeardWordsNeverFire", "in the", ["innThy"]),
            ("IdenticalGramBelongsToExactTier", "open terminal pane", ["terminal pane"]),
            ("EditDistanceOneGramBelongsToFuzzyTier", "open terminal pan", ["terminal pane"]),
        ]
        for (name, transcript, terms) in cases {
            XCTAssertEqual(phonetic(transcript, terms: terms), .empty, name)
        }
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

    func testPhoneticWordUnits() {
        let cases: [(name: String, text: String, expected: [String])] = [
            ("SplitsIdentifierBoundaries", "useAuth.ts", ["use", "Auth", "ts"]),
            (
                "SplitsRepositoryBoundaries", "src/session_sync/HTTP2Client",
                ["src", "session", "sync", "HTTP", "2Client"]
            ),
            ("SplitsHyphensAndSpaces", "alpha-beta gamma", ["alpha", "beta", "gamma"]),
            ("DropsEmptyUnits", "///__--", []),
            ("DropsNonLetterUnits", "model2/123/_pane", ["model", "pane"]),
        ]
        for (name, text, expected) in cases {
            XCTAssertEqual(RepoVocabularyMatcher.phoneticWordUnits(of: text), expected, name)
        }
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
    }

    func testAlignedDemotionsKeepTheGuessOnlyAsVerification() {
        let cases: [(name: String, transcript: String, terms: [String], verification: [ReplacementEntry])] = [
            (
                "NearScoreDemotesBestCandidate", "abcx efyy", ["abcdefghij"],
                [ReplacementEntry(replaceWith: "abcdefghij", matches: ["abcx efyy"])]
            ),
            (
                "UnspokenExtensionDemotesBestCandidate", "Fix the user session manager.",
                ["UserSessionManager.swift"],
                [ReplacementEntry(replaceWith: "UserSessionManager.swift", matches: ["user session manager"])]
            ),
            // A single word that would inflate in length stays a hard drop.
            ("SingleWordLengthInflationRemainsHardDrop", "Ouvreusot.ts maintenant.", ["useAuth.ts"], []),
        ]
        for (name, transcript, terms, verification) in cases {
            let outcome = RepoVocabularyMatcher.alignedFallbackOutcome(
                transcript: transcript,
                vocabulary: makeVocabulary(terms)
            )

            XCTAssertNil(outcome.approved, name)
            XCTAssertEqual(outcome.verification, verification, name)
        }
    }

    func testAlignedFallbackApprovesAConfidentSingleCandidate() {
        XCTAssertEqual(
            RepoVocabularyMatcher.alignedFallbackOutcome(
                transcript: "Open uzoft.ts and add a null check.",
                vocabulary: makeVocabulary(["useAuth.ts"])
            ).approved,
            ReplacementEntry(replaceWith: "useAuth.ts", matches: ["uzoft.ts"])
        )
    }
}
