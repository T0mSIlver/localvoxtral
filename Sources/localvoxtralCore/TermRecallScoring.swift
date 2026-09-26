import Foundation

/// The term-recall set's case file (`EvalRecordings/term-recall/cases.json`,
/// written by `scripts/harvest-term-recall-cases.py`). Private: the cases come
/// from the owner's transcripts and never leave the gitignored directory.
package struct TermRecallCaseFile: Codable, Equatable, Sendable {
    package var schemaVersion: Int
    /// Terms no case speaks or lists: the bias list of the noise-control arm.
    package var noiseTerms: [String]
    package var cases: [TermRecallCase]

    package init(schemaVersion: Int = 2, noiseTerms: [String], cases: [TermRecallCase]) {
        self.schemaVersion = schemaVersion
        self.noiseTerms = noiseTerms
        self.cases = cases
    }
}

package struct TermRecallCase: Codable, Equatable, Sendable {
    package var id: String
    /// "en" or "fr".
    package var language: String
    /// What is spoken, and the reference the hypothesis is scored against.
    package var text: String
    /// The listed terms the text contains.
    package var terms: [String]
    /// At most 100 terms from the case's session and project, its own terms
    /// included: the bias list of the session arm.
    package var sessionTerms: [String]

    package init(
        id: String,
        language: String,
        text: String,
        terms: [String],
        sessionTerms: [String]
    ) {
        self.id = id
        self.language = language
        self.text = text
        self.terms = terms
        self.sessionTerms = sessionTerms
    }
}

/// One case's score. Carries term text and what the engine wrote, so it stays
/// under `EvalRecordings/`; only `TermRecallTally` is safe to print in a PR.
package struct TermRecallCaseScore: Codable, Equatable, Sendable {
    package struct TermResult: Codable, Equatable, Sendable {
        package var term: String
        /// Times the reference says it.
        package var expected: Int
        /// Times the hypothesis says it, capped at `expected`.
        package var recalled: Int
        /// What the hypothesis has where a missed term was, when the words
        /// around it line up. A diagnostic, not a metric.
        package var heard: String?
    }

    package enum ListKind: String, Codable, Sendable {
        case session
        case noise
    }

    package struct FalseInsertion: Codable, Equatable, Sendable {
        package var term: String
        package var list: ListKind
        package var count: Int
    }

    package var id: String
    package var language: String
    /// The case text as the scorer's words, then its listed terms, so
    /// `compare` can tell a case that changed under the same id (text or
    /// targets) from one the engine got differently.
    package var reference: String
    package var hypothesis: String
    package var terms: [TermResult]
    package var falseInsertions: [FalseInsertion]
    /// Reference words outside every listed term, and the errors aligned to
    /// them.
    package var nonTermWords: Int
    package var nonTermErrors: Int
    /// Listed `terms` the scorer cannot find in the case's own text: a corpus
    /// bug, reported instead of scored.
    package var corpusErrors: [String]
}

/// Sums over a group of cases. Holds counts only, no case content.
package struct TermRecallTally: Equatable, Sendable {
    package var cases = 0
    /// Cases whose text says at least one listed term, and those
    /// with every such occurrence recalled.
    package var casesWithTerms = 0
    package var casesAllRecalled = 0
    package var termOccurrences = 0
    package var recalled = 0
    package var falseInsertionsSession = 0
    package var falseInsertionsNoise = 0
    package var nonTermWords = 0
    package var nonTermErrors = 0
    package var corpusErrors = 0

    package init() {}

    package mutating func add(_ score: TermRecallCaseScore) {
        cases += 1
        let expected = score.terms.reduce(0) { $0 + $1.expected }
        let got = score.terms.reduce(0) { $0 + $1.recalled }
        termOccurrences += expected
        recalled += got
        if expected > 0 {
            casesWithTerms += 1
            if got == expected { casesAllRecalled += 1 }
        }
        for insertion in score.falseInsertions {
            switch insertion.list {
            case .session: falseInsertionsSession += insertion.count
            case .noise: falseInsertionsNoise += insertion.count
            }
        }
        nonTermWords += score.nonTermWords
        nonTermErrors += score.nonTermErrors
        corpusErrors += score.corpusErrors.count
    }
}

