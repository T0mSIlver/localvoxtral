import XCTest
@testable import localvoxtral

/// Field regressions from the owner's dictation history (2026-09-18): the
/// sound-alike tiers wrote code terms over ordinary prose before the model saw
/// the text. Only a span that normalizes to the term itself may rewrite the
/// transcript now; everything else is a term offered to the model.
final class SoundAlikeNominationTests: XCTestCase {
    private func outcome(_ transcript: String, terms: [String])
        -> RepoVocabularyMatcher.GroundingOutcome
    {
        RepoVocabularyMatcher.groundedCandidates(
            transcript: transcript,
            vocabulary: RepoVocabulary(terms: terms, branch: nil)
        )
    }

    private func preapplied(_ transcript: String, terms: [String]) -> String {
        let result = outcome(transcript, terms: terms)
        return RepoVocabularyMatcher.preapplying(
            entries: result.entries + result.phoneticEntries,
            to: transcript
        )
    }

    func testExactNormalizedSpanStillPreApplies() {
        let transcript = "open use auth dot ts please"
        XCTAssertEqual(
            preapplied(transcript, terms: ["useAuth.ts"]),
            "open useAuth.ts please"
        )
    }

    func testEditDistanceOneHitIsNominatedNotPreApplied() {
        let transcript = "look at the settings stor file"
        let result = outcome(transcript, terms: ["SettingsStore"])

        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.verificationCandidates.map(\.replaceWith), ["SettingsStore"])
        XCTAssertEqual(preapplied(transcript, terms: ["SettingsStore"]), transcript)
    }

    func testExactPhoneticKeyHitIsNominatedNotPreApplied() {
        let transcript = "click the terminal pain"
        let result = outcome(transcript, terms: ["terminal pane"])

        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertTrue(result.phoneticEntries.isEmpty)
        XCTAssertEqual(result.verificationCandidates.map(\.replaceWith), ["terminal pane"])
        XCTAssertEqual(preapplied(transcript, terms: ["terminal pane"]), transcript)
    }

    /// "local Voxtral" came back as `localvoxtral.js` twice in the field, and
    /// every model tried repeated it when the file name was merely offered.
    func testFileNameWithUnspokenExtensionIsNeverOffered() {
        let transcript = "the way microphones are proposed in local Voxtral"
        let result = outcome(transcript, terms: ["localvoxtral.js"])

        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertTrue(result.phoneticEntries.isEmpty)
        XCTAssertTrue(result.verificationCandidates.isEmpty)
    }

    func testSpokenExtensionOrFileCueKeepsTheFileNameOnOffer() {
        func withheld(_ term: String, _ heard: String, in transcript: String) -> Bool {
            RepoVocabularyMatcher.addsUnspokenExtension(
                term: term, heard: heard, transcript: transcript
            )
        }
        XCTAssertFalse(withheld(
            "localvoxtral.js", "local voxtral dot js", in: "fix local voxtral dot js"
        ))
        XCTAssertFalse(withheld("localvoxtral.js", "localvoxtral.js", in: "fix localvoxtral.js"))
        XCTAssertTrue(withheld("localvoxtral.js", "local Voxtral", in: "proposed in local Voxtral"))
        XCTAssertFalse(withheld(
            "DictationViewModel.swift", "dictation vie ou modèle",
            in: "Regarde, dictation vie ou modèle."
        ))
        XCTAssertFalse(withheld("SessionStart", "session", in: "after starting a session"))
        // Letters spoken one by one after the separator.
        XCTAssertFalse(withheld("useAuth.ts", "use auth dot t s", in: "fix use auth dot t s"))
        XCTAssertTrue(withheld("useAuth.ts", "use auth dots", in: "fix use auth dots"))
        // The cue may precede a later occurrence of the span.
        XCTAssertFalse(withheld(
            "SettingsView.swift", "settings view",
            in: "the settings view is slow, so open settings view"
        ))
    }

    /// A term one source already wrote into the transcript is not offered
    /// again from another source's damaged span.
    func testPreAppliedTermIsNotAlsoOffered() {
        let merged = PolishContextGrounding.merge([
            .init(
                source: .repository,
                entries: [ReplacementEntry(replaceWith: "ConfigStore", matches: ["config store"])],
                isFallbackOnly: false
            ),
            .init(
                source: .clipboard,
                entries: [],
                isFallbackOnly: false,
                verificationEntries: [
                    ReplacementEntry(replaceWith: "ConfigStore", matches: ["config stor"]),
                    ReplacementEntry(replaceWith: "ConfigLoader", matches: ["config lauder"]),
                ]
            ),
        ])

        XCTAssertEqual(merged.all.map(\.replaceWith), ["ConfigStore"])
        XCTAssertEqual(merged.verificationPairs.map(\.exact), ["ConfigLoader"])
    }

    /// French "Sans" equals the flag `--sans` once dashes are ignored. One
    /// word may only change its letter case.
    func testLoneWordOnlyChangesLetterCase() {
        XCTAssertEqual(
            preapplied("Sans objectif défini clair", terms: ["--sans"]),
            "Sans objectif défini clair"
        )
        XCTAssertEqual(
            preapplied("the sessionstart hook fires late", terms: ["SessionStart"]),
            "the SessionStart hook fires late"
        )
    }

    /// Prose from the field that was rewritten with hook and flag names on
    /// screen. None of it may change before the model sees it.
    func testFieldProseIsNotRewrittenByScreenTerms() {
        let terms = ["toolInput", "SessionStart", "--sans", "OpenShift", "localvoxtral.js"]
        for transcript in [
            "Une fois qu'on a ces liens, on peut voir quelque chose d'assez intéressant",
            "I just noticed that after starting a session I can join it",
            "Well, the first issue is that the update button is truncated",
            "qu'avec les modèles OpenAI et Codex",
            "Sans objectif défini clair, aboutir à une démo",
        ] {
            XCTAssertEqual(preapplied(transcript, terms: terms), transcript)
        }
    }

    /// Rendered as `"heard" -> "term"` pairs, models applied the pair as an
    /// instruction. The section names terms only.
    func testNominationsRenderAsTermsWithoutTheHeardSpan() {
        let section = RepoVocabularyMatcher.verificationPromptSection(pairs: [
            .init(heard: "plateforme Docs Public", exact: "platform-docs-public"),
            .init(heard: "plateforme docs", exact: "platform-docs-public"),
            .init(heard: "comités", exact: "commits"),
        ])

        XCTAssertEqual(
            section,
            """
            \(RepoVocabularyMatcher.verificationCandidatesHeader)
            - platform-docs-public
            - commits
            """
        )
        XCTAssertFalse(section.contains("plateforme"))
        XCTAssertFalse(section.contains("->"))
    }
}

