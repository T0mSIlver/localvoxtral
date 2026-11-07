import Foundation

/// What became of the term suggestions Settings offered, week by week and
/// by where they came from: the measure of whether suggestions are relevant
/// (LVX-11). Counts only: no term, no dictation text. It stays on the Mac
/// and nothing shows it; a script reads it.
package struct TermSuggestionOutcomes: Codable, Equatable, Sendable {
    package enum Source: String, Codable, Sendable, CaseIterable {
        /// A learned term the app watched polishing fix.
        case learned
        /// A term a model run found in the history.
        case model
    }

    package enum Event: Sendable {
        case shown, accepted, refused
    }

    package struct Counts: Codable, Equatable, Sendable {
        package var shown = 0
        package var accepted = 0
        package var refused = 0

        package init(shown: Int = 0, accepted: Int = 0, refused: Int = 0) {
            self.shown = shown
            self.accepted = accepted
            self.refused = refused
        }
    }

    package struct Week: Codable, Equatable, Sendable {
        /// The week's first second, in 7-day steps from 1970.
        package var start: Date
        package var learned = Counts()
        package var model = Counts()

        package init(start: Date, learned: Counts = Counts(), model: Counts = Counts()) {
            self.start = start
            self.learned = learned
            self.model = model
        }
    }

    /// Half a year: enough for a trend, small enough to rewrite on each event.
    package static let keptWeeks = 26
    package static let weekSeconds: TimeInterval = 7 * 86_400

    /// Oldest first.
    package private(set) var weeks: [Week] = []

    package init(weeks: [Week] = []) {
        self.weeks = weeks
    }

    package static func weekStart(of date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / weekSeconds).rounded(.down) * weekSeconds)
    }

    package mutating func record(_ event: Event, source: Source, count: Int = 1, at date: Date) {
        guard count > 0 else { return }
        let start = Self.weekStart(of: date)
        let index: Int
        if let existing = weeks.firstIndex(where: { $0.start == start }) {
            index = existing
        } else {
            weeks.append(Week(start: start))
            weeks.sort { $0.start < $1.start }
            index = weeks.firstIndex { $0.start == start }!
        }
        func bump(_ counts: inout Counts) {
            switch event {
            case .shown: counts.shown += count
            case .accepted: counts.accepted += count
            case .refused: counts.refused += count
            }
        }
        switch source {
        case .learned: bump(&weeks[index].learned)
        case .model: bump(&weeks[index].model)
        }
        if weeks.count > Self.keptWeeks { weeks.removeFirst(weeks.count - Self.keptWeeks) }
    }
}
