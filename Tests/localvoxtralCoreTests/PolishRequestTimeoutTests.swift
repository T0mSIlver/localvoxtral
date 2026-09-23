import Foundation
import XCTest
@testable import localvoxtralCore

final class PolishRequestTimeoutTests: XCTestCase {
    func testTimeoutGrowsWithTheTranscriptBetweenFloorAndCeiling() {
        let cases: [(characters: Int, expected: TimeInterval, line: UInt)] = [
            // Floor: nothing to read or write beyond the fixed prompt.
            (0, 40, #line),
            (-12, 40, #line),
            // Short dictation: a sentence barely moves it.
            (1, 40.05, #line),
            (4, 40.05, #line),
            (5, 40.1, #line),
            (200, 42.5, #line),
            // ~1,500 words (~9,000 characters, 2,250 tokens).
            (9_000, 152.5, #line),
            // Just under and at the ceiling (5,200 tokens).
            (20_796, 299.95, #line),
            (20_800, 300, #line),
            // ~9,000 words, an hour of dictation: capped.
            (54_000, 300, #line),
            (Int.max, 300, #line),
        ]
        for testCase in cases {
            XCTAssertEqual(
                PolishRequestTimeout.seconds(forInputCharacters: testCase.characters),
                testCase.expected,
                accuracy: 1e-9,
                "\(testCase.characters) characters",
                line: testCase.line
            )
        }
    }

    func testTimeoutNeverDecreasesAsTheTranscriptGrows() {
        var previous = PolishRequestTimeout.seconds(forInputCharacters: 0)
        for characters in stride(from: 0, through: 30_000, by: 37) {
            let current = PolishRequestTimeout.seconds(forInputCharacters: characters)
            XCTAssertGreaterThanOrEqual(current, previous, "\(characters) characters")
            previous = current
        }
    }

    func testExplicitOverrideWinsWhateverTheLength() {
        let cases: [(characters: Int, override: TimeInterval, line: UInt)] = [
            // Below the floor, above the ceiling, and in between.
            (0, 5, #line),
            (54_000, 7, #line),
            (0, 420, #line),
            (9_000, 100, #line),
        ]
        for testCase in cases {
            XCTAssertEqual(
                PolishRequestTimeout.seconds(
                    forInputCharacters: testCase.characters,
                    override: testCase.override
                ),
                testCase.override,
                line: testCase.line
            )
        }
    }
}