/// Paired comparison of two runs over the cases both scored.
package struct TermRecallComparison: Equatable, Sendable {
    package var pairedCases = 0
    /// Term occurrences the second run recalls and the first misses.
    package var termGains = 0
    /// Term occurrences the first run recalls and the second misses.
    package var termLosses = 0
    package var casesWithGain = 0
    package var casesWithLoss = 0
    package var falseInsertionsBefore = 0
    package var falseInsertionsAfter = 0
    package var nonTermWords = 0
    package var nonTermErrorsBefore = 0
    package var nonTermErrorsAfter = 0
    /// Case ids only one run scored.
    package var unpaired: [String] = []
    /// Case ids both runs scored against different text: the case set was
    /// re-harvested between them. Left out of every count above.
    package var changed: [String] = []

    package init() {}
}

/// Scores a hypothesis against a term-recall case. Pure; `TermRecallScoringTests`
/// pins the rules on fixed transcripts.
///
/// Words are lowercased and split on anything that is not a letter or digit,
/// so case and punctuation never decide a match. A listed term counts where
/// its words appear in order, or where one to N adjacent hypothesis words
/// glue to it exactly ("mlxlm" for `mlx-lm`); never inside a longer word. A
/// split term ("work tree" for `worktree`) is a miss. Where two listed terms
/// could match at the same place, the one with more words wins, and a match
/// claims its words.
package enum TermRecallScorer {
    package static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    package static func score(
        _ evalCase: TermRecallCase,
        hypothesis: String,
        noiseTerms: [String]
    ) -> TermRecallCaseScore {
        let sessionList = unique(evalCase.terms + evalCase.sessionTerms)
        let sessionKeys = Set(sessionList.map(key))
        let noiseList = unique(noiseTerms).filter { !sessionKeys.contains(key($0)) }
        let matcher = Matcher(terms: sessionList + noiseList)

        let reference = words(evalCase.text)
        let heard = words(hypothesis)
        let referenceMatches = matcher.matches(in: reference)
        let hypothesisMatches = matcher.matches(in: heard)
        let referenceCounts = counts(referenceMatches)
        let hypothesisCounts = counts(hypothesisMatches)

        let corpusErrors = evalCase.terms.filter { (referenceCounts[key($0)] ?? 0) == 0 }

        // Recall covers the session list's terms the reference says. A noise
        // term a case happens to say is neither a target nor an insertion.
        let alignment = align(reference, heard)
        var termResults: [TermRecallCaseScore.TermResult] = []
        for term in sessionList {
            let expected = referenceCounts[key(term)] ?? 0
            guard expected > 0 else { continue }
            let recalled = min(expected, hypothesisCounts[key(term)] ?? 0)
            var span: String?
            if recalled < expected {
                // The occurrence the engine missed: the first whose words do
                // not all align to matching words.
                let ranges = referenceMatches.filter { $0.key == key(term) }.map(\.range)
                let missed = ranges.first { !isHeardWordForWord($0, alignment: alignment) } ?? ranges[0]
                span = heardSpan(for: missed, alignment: alignment, hypothesis: heard)
            }
            termResults.append(
                .init(term: term, expected: expected, recalled: recalled, heard: span)
            )
        }

        // A listed term that is part of a longer spoken term, written over
        // that term's words ("Claude Claude" for "Claude Code"), is the longer
        // term misheard, charged to recall. Any other listed term written
        // over a spoken one ("herdr" for "speechd") is an insertion: that is
        // the failure a biased list causes.
        var insertable: [String: Int] = [:]
        let referenceKeyAt = referenceMatches.reduce(into: [Int: String]()) { keys, match in
            for index in match.range { keys[index] = match.key }
        }
        let referenceIndexOfHeard = alignment.reduce(into: [Int: Int]()) { indices, step in
            if let hypothesisIndex = step.hypothesis, step.kind == .match || step.kind == .substitution {
                indices[hypothesisIndex] = step.reference
            }
        }
        for match in hypothesisMatches {
            let overTerm = match.range.contains { index in
                guard let referenceIndex = referenceIndexOfHeard[index],
                    let spoken = referenceKeyAt[referenceIndex]
                else { return false }
                return spoken != match.key && isPart(match.key, of: spoken)
            }
            if !overTerm { insertable[match.key, default: 0] += 1 }
        }

        var insertions: [TermRecallCaseScore.FalseInsertion] = []
        for (list, terms) in [(TermRecallCaseScore.ListKind.session, sessionList), (.noise, noiseList)] {
            for term in terms {
                let extra = (insertable[key(term)] ?? 0) - (referenceCounts[key(term)] ?? 0)
                if extra > 0 {
                    insertions.append(.init(term: term, list: list, count: extra))
                }
            }
        }

        var termPositions = Set<Int>()
        for match in referenceMatches { termPositions.formUnion(match.range) }
        let errors = nonTermErrorCount(alignment, termPositions: termPositions, referenceCount: reference.count)

        return TermRecallCaseScore(
            id: evalCase.id,
            language: evalCase.language,
            reference: reference.joined(separator: " ") + " | "
                + evalCase.terms.map(key).sorted().joined(separator: ", "),
            hypothesis: hypothesis,
            terms: termResults,
            falseInsertions: insertions,
            nonTermWords: reference.count - termPositions.count,
            nonTermErrors: errors,
            corpusErrors: corpusErrors
        )
    }

    /// Tallies by language, plus "all".
    package static func tally(_ scores: [TermRecallCaseScore]) -> [String: TermRecallTally] {
        var tallies: [String: TermRecallTally] = [:]
        for score in scores {
            tallies[score.language, default: TermRecallTally()].add(score)
            tallies["all", default: TermRecallTally()].add(score)
        }
        return tallies
    }

    package static func compare(
        before: [TermRecallCaseScore],
        after: [TermRecallCaseScore]
    ) -> TermRecallComparison {
        var comparison = TermRecallComparison()
        let beforeByID = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let afterByID = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        comparison.unpaired = Set(beforeByID.keys).symmetricDifference(afterByID.keys).sorted()
        for id in beforeByID.keys.sorted() {
            guard let old = beforeByID[id], let new = afterByID[id] else { continue }
            guard old.reference == new.reference else {
                comparison.changed.append(id)
                continue
            }
            comparison.pairedCases += 1
            let oldRecalled = Dictionary(old.terms.map { (key($0.term), $0.recalled) }, uniquingKeysWith: +)
            let newRecalled = Dictionary(new.terms.map { (key($0.term), $0.recalled) }, uniquingKeysWith: +)
            var gains = 0
            var losses = 0
            for term in Set(oldRecalled.keys).union(newRecalled.keys) {
                let delta = (newRecalled[term] ?? 0) - (oldRecalled[term] ?? 0)
                if delta > 0 { gains += delta } else { losses -= delta }
            }
            comparison.termGains += gains
            comparison.termLosses += losses
            if gains > 0 { comparison.casesWithGain += 1 }
            if losses > 0 { comparison.casesWithLoss += 1 }
            comparison.falseInsertionsBefore += old.falseInsertions.reduce(0) { $0 + $1.count }
            comparison.falseInsertionsAfter += new.falseInsertions.reduce(0) { $0 + $1.count }
            comparison.nonTermWords += old.nonTermWords
            comparison.nonTermErrorsBefore += old.nonTermErrors
            comparison.nonTermErrorsAfter += new.nonTermErrors
        }
        return comparison
    }

    // MARK: - Matching

    private static func key(_ term: String) -> String {
        words(term).joined(separator: " ")
    }

    private static func unique(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.filter { !key($0).isEmpty && seen.insert(key($0)).inserted }
    }

    private static func counts(_ matches: [Match]) -> [String: Int] {
        matches.reduce(into: [:]) { $0[$1.key, default: 0] += 1 }
    }

    struct Match: Equatable {
        let key: String
        let range: Range<Int>
    }

    struct Matcher {
        private struct Pattern {
            let key: String
            let words: [String]
            let glued: String
        }

        private let patterns: [Pattern]

        init(terms: [String]) {
            patterns = terms.map { term in
                let parts = TermRecallScorer.words(term)
                return Pattern(key: parts.joined(separator: " "), words: parts, glued: parts.joined())
            }
            .filter { !$0.words.isEmpty }
            .sorted { ($0.words.count, $0.glued.count, $0.key) > ($1.words.count, $1.glued.count, $1.key) }
        }

        func matches(in text: [String]) -> [Match] {
            var found: [Match] = []
            var index = 0
            while index < text.count {
                if let length = longestMatch(at: index, in: text) {
                    found.append(Match(key: length.key, range: index..<index + length.count))
                    index += length.count
                } else {
                    index += 1
                }
            }
            return found
        }

        private func longestMatch(at index: Int, in text: [String]) -> (key: String, count: Int)? {
            for pattern in patterns {
                let n = pattern.words.count
                if index + n <= text.count, Array(text[index..<index + n]) == pattern.words {
                    return (pattern.key, n)
                }
                // Glued: fewer hypothesis words than the term has, joining to
                // exactly the term with its separators dropped.
                if n > 1 {
                    for window in stride(from: n - 1, through: 1, by: -1)
                    where index + window <= text.count
                        && text[index..<index + window].joined() == pattern.glued
                    {
                        return (pattern.key, window)
                    }
                }
            }
            return nil
        }
    }

    // MARK: - Alignment

    /// One step of a minimum word edit path. `reference` is the reference
    /// index a step consumes; an insertion sits before `reference`.
    struct Step: Equatable {
        enum Kind: Equatable { case match, substitution, deletion, insertion }
        let kind: Kind
        let reference: Int
        let hypothesis: Int?
    }

    static func align(_ reference: [String], _ hypothesis: [String]) -> [Step] {
        let n = reference.count
        let m = hypothesis.count
        var cost = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }
        if n > 0, m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let substitution = cost[i - 1][j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1)
                    cost[i][j] = min(cost[i - 1][j] + 1, cost[i][j - 1] + 1, substitution)
                }
            }
        }
        var steps: [Step] = []
        var i = n
        var j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, reference[i - 1] == hypothesis[j - 1], cost[i][j] == cost[i - 1][j - 1] {
                steps.append(Step(kind: .match, reference: i - 1, hypothesis: j - 1))
                i -= 1
                j -= 1
            } else if j > 0, cost[i][j] == cost[i][j - 1] + 1 {
                // Insertion before substitution on a tie: walking backwards,
                // that places an extra word as late as it can go, so it lands
                // beside the word it follows rather than drifting onto a
                // term's edge, where it would go uncounted.
                steps.append(Step(kind: .insertion, reference: i, hypothesis: j - 1))
                j -= 1
            } else if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + 1 {
                steps.append(Step(kind: .substitution, reference: i - 1, hypothesis: j - 1))
                i -= 1
                j -= 1
            } else {
                steps.append(Step(kind: .deletion, reference: i - 1, hypothesis: nil))
                i -= 1
            }
        }
        return steps.reversed()
    }

    /// Errors on reference words outside listed terms. An insertion counts
    /// only when neither neighbouring reference word is a term word, so a
    /// misheard term ("clothes code") is charged to recall once, not to the
    /// word error rate as well.
    private static func nonTermErrorCount(
        _ steps: [Step],
        termPositions: Set<Int>,
        referenceCount: Int
    ) -> Int {
        var errors = 0
        for step in steps {
            switch step.kind {
            case .match:
                continue
            case .substitution, .deletion:
                if !termPositions.contains(step.reference) { errors += 1 }
            case .insertion:
                let before = step.reference - 1
                let after = step.reference
                let touchesTerm =
                    (before >= 0 && termPositions.contains(before))
                    || (after < referenceCount && termPositions.contains(after))
                if !touchesTerm { errors += 1 }
            }
        }
        return errors
    }

    /// Whether `part`'s words appear in order, adjacent, inside `whole`'s.
    private static func isPart(_ part: String, of whole: String) -> Bool {
        let partWords = part.split(separator: " ")
        let wholeWords = whole.split(separator: " ")
        guard partWords.count < wholeWords.count else { return false }
        return (0...(wholeWords.count - partWords.count)).contains {
            Array(wholeWords[$0..<$0 + partWords.count]) == partWords
        }
    }

    private static func isHeardWordForWord(_ range: Range<Int>, alignment: [Step]) -> Bool {
        let steps = alignment.filter { $0.kind != .insertion && range.contains($0.reference) }
        return steps.count == range.count && steps.allSatisfy { $0.kind == .match }
    }

    /// The hypothesis words between the nearest matched words on either side
    /// of a reference span; empty when nothing is left there.
    private static func heardSpan(for range: Range<Int>, alignment: [Step], hypothesis: [String]) -> String {
        let anchors = alignment.filter { $0.kind == .match }
        let left = anchors.filter { $0.reference < range.lowerBound }.compactMap(\.hypothesis).max() ?? -1
        let right = anchors.filter { $0.reference >= range.upperBound }.compactMap(\.hypothesis).min() ?? hypothesis.count
        guard left + 1 < right else { return "" }
        return hypothesis[(left + 1)..<right].joined(separator: " ")
    }
}

