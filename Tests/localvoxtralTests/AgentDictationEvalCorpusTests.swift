import Foundation
import XCTest

/// Structural validation of the agent-dictation eval corpus
/// (EvalCorpus/agent-dictation/). Runs in the plain unit tier: no env gate,
/// no network, no TTS — it only checks that the corpus data is internally
/// consistent, so authoring mistakes fail CI before the Phase 2 harness
/// ever burns inference time on them.
final class AgentDictationEvalCorpusTests: XCTestCase {
    // MARK: - Shared loading

    private func loadedStrata() throws -> [AgentDictationEvalCorpus.LoadedStratum] {
        try AgentDictationEvalCorpus.loadStrata()
    }

    private func allCases() throws -> [AgentDictationEvalCorpus.Case] {
        try AgentDictationEvalCorpus.allCases()
    }

    /// Spacing-normalized, casing per the case's scoring contract.
    private func matchText(_ text: String, for evalCase: AgentDictationEvalCorpus.Case) -> String {
        let normalized = LLMPolishEvalSupport.normalizedSpacing(text)
        return evalCase.isCaseInsensitive ? normalized.lowercased() : normalized
    }

    // MARK: - Corpus shape

    func testCorpusLoadsAndCoversExpectedStrata() throws {
        let strata = try loadedStrata()
        let names = Set(strata.map(\.stratum.stratum))
        XCTAssertEqual(
            names,
            AgentDictationEvalCorpus.expectedStrata,
            "Stratum set drifted — adding/removing a stratum is deliberate; update expectedStrata and the corpus README together."
        )

        for loaded in strata {
            XCTAssertEqual(loaded.stratum.schemaVersion, 1, "\(loaded.fileName): unknown schemaVersion")
            XCTAssertFalse(loaded.stratum.cases.isEmpty, "\(loaded.fileName): stratum has no cases")
            XCTAssertFalse(loaded.stratum.description.isEmpty, "\(loaded.fileName): missing description")
            let langs = Set(loaded.stratum.cases.map(\.lang))
            XCTAssertTrue(
                langs.contains(.en) && langs.contains(.fr),
                "\(loaded.fileName): every stratum must cover both languages"
            )
        }

        let cases = strata.flatMap(\.stratum.cases)
        XCTAssertGreaterThanOrEqual(cases.count, 150, "corpus shrank below the agreed ~150–200 size")
        let frShare = Double(cases.filter { $0.lang == .fr }.count) / Double(cases.count)
        XCTAssertGreaterThanOrEqual(frShare, 0.25, "French share fell below the ~1/3 target band")
        XCTAssertLessThanOrEqual(frShare, 0.45, "French share exceeded the ~1/3 target band")
    }

    func testPipelinesMatchStratumSemantics() throws {
        for loaded in try loadedStrata() {
            let expected: AgentDictationEvalCorpus.Pipeline
            switch loaded.stratum.stratum {
            case "plain-asr-baseline":
                expected = .asrOnly
            case "punctuation-spacing-migration":
                expected = .polishOnly
            default:
                expected = .full
            }
            XCTAssertEqual(
                loaded.stratum.resolvedPipeline,
                expected,
                "\(loaded.fileName): pipeline must match the stratum's contract"
            )
            if loaded.stratum.resolvedPipeline == .asrOnly {
                for evalCase in loaded.stratum.cases {
                    XCTAssertNil(
                        evalCase.features,
                        "\(evalCase.id): asr-only cases must not carry polish features"
                    )
                }
            }
        }
    }

    // MARK: - Per-case structural invariants

