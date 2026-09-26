import Foundation
import XCTest

@testable import localvoxtralCore

final class TermSuggestionScreenTests: XCTestCase {
    private typealias Dictation = TermSuggestionScreen.Dictation

    /// The owner's chips (#610): words the recognizer spells right go, a
    /// polish fix and a recovered name stay, and the fixes lead.
    func testKeepsOnlyWhatTheRecognizerGetsWrong() {
        let dictations = [
            Dictation(raw: "IBM made the Mac", final: "IBM made the Mac"),
            Dictation(raw: "open it in Word on the Mac", final: "Open it in Word on the Mac."),
            Dictation(raw: "the m c p server", final: "The MCP server."),
            Dictation(raw: "coin 3.6 behind the m c p tools", final: "Qwen 3.6 behind the MCP tools."),
        ]
        XCTAssertEqual(
            TermSuggestionScreen.screened(["IBM", "Mac", "Word", "Qwen", "MCP", "Glossator"], dictations: dictations),
            ["MCP", "Qwen", "Glossator"]
        )
    }

    /// One right spelling is not enough when polishing fixed it elsewhere.
    func testAFixAnywhereOutweighsRightSpellingsElsewhere() {
        let dictations = [
            Dictation(raw: "vLLM serves it", final: "vLLM serves it."),
            Dictation(raw: "v l l m again", final: "vLLM again."),
        ]
        XCTAssertEqual(TermSuggestionScreen.screened(["vLLM"], dictations: dictations), ["vLLM"])
    }

    /// A quoted wrong form counts only where a transcript really has it,
    /// and never when it is the term itself.
    func testHeardFormsCountOnlyWhenTheTranscriptHasThem() {
        let dictations = [
            Dictation(raw: "IBM and vLLM", final: "IBM and vLLM."),
            Dictation(raw: "v l l m is down", final: "v l l m is down."),
        ]
        XCTAssertEqual(
            TermSuggestionScreen.screened(
                ["IBM", "vLLM"], dictations: dictations,
                heard: ["IBM": ["eye bee em", "IBM"], "vLLM": ["v l l m"]]
            ),
            ["vLLM"]
        )
    }

    /// Polishing fixes capitalization without a vocabulary entry: "MAC" for
    /// Mac is not a mistake worth a chip, fixed or quoted (#612).
    func testACapitalizationSlipIsNotAMistake() {
        let dictations = [
            Dictation(raw: "my Mac", final: "My Mac."),
            Dictation(raw: "the MAC again", final: "The Mac again."),
        ]
        XCTAssertEqual(
            TermSuggestionScreen.screened(["Mac"], dictations: dictations, heard: ["Mac": ["MAC"]]),
            []
        )
    }

    func testMatchesWholeWordsOnly() {
        let dictations = [Dictation(raw: "my MacBook and iMac", final: "My MacBook and iMac.")]
        XCTAssertEqual(TermSuggestionScreen.screened(["Mac"], dictations: dictations), ["Mac"])
    }

    func testTiesKeepTheModelsOrder() {
        let dictations = [
            Dictation(raw: "quen and cloud code", final: "Qwen and Claude Code"),
        ]
        XCTAssertEqual(
            TermSuggestionScreen.screened(["Qwen", "Claude Code", "Glossator"], dictations: dictations),
            ["Qwen", "Claude Code", "Glossator"]
        )
    }

    func testDropsBlankCandidates() {
        XCTAssertEqual(TermSuggestionScreen.screened(["  ", ""], dictations: []), [])
    }
}
