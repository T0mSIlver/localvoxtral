import Foundation

/// Mistral's realtime stream can stall for a few seconds mid-dictation, then
/// resume with the speech sent during the stall gone from its deltas and from
/// `transcription.done` (symptom D, #1648). When it resumes, the session
/// batch-transcribes the stalled stretch of its recording and splices the
/// words back where the stream skipped them. These are the pure parts: which
/// stall is worth it, which audio to send, and which of the batch's words are
/// new.
package enum StallBackfill {
    /// The loudest 100 ms of the stalled audio must reach this to count as
    /// speech. Speech reads -40 to -20 dBFS and a quiet room below -50; the
    /// two field stalls that lost words (2026-10-03) peaked at -33.
    package static let speechLevelDBFS: Double = -45

    /// Audio taken from before the last server event. The last delta before a
    /// stall covers speech up to a little before it arrived; this much lead
    /// gives the batch text a few words in common with the text before the
    /// hole, which is how its words are placed.
    package static let leadSeconds: Double = 3

    /// How many leading batch words may precede the overlap with the text
    /// before the hole (a word the window cut in half), and how many trailing
    /// ones may follow the overlap with the text after it.
    package static let maxSeamSkipWords = 2

    /// Whether a stall that just ended may have dropped speech.
    package static func isWorthBackfilling(_ stall: MistralStreamHealth.StallEnd) -> Bool {
        guard let loudest = stall.loudestDBFS else { return false }
        return loudest >= speechLevelDBFS
    }

    /// Bytes of 16 kHz mono PCM16 to take from the end of the recording: the
    /// audio sent since the last server event, plus `leadSeconds`. Even, so
    /// the slice starts on a sample.
    package static func windowBytes(for stall: MistralStreamHealth.StallEnd) -> Int {
        let bytes = Int(((stall.audioSeconds + leadSeconds) * 32_000).rounded(.up))
        return bytes + (bytes % 2)
    }

    /// The batch text's words that the realtime text lacks between `before`
    /// and `after`, as the batch spelled them, or nil when there are none or
    /// they cannot be placed.
    ///
    /// The batch window overlaps the text before the hole by `leadSeconds`,
    /// so its leading words repeat the end of `before`: the longest such
    /// overlap, starting within `maxSeamSkipWords` of the batch's start, is
    /// cut. With `before` non-empty and no overlap of at least two words (one
    /// when `before` has one), nothing places the words, and a hole beats a
    /// repeated phrase. The window ends at the resume, where `after` starts,
    /// so a run at the batch's end that repeats the start of `after` is cut
    /// too; finding none keeps the batch's tail.
    package static func wordsToInsert(batch: String, before: String, after: String) -> String? {
        let batchWords = words(in: batch)
        let beforeKeys = words(in: before).map(\.key)
        let afterKeys = words(in: after).map(\.key)
        let batchKeys = batchWords.map(\.key)

        var start = 0
        if !beforeKeys.isEmpty {
            let minimumOverlap = min(2, beforeKeys.count)
            guard let found = leadingOverlapEnd(
                batchKeys, matchingSuffixOf: beforeKeys, minimum: minimumOverlap)
            else { return nil }
            start = found
        }
        var end = batchKeys.count
        if !afterKeys.isEmpty,
            let found = trailingOverlapStart(batchKeys, from: start, matchingPrefixOf: afterKeys)
        {
            end = found
        }
        guard start < end else { return nil }
        return batchWords[start..<end].map(\.text).joined(separator: " ")
    }

    /// The batch index just past the longest run of `before`'s last words
    /// that starts within `maxSeamSkipWords` of the batch's start.
    private static func leadingOverlapEnd(
        _ batch: [String], matchingSuffixOf before: [String], minimum: Int
    ) -> Int? {
        let longest = min(before.count, batch.count)
        guard longest >= minimum else { return nil }
        for length in stride(from: longest, through: minimum, by: -1) {
            let suffix = Array(before.suffix(length))
            for skip in 0...maxSeamSkipWords where skip + length <= batch.count {
                if Array(batch[skip..<skip + length]) == suffix { return skip + length }
            }
        }
        return nil
    }

    /// The batch index where the longest run of `after`'s first words starts,
    /// that run ending within `maxSeamSkipWords` of the batch's end, and
    /// starting no earlier than `lowerBound`.
    private static func trailingOverlapStart(
        _ batch: [String], from lowerBound: Int, matchingPrefixOf after: [String]
    ) -> Int? {
        let longest = min(after.count, batch.count - lowerBound)
        guard longest >= 1 else { return nil }
        for length in stride(from: longest, through: 1, by: -1) {
            let prefix = Array(after.prefix(length))
            // One common word alone says little; it must end the batch.
            for skip in 0...(length == 1 ? 0 : maxSeamSkipWords) {
                let end = batch.count - skip
                guard end - length >= lowerBound else { continue }
                if Array(batch[end - length..<end]) == prefix { return end - length }
            }
        }
        return nil
    }

    private struct Word {
        let text: String
        /// Lowercased, letters and digits only; the word itself when it has
        /// none.
        let key: String
    }

    private static func words(in text: String) -> [Word] {
        text.split(whereSeparator: \.isWhitespace).map { raw in
            let folded = String(raw.lowercased().filter { $0.isLetter || $0.isNumber })
            return Word(text: String(raw), key: folded.isEmpty ? String(raw) : folded)
        }
    }
}
