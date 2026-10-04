import Foundation

extension StopSecondPass {
    // MARK: - Realtime runs the batch text dropped (#1649)

    /// The shortest run of realtime words the batch text may not drop. On the
    /// owner's 2026-10-03 dictations the batch text left out runs of 1, 1, 3,
    /// 4 and 9 realtime words. The 9-word run was a spoken sentence and the
    /// others were restarts ("on the on two on two") and fillers, which the
    /// batch model removes on purpose.
    package static let minimumRestoredRunWords = 4

    /// What reconciling the batch text with the realtime text produced.
    package struct Reconciled: Equatable, Sendable {
        /// The batch text with each restored run put back where the realtime
        /// text had it.
        package let text: String
        /// Realtime words put back, for the log.
        package let restoredWords: Int
    }

    /// The batch text, plus every run of realtime words it dropped outright.
    ///
    /// The two are aligned word by word, ignoring case and punctuation. A run
    /// of realtime words is put back when all of these hold:
    /// - the batch text has nothing in its place: the words on either side of
    ///   the run (or the text's edge) match words that are adjacent in the
    ///   batch text, so the run is a gap and not a rewording;
    /// - it is `minimumRestoredRunWords` long or longer;
    /// - at least half of its words are absent from the as many realtime
    ///   words on each side of it, so a restart that repeats its neighbours
    ///   stays dropped.
    /// Every other difference keeps the batch text, which is the one with
    /// the vocabulary.
    package static func keepingDroppedRealtimeRuns(
        realtime: String,
        secondPass: String
    ) -> Reconciled {
        let realtimeWords = Self.words(in: realtime)
        let batchWords = Self.words(in: secondPass)
        guard !realtimeWords.isEmpty, !batchWords.isEmpty else {
            return Reconciled(text: secondPass, restoredWords: 0)
        }

        let realtimeKeys = realtimeWords.map(\.key)
        let difference = batchWords.map(\.key).difference(from: realtimeKeys)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        // Realtime index -> batch index of the words both texts share, walked
        // in order: the unchanged words of a diff pair up one to one.
        var batchIndexOfRealtime = [Int: Int]()
        var batchIndex = 0
        for realtimeIndex in realtimeWords.indices where !removed.contains(realtimeIndex) {
            while inserted.contains(batchIndex) { batchIndex += 1 }
            batchIndexOfRealtime[realtimeIndex] = batchIndex
            batchIndex += 1
        }

        // (batch word index the run goes in front of, run), last first so
        // earlier insertion points keep their character offsets.
        var restorations: [(beforeBatchWord: Int, run: Range<Int>)] = []
        var start = 0
        while start < realtimeWords.count {
            guard removed.contains(start) else { start += 1; continue }
            var end = start
            while end < realtimeWords.count, removed.contains(end) { end += 1 }
            let run = start..<end
            start = end

            let batchBefore = run.lowerBound == 0 ? -1 : batchIndexOfRealtime[run.lowerBound - 1]
            let batchAfter = run.upperBound == realtimeWords.count
                ? batchWords.count : batchIndexOfRealtime[run.upperBound]
            guard let batchBefore, let batchAfter, batchAfter == batchBefore + 1 else { continue }
            guard run.count >= minimumRestoredRunWords,
                  Self.isMostlyNew(run, in: realtimeKeys)
            else { continue }
            restorations.append((beforeBatchWord: batchAfter, run: run))
        }
        guard !restorations.isEmpty else {
            return Reconciled(text: secondPass, restoredWords: 0)
        }

        var text = secondPass
        for restoration in restorations.reversed() {
            let lower = realtimeWords[restoration.run.lowerBound].range.lowerBound
            let upper = realtimeWords[restoration.run.upperBound - 1].range.upperBound
            let runText = String(realtime[lower..<upper])
            if restoration.beforeBatchWord == batchWords.count {
                let end = batchWords[batchWords.count - 1].range.upperBound
                let offset = secondPass.distance(from: secondPass.startIndex, to: end)
                text.insert(contentsOf: " " + runText, at: text.index(text.startIndex, offsetBy: offset))
            } else {
                let next = batchWords[restoration.beforeBatchWord].range.lowerBound
                let offset = secondPass.distance(from: secondPass.startIndex, to: next)
                text.insert(contentsOf: runText + " ", at: text.index(text.startIndex, offsetBy: offset))
            }
        }
        return Reconciled(
            text: text,
            restoredWords: restorations.reduce(0) { $0 + $1.run.count })
    }

    private struct Word {
        let range: Range<String.Index>
        /// Lowercased, letters and digits only; the word itself when it has
        /// none, so a lone dash still aligns with a dash.
        let key: String
    }

    private static func words(in text: String) -> [Word] {
        var words: [Word] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else {
                index = text.index(after: index)
                continue
            }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            let raw = text[start..<index]
            let folded = String(raw.lowercased().filter { $0.isLetter || $0.isNumber })
            words.append(Word(range: start..<index, key: folded.isEmpty ? String(raw) : folded))
        }
        return words
    }

    /// Whether at least half of the run's words are absent from the run's
    /// length of realtime words on each side of it.
    private static func isMostlyNew(_ run: Range<Int>, in keys: [String]) -> Bool {
        let before = keys[max(0, run.lowerBound - run.count)..<run.lowerBound]
        let after = keys[run.upperBound..<min(keys.count, run.upperBound + run.count)]
        let neighbours = Set(before).union(after)
        let new = keys[run].filter { !neighbours.contains($0) }.count
        return new * 2 >= run.count
    }
}
