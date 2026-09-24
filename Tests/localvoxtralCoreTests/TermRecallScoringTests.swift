import XCTest

@testable import localvoxtralCore

final class TermRecallScoringTests: XCTestCase {
    private func makeCase(
        _ text: String,
        terms: [String],
        sessionTerms: [String] = [],
        language: String = "en",
        id: String = "tr-en-0001"
    ) -> TermRecallCase {
        TermRecallCase(id: id, language: language, text: text, terms: terms, sessionTerms: sessionTerms)
    }

    private func recalled(_ term: String, in text: String, heard: String) -> Bool {
        let score = TermRecallScorer.score(makeCase(text, terms: [term]), hypothesis: heard, noiseTerms: [])
        XCTAssertEqual(score.corpusErrors, [], "the reference must contain \(term)")
        return score.terms.first { $0.term == term }.map { $0.recalled == $0.expected } ?? false
    }

    // MARK: - Recall decisions (the July miner's table)

    func testRecallDecisionTable() {
        let rows: [(term: String, text: String, heard: String, recalled: Bool)] = [
            ("Claude Code", "open Claude Code and fix the bug", "open claude code and fix the bug", true),
            ("tty", "join the tty now", "that is pretty good", false),
            ("tty", "join the tty now", "join the tty now", true),
            ("mlx-lm", "package mlx-lm into the app", "package mlxlm into the app", true),
            ("mlx-lm", "package mlx-lm into the app", "package mlx lm into the app", true),
            ("mlx-lm", "package mlx-lm into the app", "package em el ex el em into the app", false),
            ("SwiftPM", "SwiftPM process trees", "swift pm process trees", false),
            ("voxmlx", "restart voxmlx on the mac", "restart vox m l x on the mac", false),
            ("AGENTS.md", "read AGENTS.md first", "read agents md first", true),
            ("worktree", "make a worktree", "make a work tree", false),
        ]
        for row in rows {
            XCTAssertEqual(
                recalled(row.term, in: row.text, heard: row.heard), row.recalled,
                "\(row.term) heard as '\(row.heard)'"
            )
        }
    }

    func testTermNeverMatchesInsideALongerWord() {
        XCTAssertFalse(recalled("tty", in: "the tty works", heard: "the pretty works"))
        XCTAssertFalse(recalled("mlx-lm", in: "use mlx-lm", heard: "use mlxlmx"))
    }

    func testCaseAndPunctuationNeverDecide() {
        XCTAssertTrue(recalled("GitHub", in: "push to GitHub.", heard: "Push to github"))
        XCTAssertTrue(recalled("Next.js", in: "a Next.js app", heard: "a next js app"))
    }

    func testFrenchAccentsStayInsideWords() {
        let evalCase = makeCase(
            "je préfère FastAPI pour ça", terms: ["FastAPI"], language: "fr", id: "tr-fr-0001"
        )
        let score = TermRecallScorer.score(evalCase, hypothesis: "je préfère fast api pour ça", noiseTerms: [])
        XCTAssertEqual(score.terms.map(\.recalled), [0])
        XCTAssertEqual(score.terms.first?.heard, "fast api")
        // "préfère" is one word, so the non-term words align and only the term misses.
        XCTAssertEqual(score.nonTermErrors, 0)
        XCTAssertEqual(score.nonTermWords, 4)
    }

    func testLongerListedTermClaimsItsWords() {
        let evalCase = makeCase(
            "ask Claude Code, not Claude", terms: ["Claude Code", "Claude"], sessionTerms: ["Code"]
        )
        let score = TermRecallScorer.score(evalCase, hypothesis: "ask claude code not claude", noiseTerms: [])
        let byTerm = Dictionary(uniqueKeysWithValues: score.terms.map { ($0.term, $0) })
        XCTAssertEqual(byTerm["Claude Code"]?.expected, 1)
        XCTAssertEqual(byTerm["Claude"]?.expected, 1)
        XCTAssertNil(byTerm["Code"], "code is inside Claude Code, never a separate target")
        XCTAssertEqual(score.falseInsertions, [])
    }

    func testRepeatedTermCountsEachTime() {
        let evalCase = makeCase("the tty and the other tty", terms: ["tty"])
        let score = TermRecallScorer.score(evalCase, hypothesis: "the tty and the other titty", noiseTerms: [])
        XCTAssertEqual(score.terms.first?.expected, 2)
        XCTAssertEqual(score.terms.first?.recalled, 1)
    }