    func testCaseIdsAreUniqueAndSlugLike() throws {
        var seen: Set<String> = []
        for evalCase in try allCases() {
            XCTAssertTrue(seen.insert(evalCase.id).inserted, "duplicate case id: \(evalCase.id)")
            XCTAssertNotNil(
                evalCase.id.range(of: "^[a-j]-(en|fr)-[a-z0-9-]+$", options: .regularExpression),
                "\(evalCase.id): id must be <stratum-letter>-<lang>-<slug>"
            )
            XCTAssertTrue(
                evalCase.id.hasPrefix(evalCase.id.prefix(2) + evalCase.lang.rawValue),
                "\(evalCase.id): id lang segment must match lang field \(evalCase.lang.rawValue)"
            )
        }
    }

    func testCoreFieldsArePresent() throws {
        for evalCase in try allCases() {
            XCTAssertFalse(evalCase.spokenForm.isEmpty, "\(evalCase.id): empty spokenForm")
            XCTAssertFalse(evalCase.intendedText.isEmpty, "\(evalCase.id): empty intendedText")
            XCTAssertFalse(evalCase.notes.isEmpty, "\(evalCase.id): empty notes")
            XCTAssertFalse(evalCase.requiredTokens.isEmpty, "\(evalCase.id): requiredTokens is the primary metric — every case needs at least one")
            XCTAssertFalse(evalCase.status.isEmpty, "\(evalCase.id): empty status map")
            XCTAssertNotNil(evalCase.status["tokens"], "\(evalCase.id): every case must carry a status for the primary 'tokens' metric")
            for metric in evalCase.status.keys {
                XCTAssertTrue(
                    AgentDictationEvalCorpus.validMetrics.contains(metric),
                    "\(evalCase.id): unknown metric '\(metric)'"
                )
            }
        }
    }

    func testRequiredTokensAppearInIntendedText() throws {
        for evalCase in try allCases() {
            let haystack = matchText(evalCase.intendedText, for: evalCase)
            for token in evalCase.requiredTokens {
                XCTAssertFalse(token.isEmpty, "\(evalCase.id): empty required token")
                XCTAssertTrue(
                    haystack.contains(matchText(token, for: evalCase)),
                    "\(evalCase.id): required token \"\(token)\" does not appear in intendedText"
                )
            }
        }
    }

    func testForbiddenSubstringsAbsentFromIntendedTextAndDisjointFromRequired() throws {
        for evalCase in try allCases() {
            // Forbidden needles are contamination detectors and always match
            // case-insensitively.
            let haystack = LLMPolishEvalSupport.normalizedSpacing(evalCase.intendedText).lowercased()
            for needle in evalCase.forbidden {
                XCTAssertFalse(needle.isEmpty, "\(evalCase.id): empty forbidden substring")
                let normalizedNeedle = LLMPolishEvalSupport.normalizedSpacing(needle).lowercased()
                XCTAssertFalse(
                    haystack.contains(normalizedNeedle),
                    "\(evalCase.id): forbidden \"\(needle)\" appears in intendedText — the case can never pass"
                )
                for token in evalCase.requiredTokens {
                    let normalizedToken = LLMPolishEvalSupport.normalizedSpacing(token).lowercased()
                    XCTAssertFalse(
                        normalizedToken.contains(normalizedNeedle) || normalizedNeedle.contains(normalizedToken),
                        "\(evalCase.id): forbidden \"\(needle)\" overlaps required \"\(token)\" — contradictory metric"
                    )
                }
            }
        }
    }

    // MARK: - Language heuristic