/// Which arm and engine produced a run. Written as the first line of a run
/// file and printed on the scoreboard.
package struct TermRecallRunHeader: Codable, Equatable, Sendable {
    package var label: String
    /// A row of `scripts/mac/test-speech-models.tsv`, or `hypotheses` when
    /// the text came from a file.
    package var source: String
    package var model: String?
    /// `none`, `session` or `noise`: the list the engine was biased with.
    package var bias: String
    /// `say`, `<source>/<set>` for a recorded set (`human/<set>` unless its
    /// manifest names a TTS engine), or `none` for a hypotheses file.
    package var audio: String
    /// Cases left unscored because the speech stage failed (no audio, no
    /// transcript): infrastructure, never counted as misses.
    package var unscoredCases: Int

    package init(
        label: String,
        source: String,
        model: String?,
        bias: String,
        audio: String,
        unscoredCases: Int = 0
    ) {
        self.label = label
        self.source = source
        self.model = model
        self.bias = bias
        self.audio = audio
        self.unscoredCases = unscoredCases
    }
}

/// A run file: the header line, then one scored case per line. Private, like
/// the cases it scores.
package struct TermRecallRun: Equatable, Sendable {
    package var header: TermRecallRunHeader
    package var scores: [TermRecallCaseScore]

    package init(header: TermRecallRunHeader, scores: [TermRecallCaseScore]) {
        self.header = header
        self.scores = scores
    }

    package func jsonLines() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var lines = [String(decoding: try encoder.encode(header), as: UTF8.self)]
        for score in scores {
            lines.append(String(decoding: try encoder.encode(score), as: UTF8.self))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    package static func parse(jsonLines: String) throws -> TermRecallRun {
        let decoder = JSONDecoder()
        let lines = jsonLines.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard let first = lines.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "empty run file"))
        }
        let header = try decoder.decode(TermRecallRunHeader.self, from: Data(first.utf8))
        let scores = try lines.dropFirst().map {
            try decoder.decode(TermRecallCaseScore.self, from: Data($0.utf8))
        }
        return TermRecallRun(header: header, scores: scores)
    }
}