    // MARK: - False insertions

    func testFalseInsertionsCountListedTermsBeyondTheReference() {
        let evalCase = makeCase(
            "restart the server", terms: [], sessionTerms: ["speechd", "herdr"]
        )
        let score = TermRecallScorer.score(
            evalCase,
            hypothesis: "restart the speechd server herdr herdr cloudflared",
            noiseTerms: ["cloudflared", "Okta"]
        )
        XCTAssertEqual(
            score.falseInsertions,
            [
                .init(term: "speechd", list: .session, count: 1),
                .init(term: "herdr", list: .session, count: 2),
                .init(term: "cloudflared", list: .noise, count: 1),
            ]
        )
    }

    func testNoiseTermTheCaseSaysIsNeitherTargetNorInsertion() {
        let evalCase = makeCase("log in with Okta today", terms: [])
        let score = TermRecallScorer.score(evalCase, hypothesis: "log in with okta today", noiseTerms: ["Okta"])
        XCTAssertEqual(score.terms, [])
        XCTAssertEqual(score.falseInsertions, [])
        XCTAssertEqual(score.nonTermWords, 4)
    }

    func testTermOnBothListsCountsAsSession() {
        let evalCase = makeCase("hello there", terms: [], sessionTerms: ["herdr"])
        let score = TermRecallScorer.score(evalCase, hypothesis: "hello herdr there", noiseTerms: ["herdr"])
        XCTAssertEqual(score.falseInsertions, [.init(term: "herdr", list: .session, count: 1)])
    }

    // MARK: - Non-term word error rate

    func testMisheardTermIsNotAlsoCountedAsWordErrors() {
        let evalCase = makeCase("open Claude Code and fix the bug", terms: ["Claude Code"])
        let score = TermRecallScorer.score(evalCase, hypothesis: "open clothes code and fix the bug", noiseTerms: [])
        XCTAssertEqual(score.terms.first?.recalled, 0)
        XCTAssertEqual(score.terms.first?.heard, "clothes code")
        XCTAssertEqual(score.nonTermWords, 5)
        XCTAssertEqual(score.nonTermErrors, 0)
    }

    func testSpelledOutTermIsNotChargedAsInsertions() {
        let evalCase = makeCase("package mlx-lm into the app", terms: ["mlx-lm"])
        let score = TermRecallScorer.score(
            evalCase, hypothesis: "package em el ex el em into the app", noiseTerms: []
        )
        XCTAssertEqual(score.terms.first?.heard, "em el ex el em")
        XCTAssertEqual(score.nonTermErrors, 0)
    }

    func testNonTermErrorsCountSubstitutionsDeletionsAndInsertions() {
        let evalCase = makeCase("please restart the tty session now", terms: ["tty"])
        // "please" dropped, "session" -> "cession", "really" inserted before "now".
        let score = TermRecallScorer.score(
            evalCase, hypothesis: "restart the tty cession really now", noiseTerms: []
        )
        XCTAssertEqual(score.terms.first?.recalled, 1)
        XCTAssertEqual(score.nonTermWords, 5)
        XCTAssertEqual(score.nonTermErrors, 3)
    }

    func testDroppedTermHeardSpanIsEmpty() {
        let evalCase = makeCase("join the tty now", terms: ["tty"])
        let score = TermRecallScorer.score(evalCase, hypothesis: "join the now", noiseTerms: [])
        XCTAssertEqual(score.terms.first?.heard, "")
        XCTAssertEqual(score.nonTermErrors, 0)
    }

    // MARK: - Corpus errors

    func testListedTermMissingFromTheTextIsACorpusError() {
        let evalCase = makeCase("restart the server", terms: ["speechd"])
        let score = TermRecallScorer.score(evalCase, hypothesis: "restart the server", noiseTerms: [])
        XCTAssertEqual(score.corpusErrors, ["speechd"])
        XCTAssertEqual(score.terms, [])
    }

    // MARK: - Tally and comparison

