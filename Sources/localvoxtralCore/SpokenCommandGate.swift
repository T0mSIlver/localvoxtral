import Foundation

/// One row of the gate's phrase table.
package struct SpokenCommandRule<Phrase: Sendable>: Sendable {
    package let phrase: Phrase
    /// Whether a final that came with no partial before it is this
    /// phrase's to decide, when the phrase is armed.
    package let claimsUnheldFinal: @Sendable (String) -> Bool

    package init(
        phrase: Phrase,
        claimsUnheldFinal: @escaping @Sendable (String) -> Bool
    ) {
        self.phrase = phrase
        self.claimsUnheldFinal = claimsUnheldFinal
    }
}

/// The one hold-back between Live Auto-Paste's transcript and its typing
/// (#1853). Typed words cannot be taken back, so a segment that may be a
/// spoken command is held from its first word to its final, which says
/// which ("send it" closes the segment, #318).
///
/// The rows of `rules` claim a segment in table order: the first armed row
/// holds it. A held final goes to the row that held it, which acts on it or
/// passes it to the next armed row; past the last row it is typed whole.
/// While `action` runs (a send reading its pane back), every segment that
/// ends is queued, and the queue replays them from the first row once it is
/// done.
///
/// The gate only decides. Typing and acting are the caller's.
package struct SpokenCommandGate<Phrase: Sendable> {
    /// Where the current segment stands.
    package enum Segment: Equatable, Sendable {
        /// No word of it has arrived.
        case undecided
        /// Row `rule` holds it.
        case held(rule: Int)
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
            return claim(isArmed: isArmed)
        case .queued:
            return .withhold
        case .typing:
            return .deliver
        case .held:
            return .withhold
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
        case .held(let rule):
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
        case .held(let rule):
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

    /// The segment's first word: the first armed row holds it.
    private mutating func claim(isArmed: (Phrase) -> Bool) -> PartialVerdict {
        if let rule = rules.indices.first(where: { isArmed(rules[$0].phrase) }) {
            segment = .held(rule: rule)
            return .withhold
        }
        segment = .typing
        return .deliver
    }
}
