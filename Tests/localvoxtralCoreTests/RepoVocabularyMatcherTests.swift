import Foundation
import XCTest
@testable import localvoxtralCore

// MARK: - Matcher

final class RepoVocabularyMatcherTests: XCTestCase {
    /// Everything the matcher found for a transcript: the spans it rewrites
    /// plus the sound-alike terms it offers the model. The recall cases below
    /// are about FINDING the term; which channel carries it is pinned in
    /// `SoundAlikeNominationTests`.
    private func found(_ transcript: String, vocabulary: RepoVocabulary) -> [ReplacementEntry] {
        let outcome = RepoVocabularyMatcher.groundedCandidates(
            transcript: transcript, vocabulary: vocabulary
        )
        return outcome.entries + outcome.verificationCandidates
    }

    private func entries(_ transcript: String, terms: [String]) -> [ReplacementEntry] {
        RepoVocabularyMatcher.candidateEntries(
            transcript: transcript,
            vocabulary: RepoVocabulary(terms: terms, branch: nil)
        )
    }

    func testCanonicalExamples() {
        let cases: [(name: String, transcript: String, term: String, heard: String)] = [
            ("CanonicalUseAuthExample", "open use auth dot t s and fix the import", "useAuth.ts", "use auth dot t s"),
            (
                "CanonicalUserSessionManagerExample",
                "rename the user session manager dot swift file",
                "UserSessionManager.swift",
                "user session manager dot swift"
            ),
        ]
        for (name, transcript, term, heard) in cases {
            let result = entries(transcript, terms: [term])
            XCTAssertEqual(result.count, 1, name)
            XCTAssertEqual(result.first?.replaceWith, term, name)
            XCTAssertEqual(result.first?.matches, [heard], name)
        }
    }