    func testTallyGroupsByLanguageAndAll() {
        let english = TermRecallScorer.score(
            makeCase("open Claude Code now", terms: ["Claude Code"], sessionTerms: ["herdr"]),
            hypothesis: "open clothes code now herdr", noiseTerms: []
        )
        let french = TermRecallScorer.score(
            makeCase("ouvre Claude Code", terms: ["Claude Code"], language: "fr", id: "tr-fr-0001"),
            hypothesis: "ouvre claude code", noiseTerms: []
        )
        let tallies = TermRecallScorer.tally([english, french])
        XCTAssertEqual(tallies["en"]?.recalled, 0)
        XCTAssertEqual(tallies["en"]?.falseInsertionsSession, 1)
        XCTAssertEqual(tallies["fr"]?.casesAllRecalled, 1)
        XCTAssertEqual(tallies["all"]?.cases, 2)
        XCTAssertEqual(tallies["all"]?.termOccurrences, 2)
        XCTAssertEqual(tallies["all"]?.recalled, 1)
    }

    func testCompareCountsPairedGainsAndLosses() {
        let first = makeCase("use tty and herdr", terms: ["tty", "herdr"])
        let second = makeCase("ask Claude Code", terms: ["Claude Code"], id: "tr-en-0002")
        let only = makeCase("the tty", terms: ["tty"], id: "tr-en-0003")
        let before = [
            TermRecallScorer.score(first, hypothesis: "use tty and her dirt", noiseTerms: []),
            TermRecallScorer.score(second, hypothesis: "ask claude code", noiseTerms: []),
            TermRecallScorer.score(only, hypothesis: "the tty", noiseTerms: []),
        ]
        let after = [
            TermRecallScorer.score(first, hypothesis: "use tty and herdr", noiseTerms: []),
            TermRecallScorer.score(second, hypothesis: "ask clothes code", noiseTerms: []),
        ]
        let comparison = TermRecallScorer.compare(before: before, after: after)
        XCTAssertEqual(comparison.pairedCases, 2)
        XCTAssertEqual(comparison.termGains, 1)
        XCTAssertEqual(comparison.termLosses, 1)
        XCTAssertEqual(comparison.casesWithGain, 1)
        XCTAssertEqual(comparison.casesWithLoss, 1)
        XCTAssertEqual(comparison.unpaired, ["tr-en-0003"])
    }

    func testCaseFileDecodesTheHarvesterSchema() throws {
        let json = """
            {"schemaVersion": 2, "set": "term-recall", "private": true, "note": "x",
             "noiseTerms": ["Okta"],
             "cases": [{"id": "tr-fr-0001", "language": "fr", "text": "ouvre Claude Code",
                        "terms": ["Claude Code"], "sessionTerms": ["Claude Code", "herdr"],
                        "sessionHash": "0123456789ab"}]}
            """
        let file = try JSONDecoder().decode(TermRecallCaseFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.noiseTerms, ["Okta"])
        XCTAssertEqual(file.cases.first?.sessionTerms, ["Claude Code", "herdr"])
    }

    // MARK: - Run file and report

    private func sampleRun(label: String, hypothesis: String) -> TermRecallRun {
        let evalCase = makeCase("open Claude Code now", terms: ["Claude Code"], sessionTerms: ["herdr"])
        return TermRecallRun(
            header: .init(label: label, source: "voxtral", model: "org/model", bias: "none", audio: "say"),
            scores: [TermRecallScorer.score(evalCase, hypothesis: hypothesis, noiseTerms: ["Okta"])]
        )
    }

    func testRunFileRoundTrips() throws {
        let run = sampleRun(label: "a", hypothesis: "open clothes code now")
        XCTAssertEqual(try TermRecallRun.parse(jsonLines: run.jsonLines()), run)
    }

    func testScoreboardAndComparisonCarryNoCaseContent() {
        let before = sampleRun(label: "before", hypothesis: "open clothes code now okta")
        let after = sampleRun(label: "after", hypothesis: "open claude code now")
        let printed = TermRecallReport.scoreboard(before) + TermRecallReport.comparison(before: before, after: after)
        for secret in ["claude", "clothes", "herdr", "okta", "open"] {
            XCTAssertFalse(printed.lowercased().contains(secret), "printed \(secret)")
        }
        XCTAssertTrue(TermRecallReport.scoreboard(before).contains("0.0% (0/1)"))
        XCTAssertTrue(TermRecallReport.comparison(before: before, after: after).contains("term occurrences gained: 1 in 1 case(s)"))
    }
}
