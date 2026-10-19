import XCTest
@testable import localvoxtralCore

/// #1853: a new spoken command is one row in the gate's table. The rows
/// below are the app's two (go-to, send) with a made-up "scratch that"
/// between them; the gate holds, releases and hands it its final with no
/// code of its own.
final class SpokenCommandGateTests: XCTestCase {
    enum Phrase: Equatable, Sendable { case goTo, scratch, send }

    static let scratchPrefix: @Sendable (String) -> SessionVoiceCommandParser.SegmentPrefix = { heard in
        let heard = heard.lowercased()
        if "scratch that".hasPrefix(heard) { return .undecided }
        return heard.hasPrefix("scratch that") ? .possibleCommand : .ordinary
    }

    static let rules: [SpokenCommandRule<Phrase>] = [
        SpokenCommandRule(
            phrase: .goTo,
            hold: .whileOpening(SessionVoiceCommandParser.segmentPrefix),
            claimsUnheldFinal: { SessionVoiceCommandParser.command(in: $0) != nil }
        ),
        SpokenCommandRule(
            phrase: .scratch,
            hold: .whileOpening(scratchPrefix),
            claimsUnheldFinal: { $0.lowercased().hasPrefix("scratch that") }
        ),
        SpokenCommandRule(phrase: .send, hold: .wholeSegment, claimsUnheldFinal: { _ in true }),
    ]

    func testANewPhraseIsHeldAndDecidedFromItsRowAlone() {
        typealias Partial = SpokenCommandGate<Phrase>.PartialVerdict
        typealias Final = SpokenCommandGate<Phrase>.FinalVerdict
        let cases: [(name: String, armed: Set<Phrase>, partials: [String], partialVerdicts: [Partial], final: String, finalVerdict: Final)] = [
            ("the new phrase is held to its final, then decides it",
             [.goTo, .scratch], ["scr", "atch th", "at"], [.withhold, .withhold, .withhold],
             "scratch that", .decide(rule: 1)),
            ("released at the letter that rules it out, as partials would have been",
             [.goTo, .scratch], ["scr", "ew it"], [.withhold, .release("screw it")],
             "screw it", .deliver),
            ("go-to keeps its place ahead of it",
             [.goTo, .scratch], ["go t", "o payments"], [.withhold, .withhold],
             "go to payments", .decide(rule: 0)),
            ("ruled out, it goes on to the send trigger",
             [.goTo, .scratch, .send], ["scr", "ew it"], [.withhold, .withhold],
             "screw it", .decide(rule: 2)),
            ("unarmed, it holds nothing",
             [], ["scratch that"], [.deliver],
             "scratch that", .deliver),
            ("a final with no partial is claimed by its row",
             [.scratch], [], [],
             "scratch that", .decide(rule: 1)),
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