    func testEditDistanceOneNearMiss() {
        // "use auth s" -> "useauths" (8), one deletion from "useauthts".
        let result = entries("please use auth s now", terms: ["useAuth.ts"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.replaceWith, "useAuth.ts")
    }

    func testGroundedFuzzyTierAbstainsForTiedDistanceOneCandidates() {
        let transcript = "Open ConfigC.swift."
        let outcome = RepoVocabularyMatcher.groundedCandidates(
            transcript: transcript,
            vocabulary: RepoVocabulary(
                terms: ["ConfigA.swift", "ConfigB.swift"],
                branch: nil
            )
        )

        XCTAssertTrue(outcome.entries.isEmpty, "entries: \(outcome.entries)")
        XCTAssertEqual(
            RepoVocabularyMatcher.preapplying(entries: outcome.entries, to: transcript),
            transcript
        )
        // The tie reaches the model as two terms on offer (the phonetic tier's
        // contested-span rule, unchanged); neither is written for it.
        XCTAssertEqual(
            Set(outcome.verificationCandidates.map(\.replaceWith)),
            ["ConfigA.swift", "ConfigB.swift"]
        )
    }

    func testGroundedCandidatesUseAlignedFallbackAfterExistingMatcherMisses() {
        let result = found("Open uzoft.ts and add a null check.",
            vocabulary: RepoVocabulary(terms: ["useAuth.ts"], branch: nil)
        )
        XCTAssertEqual(
            result,
            [ReplacementEntry(replaceWith: "useAuth.ts", matches: ["uzoft.ts"])]
        )
    }

    func testAlignedFallbackRecoversLongFrenchPhoneticDamage() {
        let result = found("Regarde de dictation vie ou modèle.",
            vocabulary: RepoVocabulary(terms: ["DictationViewModel.swift"], branch: nil)
        )
        XCTAssertEqual(result.first?.replaceWith, "DictationViewModel.swift")
        XCTAssertEqual(result.first?.matches, ["dictation vie ou modèle"])
    }

    func testAlignedFallbackRecoversRecordedContextMisses() {
        let cases: [(transcript: String, exact: String, heard: String)] = [
            (
                "Rebase my brand John to feed/Polish helper MLX Swift.",
                "feat/polish-helper-mlx-swift",
                "feed/Polish helper MLX Swift"
            ),
            (
                "Why is local voxtral cotisin identity not picked up by the runner?",
                "LOCALVOXTRAL_CODESIGN_IDENTITY",
                "local voxtral cotisin identity"
            ),
            (
                "The crash is in Pozik's pipe read next Chong.",
                "POSIXPipeRead.nextChunk(fromDescriptor:)",
                "Pozik's pipe read next Chong"
            ),
            (
                "Pourquoi la variable locale Voxtral co-design identity est ignorée?",
                "LOCALVOXTRAL_CODESIGN_IDENTITY",
                "locale Voxtral co-design identity"
            ),
            (
                "Move the token refresh into off service.ts.",
                "AuthService.ts",
                "service.ts"
            ),
        ]

        for item in cases {
            let result = found(item.transcript,
                vocabulary: RepoVocabulary(terms: [item.exact], branch: nil)
            )
            XCTAssertEqual(result.first?.replaceWith, item.exact, item.transcript)
            XCTAssertEqual(result.first?.matches, [item.heard], item.transcript)
        }
    }

    func testAlignedFallbackAbstainsWhenCandidatesAreAmbiguous() {
        let outcome = RepoVocabularyMatcher.groundedCandidates(
            transcript: "Open auth sir vice here.",
            vocabulary: RepoVocabulary(
                terms: ["AuthService.ts", "AuthServices.ts"],
                branch: nil
            )
        )
        XCTAssertTrue(outcome.entries.isEmpty, "entries: \(outcome.entries)")
        // Neither reading wins, so both are offered and the model decides.
        XCTAssertEqual(
            Set(outcome.verificationCandidates.map(\.replaceWith)),
            ["AuthService.ts", "AuthServices.ts"]
        )
    }

    func testAlignedFallbackAbstains() {
        let cases: [(name: String, transcript: String, terms: [String])] = [
            (
                "AbstainsOnUnrelatedProse",
                "Please improve the error message for users.",
                ["UserSessionManager.swift", "AuthService.ts"]
            ),
            (
                "DoesNotForceUnspokenFileExtensionWithoutFileCue",
                "Fix the user session manager.",
                ["UserSessionManager.swift"]
            ),
            ("AbstainsOnGluedSingleTokenThatWouldDeleteProse", "Ouvreusot.ts maintenant.", ["useAuth.ts"]),
        ]
        for (name, transcript, terms) in cases {
            let result = found(transcript, vocabulary: RepoVocabulary(terms: terms, branch: nil))
            XCTAssertTrue(result.isEmpty, "\(name): entries: \(result)")
        }
    }

    func testPreapplying() {
        let cases: [(name: String, entries: [ReplacementEntry], text: String, expected: String)] = [
            (
                "ApprovedMappingPreservesPunctuation",
                [ReplacementEntry(replaceWith: "useAuth.ts", matches: ["use auth dot t s"])],
                "Open use auth dot t s, then add a null check.",
                "Open useAuth.ts, then add a null check."
            ),
            (
                "ApprovedMappingsUsesLongestAliasFirst",
                [
                    ReplacementEntry(replaceWith: "Auth", matches: ["auth"]),
                    ReplacementEntry(replaceWith: "AuthService.ts", matches: ["auth service dot t s"]),
                ],
                "Open auth service dot t s and inspect auth.",
                "Open AuthService.ts and inspect Auth."
            ),
            // A repo entry and a clipboard entry for the same heard span.
            (
                "RepoClipboardConflictUsesLongerExactTermPrecedence",
                [
                    ReplacementEntry(replaceWith: "RepoAPI", matches: ["heard api"]),
                    ReplacementEntry(replaceWith: "ClipboardAPI", matches: ["heard api"]),
                ],
                "Open heard api.",
                "Open ClipboardAPI."
            ),
            (
                "ApprovedMappingDoesNotRewriteInsideIdentifier",
                [ReplacementEntry(replaceWith: "useAuth.ts", matches: ["auth"])],
                "Keep preauth_handler unchanged.",
                "Keep preauth_handler unchanged."
            ),
            (
                "SkipsUnsafeControlCharacterTerm",
                [ReplacementEntry(replaceWith: "bad\nname.ts", matches: ["bad name"])],
                "Open bad name now.",
                "Open bad name now."
            ),
        ]
        for (name, entries, text, expected) in cases {
            XCTAssertEqual(RepoVocabularyMatcher.preapplying(entries: entries, to: text), expected, name)
        }
    }

    func testFrenchComposedAndDecomposedAccentsFallbackAndPreapplyPreservePunctuation() {
        let accentForms = ["modèle", "mode\u{0300}le"]
        for accentForm in accentForms {
            let transcript = "Regarde, dictation vie ou \(accentForm)."
            let entries = found(transcript,
                vocabulary: RepoVocabulary(
                    terms: ["DictationViewModel.swift"],
                    branch: nil
                )
            )

            XCTAssertEqual(entries.first?.matches, ["dictation vie ou \(accentForm)"])
            XCTAssertEqual(
                RepoVocabularyMatcher.preapplying(entries: entries, to: transcript),
                "Regarde, DictationViewModel.swift."
            )
        }
    }

    func testNonMatchingNGramsYieldNoEntries() {
        let cases: [(name: String, transcript: String, terms: [String])] = [
            // Bare "app"/"src" normalize to < 4 chars: no standalone entries.
            ("ShortFormTermsRejected", "open the app and src", ["app", "src"]),
            // "the file" is all stopwords: never a file match even if it normalizes
            // to a real term.
            ("PureStopwordNGramsRejected", "open the file now", ["thefile"]),
        ]
        for (name, transcript, terms) in cases {
            XCTAssertTrue(entries(transcript, terms: terms).isEmpty, name)
        }
    }

    func testShortComponentCountsInsideLongerNGram() {
        // "app" alone is too short, but "app dot t s x" -> "apptsx" matches app.tsx.
        let result = entries("edit app dot t s x here", terms: ["app.tsx"])
        XCTAssertEqual(result.first?.replaceWith, "app.tsx")
    }

    func testEntryCapAtTwelve() {
        let terms = (0..<15).map { "alphafile\(String(format: "%02d", $0))" }
        let transcript = terms.joined(separator: " ")
        XCTAssertEqual(entries(transcript, terms: terms).count, 12)
    }

    func testRankingLongerNormalizedFirst() {
        let result = entries("config configuration", terms: ["config", "configuration"])
        XCTAssertEqual(result.map(\.replaceWith), ["configuration", "config"])
    }

    func testPromptSectionRendersDictionaryShape() {
        let section = RepoVocabularyMatcher.promptSection(entries: [
            ReplacementEntry(replaceWith: "useAuth.ts", matches: ["use auth dot t s"]),
        ])
        XCTAssertTrue(section.contains("Repository vocabulary"))
        XCTAssertTrue(section.contains("- useAuth.ts: use auth dot t s"))
    }

    func testAppendedSectionStandsAloneWhenBaseEmpty() {
        let appended = RepoVocabularyMatcher.appendedPromptSection(
            base: "",
            entries: [ReplacementEntry(replaceWith: "useAuth.ts", matches: ["use auth"])]
        )
        XCTAssertTrue(appended.hasPrefix("Repository vocabulary"))
    }

    func testAppendedSectionUnchangedWithNoEntries() {
        XCTAssertEqual(
            RepoVocabularyMatcher.appendedPromptSection(base: "Replacement dictionary:\n- x: y", entries: []),
            "Replacement dictionary:\n- x: y"
        )
    }

    func testPromptSectionSanitizesEmbeddedNewlineIntoSingleLine() {
        // `git ls-files -z` preserves newlines in file names; the rendered
        // dictionary line must stay a single intact `- key: aliases` line.
        let section = RepoVocabularyMatcher.promptSection(entries: [
            ReplacementEntry(replaceWith: "use\nAuth.ts", matches: ["use auth dot t s"]),
        ])
        let entryLines = section.split(separator: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(entryLines.count, 1)
        XCTAssertEqual(entryLines.first, "- useAuth.ts: use auth dot t s")
    }

    func testPromptSectionStripsControlCharactersFromAliases() {
        let section = RepoVocabularyMatcher.promptSection(entries: [
            ReplacementEntry(replaceWith: "ok.ts", matches: ["use\u{0007}\tok"]),
        ])
        XCTAssertTrue(section.contains("- ok.ts: useok"))
    }

    func testPromptSectionDropsUnrenderableEntries() {
        // Key empty after sanitization, key reduced to a dash run, and an entry
        // whose every alias sanitizes away: none may render (and with nothing
        // renderable the whole section is empty).
        let section = RepoVocabularyMatcher.promptSection(entries: [
            ReplacementEntry(replaceWith: "\u{0007}\n", matches: ["spoken"]),
            ReplacementEntry(replaceWith: "---", matches: ["spoken"]),
            ReplacementEntry(replaceWith: "ok.ts", matches: ["\n", "\u{0000}"]),
        ])
        XCTAssertEqual(section, "")
    }

    func testCommonComponentWordsDoNotBecomeMatcherEntries() {
        // A repo full of Tests/Resources directories must not turn ordinary
        // prose into capitalization "corrections": the technical-signal gate
        // keeps those components out of the vocabulary entirely.
        let vocab = RepoIndexing.buildVocabulary(
            paths: ["Tests/FooTests.swift", "Resources/image.png"],
            branch: nil
        )
        let entries = RepoVocabularyMatcher.candidateEntries(
            transcript: "run the tests and update the resources please",
            vocabulary: vocab
        )
        XCTAssertTrue(entries.isEmpty, "entries: \(entries)")
    }

    /// 20k generated terms plus one real one, indexed once for both scale
    /// cases: building the index (exact, fuzzy, phonetic and n-gram tiers) is
    /// what a 20k-term vocabulary costs, not matching against it, and neither
    /// case mutates it. The extra term is inert for the abstain case: nothing
    /// in that transcript resembles it.
    private static let largeVocabulary = RepoVocabulary(
        terms: (0..<20_000).map { "GeneratedFile\($0).swift" } + ["useAuth.ts"],
        branch: nil
    )

    func testMatcherHandlesLargeVocabulary() {
        // 20k technical terms x a 300-word transcript. No wall-clock assertion
        // (repo rule) — the guarantee is the complexity restructure (exact tier
        // = one index lookup per gram; fuzzy tier = ±1-length buckets swept at
        // most once per distinct gram); this pins CORRECTNESS at that scale and
        // acts as a canary: a return to O(grams x terms) Levenshtein would make
        // it obviously pathological.
        let vocab = Self.largeVocabulary
        let filler = Array(
            repeating: "please improve overall code quality generally",
            count: 50
        ).joined(separator: " ")
        let transcript = filler + " then open use auth dot t s directly"
        let entries = RepoVocabularyMatcher.candidateEntries(
            transcript: transcript, vocabulary: vocab
        )
        XCTAssertTrue(entries.contains { $0.replaceWith == "useAuth.ts" })
    }

    func testAlignedFallbackAbstainsCleanlyWithLargeAmbiguousVocabulary() {
        let result = RepoVocabularyMatcher.groundedCandidateEntries(
            transcript: "please improve overall error handling for generated files",
            vocabulary: Self.largeVocabulary
        )
        XCTAssertTrue(result.isEmpty, "entries: \(result)")
    }
}

final class ClipboardVocabularyTests: XCTestCase {
    // MARK: - Entity extraction (reuses the guard's recognizer)

    func testEntities() {
        let cases: [(name: String, excerpt: String, expected: [String])] = [
            (
                "RecognizeCodeLikeTokensAndDedupe",
                """
                Fix UserSessionManager.swift and rerun with --force.
                See src/auth/useAuth.ts and $HOME_DIR, then UserSessionManager.swift again.
                """,
                ["UserSessionManager.swift", "--force", "src/auth/useAuth.ts", "$HOME_DIR"]
            ),
            ("UnwrapBacktickSpans", "call `resolveWorkingDirectory` here", ["resolveWorkingDirectory"]),
            (
                "RecognizeBareContextIdentifiersMissedByGuardGrammar",
                "LOCALVOXTRAL_CODESIGN_IDENTITY ShortcutRecorder POSIXPipeRead.nextChunk(fromDescriptor:)",
                [
                    "LOCALVOXTRAL_CODESIGN_IDENTITY",
                    "ShortcutRecorder",
                    "POSIXPipeRead.nextChunk(fromDescriptor:)",
                ]
            ),
            (
                "SupplementalEntityExtractionRejectsOrdinaryClipboardProse",
                "Please remember that authentication service behavior matters",
                []
            ),
            ("ProseExcerptYieldsNoEntities", "just a plain sentence with no code tokens at all", []),
        ]
        for (name, excerpt, expected) in cases {
            XCTAssertEqual(ClipboardVocabulary.entities(inExcerpt: excerpt), expected, name)
        }
    }

    func testSupplementalEntitiesRejectColonAndHyphenatedProse() {
        let cases: [(excerpt: String, transcript: String)] = [
            ("Description: details", "description"),
            ("well-known", "well known"),
        ]

        for item in cases {
            XCTAssertTrue(
                ClipboardVocabulary.entities(inExcerpt: item.excerpt).isEmpty,
                "excerpt: \(item.excerpt)"
            )
            XCTAssertTrue(
                ClipboardVocabulary.candidateEntries(
                    transcript: item.transcript,
                    excerpt: item.excerpt
                ).isEmpty,
                "excerpt: \(item.excerpt)"
            )
        }
    }

    // MARK: - Transcript matching (same matcher as repo vocabulary)

    /// The T5 field case (2026-07-11): clipboard holds the exact identifier,
    /// the STT glued the dictated tail into `manager.swift`. The transcript
    /// n-gram must match the clipboard entity and yield the structured
    /// (spoken, exact) pair the session can pre-apply before polishing.
    func testT5TranscriptGramMatchesClipboardEntity() {
        let result = ClipboardVocabulary.candidateEntries(
            transcript: "look at user session manager.swift",
            excerpt: "UserSessionManager.swift"
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.replaceWith, "UserSessionManager.swift")
        XCTAssertEqual(result.first?.matches, ["user session manager.swift"])
    }

    func testSupplementalEntitiesGroundCommonTechnicalDictationDamage() {
        let cases: [(transcript: String, excerpt: String, expected: String)] = [
            (
                "set local voxtral code sign identity before packaging",
                "LOCALVOXTRAL_CODESIGN_IDENTITY",
                "LOCALVOXTRAL_CODESIGN_IDENTITY"
            ),
            (
                "the crash is in posix pipe read next chunk from descriptor",
                "POSIXPipeRead.nextChunk(fromDescriptor:)",
                "POSIXPipeRead.nextChunk(fromDescriptor:)"
            ),
            (
                "check whether shortcut recorder is initialized",
                "ShortcutRecorder",
                "ShortcutRecorder"
            ),
        ]

        for testCase in cases {
            let outcome = ClipboardVocabulary.candidateOutcome(
                transcript: testCase.transcript,
                clipboardText: testCase.excerpt
            )
            let result = outcome.entries + outcome.verificationCandidates
            XCTAssertEqual(
                result.first?.replaceWith,
                testCase.expected,
                "transcript: \(testCase.transcript); entries: \(result)"
            )
        }
    }

    func testUnrelatedTranscriptYieldsNoEntries() {
        XCTAssertTrue(
            ClipboardVocabulary.candidateEntries(
                transcript: "completely unrelated dictation about lunch",
                excerpt: "UserSessionManager.swift"
            ).isEmpty
        )
    }
}
