import XCTest

@testable import SpeechEngineText

final class BenchTranscriptDigestTests: XCTestCase {
    func testPrintsTheSHA256OfTheUTF8Text() {
        XCTAssertEqual(
            BenchTranscriptDigest.line(for: "abc"),
            "BENCH transcript sha256=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad chars=3"
        )
    }

    func testEmptyTranscriptHasTheEmptyDigest() {
        XCTAssertEqual(
            BenchTranscriptDigest.line(for: ""),
            "BENCH transcript sha256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 chars=0"
        )
    }

    func testOneChangedCharacterChangesTheLine() {
        XCTAssertNotEqual(
            BenchTranscriptDigest.line(for: "the cat sat"),
            BenchTranscriptDigest.line(for: "the cat sad")
        )
    }
}