/// What a run prints. The scoreboard and the comparison hold counts only, so
/// they can go into a PR; the run file between the run sentinels carries case
/// text and stays on the owner's machines.
package enum TermRecallReport {
    package static let scoreboardBegin = "== term-recall scoreboard =="
    package static let scoreboardEnd = "== end term-recall scoreboard =="
    package static let comparisonBegin = "== term-recall comparison =="
    package static let comparisonEnd = "== end term-recall comparison =="
    package static let runBegin = "=== TERM-RECALL-RUN-BEGIN ==="
    package static let runEnd = "=== TERM-RECALL-RUN-END ==="

    package static func scoreboard(_ run: TermRecallRun) -> String {
        let tallies = TermRecallScorer.tally(run.scores)
        var lines = [
            scoreboardBegin,
            describe(run.header),
            "lang  cases  term recall          all terms right  false insertions (session/noise)  non-term WER",
        ]
        for language in ["en", "fr", "all"] {
            guard let tally = tallies[language] else { continue }
            lines.append(
                [
                    pad(language, 4),
                    pad("\(tally.cases)", 5),
                    pad("\(percent(tally.recalled, tally.termOccurrences)) (\(tally.recalled)/\(tally.termOccurrences))", 19),
                    pad("\(tally.casesAllRecalled)/\(tally.casesWithTerms)", 15),
                    pad("\(tally.falseInsertionsSession)/\(tally.falseInsertionsNoise)", 32),
                    "\(percent(tally.nonTermErrors, tally.nonTermWords)) (\(tally.nonTermErrors)/\(tally.nonTermWords))",
                ].joined(separator: "  ")
            )
        }
        if run.header.unscoredCases > 0 {
            lines.append("unscored: \(run.header.unscoredCases) case(s) the speech stage failed on")
        }
        let corpusErrors = tallies["all"]?.corpusErrors ?? 0
        if corpusErrors > 0 {
            lines.append("corpus errors: \(corpusErrors) listed term(s) missing from their case text")
        }
        lines.append(scoreboardEnd)
        return lines.joined(separator: "\n")
    }

    package static func comparison(before: TermRecallRun, after: TermRecallRun) -> String {
        let result = TermRecallScorer.compare(before: before.scores, after: after.scores)
        var lines = [
            comparisonBegin,
            "before: \(describe(before.header))",
            "after:  \(describe(after.header))",
            "paired cases: \(result.pairedCases)",
            "term occurrences gained: \(result.termGains) in \(result.casesWithGain) case(s)",
            "term occurrences lost: \(result.termLosses) in \(result.casesWithLoss) case(s)",
            "false insertions: \(result.falseInsertionsBefore) -> \(result.falseInsertionsAfter)",
            "non-term WER: \(percent(result.nonTermErrorsBefore, result.nonTermWords)) -> "
                + "\(percent(result.nonTermErrorsAfter, result.nonTermWords))",
        ]
        if !result.unpaired.isEmpty {
            lines.append("unpaired cases (in one run only): \(result.unpaired.count)")
        }
        if !result.changed.isEmpty {
            lines.append(
                "cases left out, text changed between the runs (re-harvested?): \(result.changed.count)"
            )
        }
        lines.append(comparisonEnd)
        return lines.joined(separator: "\n")
    }

    private static func describe(_ header: TermRecallRunHeader) -> String {
        "run=\(header.label) source=\(header.source) model=\(header.model ?? "-") "
            + "bias=\(header.bias) audio=\(header.audio)"
    }

    private static func percent(_ part: Int, _ whole: Int) -> String {
        guard whole > 0 else { return "-" }
        return String(format: "%.1f%%", Double(part) * 100 / Double(whole))
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
