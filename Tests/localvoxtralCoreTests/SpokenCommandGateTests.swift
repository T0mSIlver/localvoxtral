import XCTest
@testable import localvoxtralCore

/// #1853: a spoken command is one row in the gate's table. The rows below are
/// the app's one ("send it", held whole) with a made-up "scratch that" ahead
/// of it; the gate holds each from its first word to its final and hands the
/// row that held it the final, with no code of its own.
final class SpokenCommandGateTests: XCTestCase {
    enum Phrase: Equatable, Sendable { case scratch, send }

    static let rules: [SpokenCommandRule<Phrase>] = [
        SpokenCommandRule(phrase: .scratch, claimsUnheldFinal: { $0.lowercased().hasPrefix("scratch that") }),
        SpokenCommandRule(phrase: .send, claimsUnheldFinal: { _ in true }),
    ]

    func testTheFirstArmedRowHoldsTheSegmentAndDecidesItsFinal() {
        typealias Partial = SpokenCommandGate<Phrase>.PartialVerdict
        typealias Final = SpokenCommandGate<Phrase>.FinalVerdict
        let cases: [(name: String, armed: Set<Phrase>, partials: [String], partialVerdicts: [Partial], final: String, finalVerdict: Final)] = [
            ("both armed: the first holds it whole",
             [.scratch, .send], ["scr", "atch th", "at"], [.withhold, .withhold, .withhold],
             "scratch that", .decide(rule: 0)),
            ("only the later row armed: it holds",
             [.send], ["screw", " it"], [.withhold, .withhold],
             "screw it", .decide(rule: 1)),
            ("unarmed, nothing is held",
             [], ["scratch that"], [.deliver],
             "scratch that", .deliver),
            ("a final with no partial is claimed by its row",
             [.scratch], [], [],
             "scratch that", .decide(rule: 0)),
            ("a final no armed row claims is typed",
             [.scratch], [], [],
             "something else", .deliver),
        ]
        for c in cases {
            var gate = SpokenCommandGate(rules: Self.rules)
            let verdicts = c.partials.map { gate.partial($0, isArmed: { c.armed.contains($0) }) }
            XCTAssertEqual(verdicts, c.partialVerdicts, c.name)
            XCTAssertEqual(
                gate.final(c.final, merged: c.final, startsMidWord: false, isArmed: { c.armed.contains($0) }),
                c.finalVerdict, c.name
            )
            XCTAssertEqual(gate.segment, .undecided, c.name)
        }
    }

    func testARowThatLetsAFinalGoPassesItToTheNextArmedRow() {
        let gate = SpokenCommandGate(rules: Self.rules)
        XCTAssertEqual(gate.nextArmedRule(after: 0, isArmed: { _ in true }), 1)
        XCTAssertNil(gate.nextArmedRule(after: 0, isArmed: { $0 == .scratch }))
        XCTAssertNil(gate.nextArmedRule(after: 1, isArmed: { _ in true }))
    }

    /// While a command acts, segments queue whatever the rows say, and
    /// replay from the first row once it is done.
    func testSegmentsQueueBehindAnActionAndReplayFromTheFirstRow() {
        var gate = SpokenCommandGate(rules: Self.rules)
        gate.action = Task {}
        XCTAssertEqual(gate.partial("scratch that", isArmed: { _ in true }), .withhold)
        XCTAssertEqual(gate.final("scratch that", merged: "scratch that", startsMidWord: false, isArmed: { _ in true }), .queued)
        XCTAssertEqual(gate.partial("more", isArmed: { _ in true }), .withhold)
        XCTAssertEqual(gate.promotion("more", startsMidWord: false), .queued)
        XCTAssertNil(gate.nextQueued(), "nothing replays while the action runs")
        gate.action = nil
        XCTAssertEqual(gate.nextQueued(), .final("scratch that", merged: "scratch that", startsMidWord: false))
        XCTAssertEqual(gate.nextQueued(), .promoted("more", startsMidWord: false))
        XCTAssertNil(gate.nextQueued())
    }
}
