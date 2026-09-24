import Foundation
import XCTest

@testable import localvoxtralCore

/// What "Copy last dictation" copies (#526).
final class LastDictationCopyTests: XCTestCase {
    func testAPolishedDictationCopiesThePolishedText() {
        XCTAssertEqual(
            LastDictationCopy.text(
                rawText: "so um the build is red", polishedText: "The build is red.",
                polishFailed: false),
            "The build is red."
        )
    }

    func testAnUnchangedDictationCopiesTheTranscript() {
        XCTAssertEqual(
            LastDictationCopy.text(rawText: " the build is red ", polishedText: nil, polishFailed: false),
            "the build is red"
        )
    }

    /// A failed polish can still leave the replacement dictionary's text in
    /// `polishedText`; the copy is the transcript all the same.
    func testAFailedPolishCopiesTheRawTranscript() {
        XCTAssertEqual(
            LastDictationCopy.text(
                rawText: "open the read me", polishedText: "open the README", polishFailed: true),
            "open the read me"
        )
    }

    /// A session cut short is saved with what was transcribed before it died,
    /// and nothing was polished.
    func testAPartialDictationCopiesWhatWasTranscribed() {
        XCTAssertEqual(
            LastDictationCopy.text(rawText: "the first half of the", polishedText: nil, polishFailed: false),
            "the first half of the"
        )
    }

    func testAnEmptyPolishFallsBackToTheTranscript() {
        XCTAssertEqual(
            LastDictationCopy.text(rawText: "keep this", polishedText: "  \n", polishFailed: false),
            "keep this"
        )
    }

    func testNothingTranscribedCopiesNothing() {
        XCTAssertNil(LastDictationCopy.text(rawText: " \n ", polishedText: nil, polishFailed: false))
        XCTAssertNil(LastDictationCopy.text(rawText: "", polishedText: "x", polishFailed: true))
    }
}
