import Foundation

/// Decides whether the prompt a user submitted after a dictation shows them
/// correcting a spelling the dictation got wrong, and if so which one.
///
/// The input is the text the app inserted and the text the user finally sent
/// (the joined agent session's `UserPromptSubmit`). The prompt may hold more
/// than the dictation: text typed before or after it is not the dictation's,
/// so the inserted words are located inside the prompt by word alignment and
/// only the aligned span is judged.
///
/// Precision over recall. A wrong verdict puts a spelling into every later
/// prompt of that project, while a missed one costs the user a second fix.
/// So a correction is learned only when the edit is small, is the only
/// substitution in the span, sounds like what it replaced, and produces a
/// spelling shaped like a name or identifier. Everything else is rewording
/// and teaches nothing.
package enum CorrectionDiffClassifier {
    /// A substitution side longer than this is rewording, not a fix. Four
    /// covers `use auth dot ts` → `useAuth.ts`.
    package static let maxFixWords = 4
    /// Words the user may add or remove elsewhere in the span, outside the
    /// one substitution, before the edit counts as rewording.
    package static let maxOtherChangedWords = 3
    /// Share of the inserted words outside the fix that must survive
    /// unchanged. Below it the prompt is not recognizably this dictation.
    package static let minKeptShare = 0.5
    /// Bounds on the alignment. The wire caps a prompt at 8 KiB, about 1,500
    /// words; a dictation past 400 words is not one a user fixes by one word.
    package static let maxInsertedWords = 400
    package static let maxSubmittedWords = 2_000

    package enum Verdict: Equatable, Sendable {
        /// Remember `term`. `forgetting` names a remembered spelling the user
        /// just replaced with it, which goes.
        case learn(term: String, replaced: String, forgetting: String?)
        /// The user changed a remembered spelling back to something that is
        /// not a term: forget it.
        case forget(term: String)
        case nothing(Reason)
    }

    /// Why nothing was learned, for the log. Counts only, never text.
    package enum Reason: String, Equatable, Sendable {
        case empty
        case tooLong
        case notFound
        case unchanged
        case rewording
        case severalFixes
        case fixTooLong
        case notSoundAlike
        case notTermShaped
    }

    /// - Parameters:
    ///   - inserted: exactly what the app inserted.
    ///   - submitted: the prompt the user sent.
    ///   - knownTerms: spellings already known to be the user's vocabulary
    ///     (Names and terms, learned terms). A plain capitalized word is
    ///     learned only when it is one of these.
    ///   - learnedTerms: remembered spellings. Replacing one of them with a
    ///     sound-alike is a revert, and the remembered spelling is forgotten.
    package static func classify(
        inserted: String,
        submitted: String,
        knownTerms: Set<String> = [],
        learnedTerms: Set<String> = []
    ) -> Verdict {
        let old = words(of: inserted)
        let new = words(of: withoutPasteMarkers(submitted))
        guard !old.isEmpty, !new.isEmpty else { return .nothing(.empty) }
        guard old.count <= maxInsertedWords, new.count <= maxSubmittedWords else {
            return .nothing(.tooLong)
        }

        let script = alignment(old, new)
        let kept = script.reduce(0) { $0 + ($1.isEqual ? 1 : 0) }
        guard kept > 0 else { return .nothing(.notFound) }

        let hunks = hunks(of: script)
        var substitutions: [Substitution] = []
        var otherChangedWords = 0
        for hunk in hunks {
            switch hunk.position {
            case .leading where hunk.deleted.isEmpty, .trailing where hunk.deleted.isEmpty:
                // Text the user typed before or after the dictation.
                continue
            default:
                break
            }
            if hunk.deleted.isEmpty || hunk.inserted.isEmpty {
                otherChangedWords += hunk.deleted.count + hunk.inserted.count
                continue
            }
            substitutions.append(Substitution(hunk: hunk, oldWords: hunk.deleted.map { old[$0] }))
        }
        guard otherChangedWords <= maxOtherChangedWords else { return .nothing(.rewording) }
        let fixedWords = substitutions.reduce(0) { $0 + $1.oldWords.count }
        guard Double(kept) >= minKeptShare * Double(old.count - fixedWords) else {
            return .nothing(.rewording)
        }
        guard !substitutions.isEmpty else { return .nothing(.unchanged) }
        guard substitutions.count == 1, let substitution = substitutions.first else {
            return .nothing(.severalFixes)
        }
        guard substitution.oldWords.count <= maxFixWords else { return .nothing(.fixTooLong) }

        let foldedLearned = Set(learnedTerms.map(\.caseFoldedForMatching))
        let foldedKnown = Set(knownTerms.map(\.caseFoldedForMatching)).union(foldedLearned)
        let replaced = trimmedEdges(substitution.oldWords.joined(separator: " "))

        // An edge hunk mixes the fix with text the user added around the
        // dictation, so the fix is the shortest run next to the kept words
        // that passes; an inner hunk is the fix whole.
        var last: Reason = .notSoundAlike
        for candidate in substitution.candidates() {
            guard candidate.count <= maxFixWords else {
                last = .fixTooLong
                continue
            }
            let term = trimmedEdges(candidate.map { new[$0] }.joined(separator: " "))
            let rejection = judge(
                replaced: replaced,
                term: term,
                atSentenceStart: isSentenceStart(candidate.first ?? 0, in: new),
                knownTerms: foldedKnown
            )
            let replacedIsLearned = foldedLearned.contains(replaced.caseFoldedForMatching)
            switch rejection {
            case nil:
                return .learn(term: term, replaced: replaced, forgetting: replacedIsLearned ? replaced : nil)
            case .notTermShaped? where replacedIsLearned:
                return .forget(term: replaced)
            case let reason?:
                last = reason
            }
        }
        return .nothing(last)
    }

    // MARK: Judging one fix

    /// Nil when `term` is a fix of `replaced` worth remembering.
    private static func judge(
        replaced: String,
        term: String,
        atSentenceStart: Bool,
        knownTerms: Set<String>
    ) -> Reason? {
        guard !term.isEmpty, !replaced.isEmpty, term != replaced else { return .unchanged }
        guard soundsAlike(replaced, term) else { return .notSoundAlike }
        guard knownTerms.contains(term.caseFoldedForMatching)
            || isTermShaped(term, atSentenceStart: atSentenceStart)
        else { return .notTermShaped }
        return nil
    }

    /// The same spelling once case, spacing, joiners and spoken separators are
    /// ignored (`use auth dot ts` / `useAuth.ts`); or the same pronunciation
    /// key (`Coin` / `Qwen`); or one or two letters apart in a long word.
    package static func soundsAlike(_ lhs: String, _ rhs: String) -> Bool {
        let left = RepoVocabularyMatcher.normalize(lhs)
        let right = RepoVocabularyMatcher.normalize(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }

        let leftKeys = Set(RepoVocabularyMatcher.phoneticVariants(
            for: RepoVocabularyMatcher.phoneticWordUnits(of: lhs)
        ))
        let rightKeys = RepoVocabularyMatcher.phoneticVariants(
            for: RepoVocabularyMatcher.phoneticWordUnits(of: rhs)
        )
        if rightKeys.contains(where: leftKeys.contains) { return true }

        let longest = max(left.count, right.count)
        return editDistance(left, right) <= max(1, longest / 4)
    }

    /// Looks like a name or identifier rather than an ordinary word: a digit,
    /// a joiner inside it, or a capital that is not just the capital every
    /// sentence starts with. `their` → `there` is a real fix, but a word
    /// every sentence may hold is not vocabulary.
    package static func isTermShaped(_ term: String, atSentenceStart: Bool) -> Bool {
        if term.contains(where: \.isNumber) { return true }
        let inner = term.dropFirst().dropLast()
        if inner.contains(where: { "._-/:@#+".contains($0) }) { return true }
        if term.first.map({ "._-/@#".contains($0) }) == true { return true }
        let capitals = term.enumerated().filter { $0.element.isUppercase }
        if capitals.contains(where: { $0.offset > 0 }) { return true }
        return !capitals.isEmpty && !atSentenceStart
    }

    // MARK: Text

    /// Claude Code hands a long paste to its hook wrapped in
    /// `<pasted_content id="…">…</pasted_content id="…">` (2.1.280, measured
    /// 2026-09-24). The markers are not the user's words.
    package static func withoutPasteMarkers(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"</?pasted_content\b[^>]*>"#,
            with: " ",
            options: .regularExpression
        )
    }

    static func words(of text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Sentence punctuation and quotes come off the ends; joiners inside a
    /// term (`useAuth.ts`) and a leading dot (`.env`) stay.
    package static func trimmedEdges(_ text: String) -> String {
        var result = Substring(text)
        while let first = result.first, "\"'([{«“‘`".contains(first) { result = result.dropFirst() }
        while let last = result.last, ",.;:!?\"')]}»”’`".contains(last) { result = result.dropLast() }
        return String(result)
    }

    private static func isSentenceStart(_ index: Int, in words: [String]) -> Bool {
        guard index > 0 else { return true }
        guard let last = words[index - 1].last else { return true }
        return ".!?:".contains(last) || words[index - 1].hasSuffix("\n")
    }

    // MARK: Alignment

    enum Step: Equatable {
        case equal(old: Int, new: Int)
        case deleted(old: Int)
        case inserted(new: Int)

        var isEqual: Bool {
            if case .equal = self { return true }
            return false
        }
    }

    /// Word-level longest common subsequence, as an edit script in order.
    /// Words compare exactly: a case change is an edit.
    static func alignment(_ old: [String], _ new: [String]) -> [Step] {
        let rows = old.count + 1
        let columns = new.count + 1
        var table = [Int32](repeating: 0, count: rows * columns)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i * columns + j] = old[i] == new[j]
                    ? table[(i + 1) * columns + j + 1] + 1
                    : max(table[(i + 1) * columns + j], table[i * columns + j + 1])
            }
        }
        var steps: [Step] = []
        var i = 0
        var j = 0
        while i < old.count, j < new.count {
            if old[i] == new[j] {
                steps.append(.equal(old: i, new: j))
                i += 1
                j += 1
            } else if table[(i + 1) * columns + j] >= table[i * columns + j + 1] {
                steps.append(.deleted(old: i))
                i += 1
            } else {
                steps.append(.inserted(new: j))
                j += 1
            }
        }
        while i < old.count { steps.append(.deleted(old: i)); i += 1 }
        while j < new.count { steps.append(.inserted(new: j)); j += 1 }
        return steps
    }

    struct Hunk {
        enum Position { case leading, inner, trailing }
        let position: Position
        var deleted: [Int] = []
        var inserted: [Int] = []
    }

    /// Runs of edits between kept words. The run before the first kept word
    /// and the one after the last are marked, since they may hold text the
    /// user added around the dictation.
    static func hunks(of steps: [Step]) -> [Hunk] {
        var result: [Hunk] = []
        var current: Hunk?
        var seenEqual = false
        for step in steps {
            switch step {
            case .equal:
                if let hunk = current { result.append(hunk) }
                current = nil
                seenEqual = true
            case .deleted(let index):
                if current == nil { current = Hunk(position: seenEqual ? .inner : .leading) }
                current?.deleted.append(index)
            case .inserted(let index):
                if current == nil { current = Hunk(position: seenEqual ? .inner : .leading) }
                current?.inserted.append(index)
            }
        }
        if let hunk = current {
            // The run after the last kept word; before any kept word it
            // stays leading.
            result.append(hunk.position == .inner
                ? Hunk(position: .trailing, deleted: hunk.deleted, inserted: hunk.inserted)
                : hunk)
        }
        return result
    }

    private struct Substitution {
        let hunk: Hunk
        let oldWords: [String]

        /// Runs of submitted-word indices to try as the fix, shortest first.
        func candidates() -> [[Int]] {
            let inserted = hunk.inserted
            switch hunk.position {
            case .inner:
                return [inserted]
            case .leading:
                return (1...inserted.count).map { Array(inserted.suffix($0)) }
            case .trailing:
                return (1...inserted.count).map { Array(inserted.prefix($0)) }
            }
        }
    }

    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