final class SpeakerProfileTemplateTests: XCTestCase {
    private let templates = LLMPromptTemplates(
        systemContent: "SYSTEM",
        userContent: "{{replacement_dictionary}}\n{{input_text}}"
    )

    func testEmptyProfileLeavesTheSystemPromptByteExact() {
        XCTAssertEqual(templates.withSpeakerProfile(""), templates)
        XCTAssertEqual(templates.withSpeakerProfile("  \n "), templates)
    }

    func testProfileIsAppendedToTheSystemPromptOnly() {
        let result = templates.withSpeakerProfile("  I work on Qwen and Claude Code.\n")

        XCTAssertEqual(
            result.systemContent,
            "SYSTEM\n\n\(LLMPromptTemplates.speakerProfileHeader)\nI work on Qwen and Claude Code.\n"
        )
        XCTAssertEqual(result.userContent, templates.userContent)
    }

    func testProfileIsCappedAndStrippedOfControlCharacters() {
        let long = String(repeating: "a", count: 5000) + "\u{0}"
        let result = templates.withSpeakerProfile(long)

        XCTAssertFalse(result.systemContent.contains("\u{0}"))
        XCTAssertTrue(result.systemContent.hasSuffix(
            String(repeating: "a", count: LLMPromptTemplates.speakerProfileMaxCharacters) + "\n"
        ))
    }
}