    /// Cheap one-directional check: a case must contain at least one
    /// whole-word function-word marker of its declared language somewhere in
    /// spokenForm + intendedText. Catches lang-field typos, not dialects.
    func testLanguageMarkersMatchDeclaredLanguage() throws {
        let frMarkers: Set<String> = [
            "le", "la", "les", "un", "une", "des", "du", "de", "et", "est",
            "dans", "avec", "pour", "sur", "que", "qui", "pas", "puis", "tu",
            "il", "on", "ce", "cette", "au", "aux", "ne", "ma", "mes", "mon",
            "vers", "depuis", "avant", "non", "mets", "deux", "regarde", "à",
        ]
        let enMarkers: Set<String> = [
            "the", "a", "to", "and", "is", "it", "with", "run", "add", "fix",
            "check", "open", "then", "of", "in", "this", "that", "we", "you",
            "for", "on", "at", "do", "not", "my", "before", "why", "what",
            "when", "how", "set", "use", "make", "tell", "give", "look", "from",
        ]

        for evalCase in try allCases() {
            let words = Set(
                (evalCase.spokenForm + " " + evalCase.intendedText)
                    .lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }
            )
            let markers = evalCase.lang == .fr ? frMarkers : enMarkers
            XCTAssertFalse(
                words.isDisjoint(with: markers),
                "\(evalCase.id): no \(evalCase.lang.rawValue) function-word marker found — lang field likely wrong"
            )
        }
    }

    // MARK: - Feature fixtures

    func testMacroCasesCarryClipboardFixturesWithCoherentAssertions() throws {
        let placeholder = "$LV_CLIPBOARD_PAYLOAD"
        for evalCase in try allCases() {
            XCTAssertFalse(
                evalCase.spokenForm.contains(placeholder) || evalCase.intendedText.contains(placeholder),
                "\(evalCase.id): the macro placeholder must never appear in corpus text"
            )
            guard let macro = evalCase.features?.macro else { continue }
            guard let payload = evalCase.features?.clipboard, !payload.isEmpty else {
                XCTFail("\(evalCase.id): macro cases must carry a clipboard payload fixture")
                continue
            }
            XCTAssertTrue(
                evalCase.forbidden.contains(placeholder),
                "\(evalCase.id): macro cases must forbid the raw placeholder leaking into the output"
            )
            if macro {
                XCTAssertTrue(
                    evalCase.intendedText.contains(payload),
                    "\(evalCase.id): macro must fire — the clipboard payload belongs inside intendedText"
                )
            } else {
                XCTAssertFalse(
                    evalCase.intendedText.contains(payload),
                    "\(evalCase.id): negative macro case must not embed the payload in intendedText"
                )
                XCTAssertTrue(
                    evalCase.forbidden.contains(payload),
                    "\(evalCase.id): negative macro case must forbid the payload (leak detector)"
                )
            }
        }
    }

    /// Per-stratum feature contracts: a clipboard-context case without a
    /// payload, or a macro case without an explicit macro flag + payload,
    /// would silently degrade into a plain polish case in Phase 2.
    func testStrataEnforceFeatureContracts() throws {
        for loaded in try loadedStrata() {
            switch loaded.stratum.stratum {
            case "clipboard-context":
                for evalCase in loaded.stratum.cases {
                    XCTAssertFalse(
                        (evalCase.features?.clipboard ?? "").isEmpty,
                        "\(evalCase.id): clipboard-context cases must carry a non-empty clipboard payload"
                    )
                }
            case "paste-clipboard-macro":
                for evalCase in loaded.stratum.cases {
                    XCTAssertNotNil(
                        evalCase.features?.macro,
                        "\(evalCase.id): paste-clipboard-macro cases must set macro true/false explicitly"
                    )
                    XCTAssertFalse(
                        (evalCase.features?.clipboard ?? "").isEmpty,
                        "\(evalCase.id): paste-clipboard-macro cases must carry a clipboard payload"
                    )
                }
            default:
                break
            }
        }
    }

    // MARK: - Loader hardening regressions

    /// JSONDecoder silently drops unknown keys, so a typo'd optional field
    /// would pass decode and lose its fixture. The loader must reject
    /// unknown keys at every object level.
    func testDecodingRejectsUnknownKeys() {
        let stratumJSON = Data("""
        {"schemaVersion": 1, "stratum": "x", "description": "d", "cases": [], "surpriseKey": true}
        """.utf8)
        assertThrowsUnknownKeyError(decoding: stratumJSON, key: "surpriseKey")

        let caseJSON = Data("""
        {"schemaVersion": 1, "stratum": "x", "description": "d", "cases": [
            {"id": "a-en-x", "lang": "en", "spokenForm": "s", "intendedText": "s",
             "requiredTokens": ["s"], "status": {"tokens": "known-hard"},
             "notes": "n", "intendedTxt": "typo"}
        ]}
        """.utf8)
        assertThrowsUnknownKeyError(decoding: caseJSON, key: "intendedTxt")

        let featuresJSON = Data("""
        {"schemaVersion": 1, "stratum": "x", "description": "d", "cases": [
            {"id": "a-en-x", "lang": "en", "spokenForm": "s", "intendedText": "s",
             "requiredTokens": ["s"], "status": {"tokens": "known-hard"}, "notes": "n",
             "features": {"clipboardPayload": "misspelled"}}
        ]}
        """.utf8)
        assertThrowsUnknownKeyError(decoding: featuresJSON, key: "clipboardPayload")
    }

    private func assertThrowsUnknownKeyError(decoding data: Data, key: String) {
        XCTAssertThrowsError(
            try JSONDecoder().decode(AgentDictationEvalCorpus.Stratum.self, from: data),
            "unknown key '\(key)' must be rejected"
        ) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                XCTFail("expected dataCorrupted for '\(key)', got \(error)")
                return
            }
            XCTAssertTrue(
                context.debugDescription.contains(key),
                "error must name the offending key '\(key)': \(context.debugDescription)"
            )
        }
    }

    /// Duplicate fixture names must surface as a readable thrown error, not
    /// a Dictionary(uniqueKeysWithValues:) trap that kills the suite.
    func testDuplicateRepoFixtureNamesAreAReadableFailure() {
        let fixture = AgentDictationEvalCorpus.RepoFixture(name: "twin", branch: "main", files: ["a.txt"])
        XCTAssertThrowsError(
            try AgentDictationEvalCorpus.indexRepoFixtures([fixture, fixture])
        ) { error in
            guard case AgentDictationEvalCorpus.LoadError.duplicateRepoFixtureName(let name) = error else {
                XCTFail("expected duplicateRepoFixtureName, got \(error)")
                return
            }
            XCTAssertEqual(name, "twin")
        }
    }

    func testRepoVocabularyCasesReferenceFixtureFiles() throws {
        let fixtures = try AgentDictationEvalCorpus.loadRepoFixtures()
        XCTAssertFalse(fixtures.isEmpty, "no repo fixtures found under fixtures/")
        for (name, fixture) in fixtures {
            XCTAssertEqual(name, fixture.name)
            XCTAssertFalse(fixture.branch.isEmpty, "fixture \(name): empty branch")
            XCTAssertEqual(
                Set(fixture.files).count, fixture.files.count,
                "fixture \(name): duplicate file entries"
            )
        }

        for loaded in try loadedStrata() {
            for evalCase in loaded.stratum.cases {
                if loaded.stratum.stratum == "repo-vocabulary" {
                    XCTAssertNotNil(
                        evalCase.features?.repo,
                        "\(evalCase.id): repo-vocabulary cases must reference a repo fixture"
                    )
                }
                guard let repo = evalCase.features?.repo else { continue }
                guard let fixture = fixtures[repo.fixture] else {
                    XCTFail("\(evalCase.id): unknown repo fixture '\(repo.fixture)'")
                    continue
                }
                XCTAssertFalse(repo.files.isEmpty, "\(evalCase.id): repo feature lists no files")
                let fixtureFiles = Set(fixture.files)
                for file in repo.files {
                    XCTAssertTrue(
                        fixtureFiles.contains(file),
                        "\(evalCase.id): references \(file) which is not in fixture '\(repo.fixture)'"
                    )
                }
            }
        }
    }

    // MARK: - Migration fidelity + promotion policy

    /// Every LLMPolishEvalSupport required/known-hard case must appear in the
    /// corpus exactly once, byte-identical: same input text (as spokenForm),
    /// same expected output / needles, same required-vs-known-hard status.
    /// LLMPolishEvalSupport stays the runtime source of truth for the
    /// polish-only eval lanes; this test pins the two representations
    /// together so neither can drift silently.
    func testMigratedCasesByteMatchLLMPolishEvalSupportOriginals() throws {
        let migrated = try allCases().filter { $0.source?.migratedFrom != nil }
        let byOriginalId = Dictionary(grouping: migrated) { $0.source?.originalId ?? "" }

        for (originalId, group) in byOriginalId {
            XCTAssertEqual(group.count, 1, "original \(originalId) migrated more than once")
        }

        let originals =
            LLMPolishEvalSupport.requiredCases.map { (original: $0, list: "LLMPolishEvalSupport.requiredCases") }
            + LLMPolishEvalSupport.knownHardCases.map { (original: $0, list: "LLMPolishEvalSupport.knownHardCases") }

        XCTAssertEqual(
            migrated.count, originals.count,
            "migration must cover every required + known-hard original, nothing more"
        )

        for (original, list) in originals {
            guard let corpusCase = byOriginalId[original.id]?.first else {
                XCTFail("original case \(original.id) is missing from the corpus migration")
                continue
            }
            XCTAssertEqual(
                corpusCase.source?.migratedFrom, list,
                "\(corpusCase.id): migratedFrom must name the originating list"
            )
            XCTAssertEqual(
                corpusCase.spokenForm, original.input,
                "\(corpusCase.id): spokenForm must byte-match the original input"
            )
            XCTAssertEqual(
                corpusCase.isCaseInsensitive, !original.caseSensitive,
                "\(corpusCase.id): must preserve the original scorer's case sensitivity"
            )
            if let expectedText = original.expectedText {
                // Currently-required original: full-output equality carries over.
                XCTAssertEqual(
                    corpusCase.intendedText, expectedText,
                    "\(corpusCase.id): intendedText must byte-match the original expectedText"
                )
                XCTAssertEqual(
                    corpusCase.status["exactText"], .required,
                    "\(corpusCase.id): migrated required case must keep exactText=required"
                )
                XCTAssertEqual(
                    corpusCase.status["tokens"], .required,
                    "\(corpusCase.id): migrated required case must keep tokens=required"
                )
            } else {
                XCTAssertEqual(
                    corpusCase.requiredTokens, original.mustContain,
                    "\(corpusCase.id): requiredTokens must byte-match the original mustContain"
                )
                XCTAssertEqual(
                    corpusCase.forbidden, original.mustNotContain,
                    "\(corpusCase.id): forbiddenSubstrings must byte-match the original mustNotContain"
                )
                XCTAssertEqual(
                    corpusCase.status["tokens"], .knownHard,
                    "\(corpusCase.id): migrated known-hard case must stay known-hard"
                )
                XCTAssertNil(
                    corpusCase.status["exactText"],
                    "\(corpusCase.id): known-hard originals had no expectedText — no exactText metric"
                )
            }
        }
    }

    /// Promotion policy ratchet: `required` status demands cross-server-state
    /// stability evidence. At corpus creation only direct migrations of
    /// currently-required LLMPolishEvalSupport cases qualify. Promoting a new
    /// case later means bringing that evidence to the PR that relaxes THIS
    /// assertion for it (see the corpus README).
    func testRequiredStatusAppearsOnlyOnMigratedRequiredCases() throws {
        for evalCase in try allCases() {
            let hasRequiredMetric = evalCase.status.values.contains(.required)
            guard hasRequiredMetric else { continue }
            XCTAssertEqual(
                evalCase.source?.migratedFrom, "LLMPolishEvalSupport.requiredCases",
                "\(evalCase.id): 'required' status needs cross-server-state stability proof — new cases start known-hard (promotion policy)"
            )
        }
    }
}
