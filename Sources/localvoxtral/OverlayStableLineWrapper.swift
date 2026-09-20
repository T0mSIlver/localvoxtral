import CoreGraphics
import Foundation

/// Breaks the overlay buffer's lines itself, so streamed text never re-wraps.
///
/// Realtime deltas arrive mid-word ("dicta" → "dictation"). Left to the text
/// engine, the line break for that word is decided from the width it has right
/// now: a half-typed word that still fits at the end of a line jumps to the
/// next one as the rest of it lands, and the whole buffer visibly reshuffles
/// while the user dictates.
///
/// Two rules remove that:
/// - **Greedy wrapping of finished words.** They never move, because the
///   transcript only ever grows at its end.
/// - **A reserve for the word still being streamed.** A word that starts with
///   less than `reserveWidth` of room left goes onto the next line straight
///   away, where it has a full line to grow into, instead of starting at the
///   edge and hopping.
///
/// The forced break is then **remembered for the session**: without that, the
/// word would snap back up to the previous line the moment it turned out to
/// fit — the same jump, in the other direction.
///
/// What survives: a word longer than the room it started with still hops, which
/// needs a word longer than the reserve starting where the line had plenty of
/// space. Rare, where the old behavior was constant.
///
/// Widths come from an injected measurer so the rules can be tested exactly,
/// without a text engine. `DictationOverlayController` passes the real one.
struct OverlayStableLineWrapper {
    typealias WidthMeasure = (String) -> CGFloat

    /// Width the rendered text has to fit into.
    private let availableWidth: CGFloat
    /// Room a still-growing word needs to start a line mid-way through it.
    private let reserveWidth: CGFloat
    private let widthOf: WidthMeasure
    /// Slack held back from `availableWidth`. Line widths are summed from word
    /// widths, so they can run a hair under what the text engine draws; a line
    /// that the engine wraps after we already broke it would move a word, which
    /// is the whole thing this type exists to prevent.
    private let safetyMargin: CGFloat

    /// Character offsets of words pushed onto their own line while incomplete.
    /// Keyed by offset because the transcript grows at its end, so an offset
    /// keeps pointing at the same word; a rewrite upstream can shift one, and a
    /// stale offset that no longer starts a word is simply never consulted.
    private var forcedBreakOffsets: Set<Int> = []
    private var widthCache: [String: CGFloat] = [:]

    init(
        availableWidth: CGFloat,
        reserveWidth: CGFloat,
        safetyMargin: CGFloat = 4,
        widthOf: @escaping WidthMeasure
    ) {
        self.availableWidth = availableWidth
        self.reserveWidth = reserveWidth
        self.safetyMargin = safetyMargin
        self.widthOf = widthOf
    }

    /// Ends the session: the next wrap starts with no remembered breaks.
    mutating func reset() {
        forcedBreakOffsets.removeAll()
        widthCache.removeAll()
    }

    /// Returns `text` with the line breaks written in.
    mutating func wrapped(_ text: String) -> String {
        let characters = Array(text)
        guard !characters.isEmpty else { return text }

        let lineWidth = max(availableWidth - safetyMargin, 1)
        // Only the last word can still be growing, and only when the text does
        // not already end at a word boundary — a trailing space or a "." means
        // the stream finished it.
        let lastWordIsGrowing = Self.isWordCharacter(characters[characters.count - 1])

        var lines: [String] = []
        var line = ""
        var lineUsed: CGFloat = 0
        var offset = 0

        while offset < characters.count {
            var separator = ""
            while offset < characters.count, characters[offset].isWhitespace {
                separator.append(characters[offset])
                offset += 1
            }
            let wordStart = offset
            var word = ""
            while offset < characters.count, !characters[offset].isWhitespace {
                word.append(characters[offset])
                offset += 1
            }
            guard !word.isEmpty else { break }  // trailing whitespace only

            let isLastWord = offset == characters.count
            let separatorWidth = line.isEmpty ? 0 : width(of: separator)
            let wordWidth = width(of: word)

            if line.isEmpty {
                line = word
                lineUsed = wordWidth
                continue
            }

            let breaksHere: Bool
            if forcedBreakOffsets.contains(wordStart) {
                breaksHere = true
            } else if lineUsed + separatorWidth + wordWidth > lineWidth {
                // A growing word that outran the room it started in has to move
                // — the residual case this type cannot prevent. Remember it all
                // the same, so a later rewrite of that word cannot pull it back
                // up to where it was.
                if isLastWord, lastWordIsGrowing {
                    forcedBreakOffsets.insert(wordStart)
                }
                breaksHere = true
            } else if isLastWord, lastWordIsGrowing,
                lineWidth - (lineUsed + separatorWidth) < reserveWidth
            {
                forcedBreakOffsets.insert(wordStart)
                breaksHere = true
            } else {
                breaksHere = false
            }

            if breaksHere {
                lines.append(line)
                line = word
                lineUsed = wordWidth
            } else {
                line += separator + word
                lineUsed += separatorWidth + wordWidth
            }
        }

        lines.append(line)
        return lines.joined(separator: "\n")
    }

    private mutating func width(of text: String) -> CGFloat {
        if let cached = widthCache[text] { return cached }
        let measured = widthOf(text)
        widthCache[text] = measured
        return measured
    }

    /// Letters, digits and the marks a delta can split a word inside. Anything
    /// else at the end of the text — whitespace, `.`, `,`, a closing quote —
    /// means the stream finished that word, so it will not grow any further.
    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "\u{2019}"
            || character == "-"
    }
}
