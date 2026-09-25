import Foundation
import XCTest
@testable import localvoxtral

final class DictationReplaySupportTests: XCTestCase {
    func testTermRecallCountsTheTermsTheKeptTextSpellsAndTheOutputMatches() {
        let hits = DictationReplaySupport.termHits(
            terms: ["Qwen", "vLLM", "Ghostty", "qwen"],
            reference: "Ask Qwen to run vLLM.",
            output: "Ask quen to run vLLM.")

        // Ghostty is not in the kept text; the second "qwen" is a duplicate.
        XCTAssertEqual(hits.present, 2)
        XCTAssertEqual(hits.recalled, 1)
    }

    func testTermRecallWantsTheExactSpellingAndAWholeWord() {
        let hits = DictationReplaySupport.termHits(
            terms: ["MLX", "Claude Code"],
            reference: "MLX in Claude Code",
            output: "MLXs in claude code")

        XCTAssertEqual(hits.present, 2)
        XCTAssertEqual(hits.recalled, 0)
    }

    func testAnArmAveragesWordAccuracyOverItsDictations() {
        var score = DictationReplaySupport.ArmScore()
        score.add(reference: "one two three four", output: "one two three four", terms: [])
        score.add(reference: "one two three four", output: "one two", terms: [])

        XCTAssertEqual(score.dictations, 2)
        XCTAssertEqual(try XCTUnwrap(score.wordAccuracy), 0.75, accuracy: 1e-9)
    }

    func testTheScoreboardHoldsNumbersOnly() {
        var score = DictationReplaySupport.ArmScore()
        score.add(reference: "Ask Qwen now", output: "Ask Qwen now", terms: ["Qwen"])
        let board = DictationReplaySupport.renderScoreboard(
            header: "1 of 1 dictations", arms: [("today", score)])

        XCTAssertTrue(board.contains("replay: today        1.000          1/1 (100 %)"), board)
        XCTAssertFalse(board.contains("Ask"))
    }

    func testASetReadsItsTermsAndNeedsTheStoreAndTheAudio() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-replay-set-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("dictation-audio"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try DictationReplaySupport.loadSet(at: directory))

        try Data().write(to: directory.appendingPathComponent("default.store"))
        try JSONEncoder().encode(["Qwen", " vLLM "])
            .write(to: directory.appendingPathComponent("speaker-terms.json"))
        var learned = LearnedTerms()
        let now = Date()
        for _ in 0..<LearnedTerms.confirmedDictations {
            learned.record(
                [LearnedTermObservation(term: "Ghostty", source: .repository)],
                project: LearnedTermProjectResolver.shared, now: now)
        }
        learned.record(
            [LearnedTermObservation(term: "herdr", source: .repository)],
            project: LearnedTermProjectResolver.shared, now: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(learned).write(to: directory.appendingPathComponent("learned-terms.json"))

        let set = try DictationReplaySupport.loadSet(at: directory)

        XCTAssertEqual(set.speakerTerms, ["Qwen", "vLLM"])
        // herdr was seen once: not confirmed, so not a learned term yet.
        XCTAssertEqual(set.learnedTerms, ["Ghostty"])
    }
}
