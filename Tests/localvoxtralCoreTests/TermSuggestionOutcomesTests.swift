import Foundation
import XCTest

@testable import localvoxtralCore

/// The suggestion-outcome counts (LVX-11): per week, per source, counts only.
final class TermSuggestionOutcomesTests: XCTestCase {
    private let monday = Date(timeIntervalSince1970: 1_790_000_000)

    func testEventsLandInTheirWeekAndSource() {
        var outcomes = TermSuggestionOutcomes()
        outcomes.record(.shown, source: .learned, count: 3, at: monday)
        outcomes.record(.accepted, source: .learned, at: monday.addingTimeInterval(60))
        outcomes.record(.refused, source: .model, at: monday.addingTimeInterval(120))
        outcomes.record(.shown, source: .model, count: 2, at: monday.addingTimeInterval(TermSuggestionOutcomes.weekSeconds))

        XCTAssertEqual(outcomes.weeks.count, 2)
        XCTAssertEqual(outcomes.weeks[0].learned, .init(shown: 3, accepted: 1, refused: 0))
        XCTAssertEqual(outcomes.weeks[0].model, .init(shown: 0, accepted: 0, refused: 1))
        XCTAssertEqual(outcomes.weeks[1].model, .init(shown: 2))
        XCTAssertLessThan(outcomes.weeks[0].start, outcomes.weeks[1].start)
    }

    func testOnlyTheNewestWeeksAreKeptAndALateEventFindsItsWeek() {
        var outcomes = TermSuggestionOutcomes()
        for week in 0..<(TermSuggestionOutcomes.keptWeeks + 2) {
            outcomes.record(.shown, source: .model, at: monday.addingTimeInterval(Double(week) * TermSuggestionOutcomes.weekSeconds))
        }
        XCTAssertEqual(outcomes.weeks.count, TermSuggestionOutcomes.keptWeeks)
        XCTAssertEqual(
            outcomes.weeks.first?.start,
            TermSuggestionOutcomes.weekStart(of: monday.addingTimeInterval(2 * TermSuggestionOutcomes.weekSeconds)))

        let newest = monday.addingTimeInterval(Double(TermSuggestionOutcomes.keptWeeks + 1) * TermSuggestionOutcomes.weekSeconds)
        outcomes.record(.accepted, source: .model, at: newest)
        XCTAssertEqual(outcomes.weeks.last?.model, .init(shown: 1, accepted: 1))
    }

    /// The app saves it as JSON in its defaults and reads it back each event.
    func testItRoundTrips() throws {
        var outcomes = TermSuggestionOutcomes()
        outcomes.record(.accepted, source: .learned, at: monday)
        let data = try JSONEncoder().encode(outcomes)
        XCTAssertEqual(try JSONDecoder().decode(TermSuggestionOutcomes.self, from: data), outcomes)
    }
}
