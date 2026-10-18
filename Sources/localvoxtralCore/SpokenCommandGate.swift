import Foundation

/// How a spoken command holds back the words of a Live Auto-Paste segment.
package enum SpokenCommandHold: Sendable {
    /// Held while the words so far may still open with the phrase, and to
    /// the final once they open with it. Anything else is released the
    /// moment a word rules the phrase out ("go to <name>", #747).
    case whileOpening(@Sendable (String) -> SessionVoiceCommandParser.SegmentPrefix)
    /// Held whole from the segment's first word to its final: the phrase
    /// closes the segment ("send it", #318).
    case wholeSegment
}

/// One row of the gate's phrase table.
package struct SpokenCommandRule<Phrase: Sendable>: Sendable {
    package let phrase: Phrase
    package let hold: SpokenCommandHold
    /// Whether a final that came with no partial before it is this
    /// phrase's to decide, when the phrase is armed.
    package let claimsUnheldFinal: @Sendable (String) -> Bool

    package init(
        phrase: Phrase,
        hold: SpokenCommandHold,
        claimsUnheldFinal: @escaping @Sendable (String) -> Bool
    ) {
        self.phrase = phrase
        self.hold = hold
        self.claimsUnheldFinal = claimsUnheldFinal
    }
}

/// The one hold-back between Live Auto-Paste's transcript and its typing
/// (#1853). Typed words cannot be taken back, so a segment that may be a
/// spoken command is held until it is known not to be one, or until its
/// final says which.
///
/// The rows of `rules` claim a segment in table order: a segment reaches a
/// row once every row before it let it go, and the row decides then, from
/// `isArmed`, whether it holds the segment. A held final goes to the row
/// that held it, which acts on it or passes it to the next armed row; past
/// the last row it is typed whole. While `action` runs (a go-to bringing a
/// pane forward, a send reading its pane back), every segment that ends is
/// queued, and the queue replays them from the first row once it is done.
///
/// The gate only decides. Typing and acting are the caller's.
package struct SpokenCommandGate<Phrase: Sendable> {
    /// Where the current segment stands.
    package enum Segment: Equatable, Sendable {
        /// No word of it has arrived.
        case undecided
        /// Row `rule` holds it. `text` is what a `whileOpening` row has
        /// heard so far.
        case held(rule: Int, text: String)
        /// Held behind `action`, to be replayed from the first row.
        case queued
        /// No row holds it: typed as it streams.
        case typing
    }

    /// A segment that ended while `action` ran.
    package enum QueuedSegment: Equatable, Sendable {
        case final(String, merged: String, startsMidWord: Bool)
        case promoted(String, startsMidWord: Bool)
    }

    package enum PartialVerdict: Equatable, Sendable {
        /// Type the delta.
        case deliver
        /// Type nothing yet.
        case withhold
        /// The segment is not a command after all: type what was held,
        /// this delta included, as the partials would have been.
        case release(String)
    }

    package enum FinalVerdict: Equatable, Sendable {
        /// Queued behind `action`.
        case queued
        /// Row `rule` decides the final.
        case decide(rule: Int)
        /// Type what the final adds to the words already typed.
        case deliver
    }

    package enum PromotionVerdict: Equatable, Sendable {
        /// Queued behind `action`.
        case queued
        /// Row `rule` held the promoted text, which is never a command.
        case held(rule: Int)
        /// Its words were typed as they streamed.
        case delivered
    }

    package let rules: [SpokenCommandRule<Phrase>]
    package private(set) var segment = Segment.undecided
    package private(set) var queue: [QueuedSegment] = []
    /// The command in flight. Segments queue while it runs.
    package var action: Task<Void, Never>?

    package init(rules: [SpokenCommandRule<Phrase>]) {
        self.rules = rules
    }

    /// A new dictation, or the end of one: the action is cancelled and
    /// nothing carries over.
    package mutating func reset() {
        action?.cancel()
        action = nil
        queue = []
        segment = .undecided
    }

    /// Empties the queue and returns what it held, in order.
    package mutating func takeQueue() -> [QueuedSegment] {
        defer { queue = [] }
        return queue
    }

    /// The next queued segment, once no action runs.
    package mutating func nextQueued() -> QueuedSegment? {
        guard action == nil, !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }

    package mutating func partial(_ delta: String, isArmed: (Phrase) -> Bool) -> PartialVerdict {
        switch segment {
        case .undecided:
            if action != nil {
                segment = .queued
                return .withhold
            }
            return claim(from: 0, heard: delta, isArmed: isArmed)
        case .queued:
            return .withhold
        case .typing:
            return .deliver
        case .held(let rule, let text):
            guard case .whileOpening(let prefix) = rules[rule].hold else { return .withhold }
            let heard = text + delta
            switch prefix(heard) {
            case .undecided, .possibleCommand:
                segment = .held(rule: rule, text: heard)
                return .withhold
            case .ordinary:
                return claim(from: rule + 1, heard: heard, isArmed: isArmed)
            }
        }
    }

    /// The segment's final. `finalText` is the backend's, `merged` the
    /// accumulator's; only the queue keeps `merged` and `startsMidWord`.
    package mutating func final(
        _ finalText: String,
        merged: String,
        startsMidWord: Bool,
        isArmed: (Phrase) -> Bool
    ) -> FinalVerdict {
        let state = segment
        segment = .undecided
        switch state {
        case .typing:
            return .deliver
        case .held(let rule, _):
            return .decide(rule: rule)
        case .queued, .undecided:
            if action != nil {
                queue.append(.final(finalText, merged: merged, startsMidWord: startsMidWord))
                return .queued
            }
            if state == .queued { return .decide(rule: 0) }
            let claimant = rules.indices.first {
                isArmed(rules[$0].phrase) && rules[$0].claimsUnheldFinal(finalText)
            }
            return claimant.map { .decide(rule: $0) } ?? .deliver
        }
    }

    /// The segment promoted without a final (a stop, a dropped socket).
    package mutating func promotion(_ text: String, startsMidWord: Bool) -> PromotionVerdict {
        let state = segment
        segment = .undecided
        switch state {
        case .typing, .undecided:
            return .delivered
        case .held(let rule, _):
            return .held(rule: rule)
        case .queued:
            if action != nil {
                queue.append(.promoted(text, startsMidWord: startsMidWord))
                return .queued
            }
            return .held(rule: 0)
        }
    }

    /// The row a held final or promotion passes to when `rule` lets it go:
    /// the next one armed now, or nil when it is typed whole.
    package func nextArmedRule(after rule: Int, isArmed: (Phrase) -> Bool) -> Int? {
        rules.indices.first { $0 > rule && isArmed(rules[$0].phrase) }
    }

    /// The segment reaches row `first` with `heard` so far.
    private mutating func claim(from first: Int, heard: String, isArmed: (Phrase) -> Bool) -> PartialVerdict {
        for rule in rules.indices where rule >= first && isArmed(rules[rule].phrase) {
            switch rules[rule].hold {
            case .wholeSegment:
                segment = .held(rule: rule, text: "")
                return .withhold
            case .whileOpening(let prefix):
                if prefix(heard) == .ordinary { continue }
                segment = .held(rule: rule, text: heard)
                return .withhold
            }
        }
        segment = .typing
        return first == 0 ? .deliver : .release(heard)
    }
}
