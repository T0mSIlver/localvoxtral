import XCTest
@testable import localvoxtralCore

final class UnicodeEventChunksTests: XCTestCase {
    /// Each chunk must decode on its own: a surrogate pair split across two
    /// events reaches the target app as two replacement characters (#1092).
    private func assertEachChunkIsValidUTF16(
        _ chunks: [[UInt16]], file: StaticString = #filePath, line: UInt = #line
    ) {
        for chunk in chunks {
            XCTAssertNotNil(
                String(validating: chunk, as: UTF16.self),
                "chunk \(chunk.map { String($0, radix: 16) }) is not valid UTF-16",
                file: file, line: line
            )
        }
    }

    func testAnEmojiStraddlingTheBoundaryStaysWhole() {
        let text = String(repeating: "a", count: 19) + "😀" + "b"
        let chunks = UnicodeEventChunks.chunks(text)

        assertEachChunkIsValidUTF16(chunks)
        XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
        XCTAssertTrue(chunks.allSatisfy { $0.count <= UnicodeEventChunks.maxUnits })
    }

    func testAGraphemeClusterStraddlingTheBoundaryStaysWhole() {
        // "e" + combining acute: split, the accent would land on the next
        // chunk's first character in apps that compose per event.
        let text = String(repeating: "a", count: 19) + "e\u{301}" + "b"
        let chunks = UnicodeEventChunks.chunks(text)

        XCTAssertEqual(chunks.map { $0.count }, [19, 3])
        XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
    }

    func testAClusterLongerThanOneEventSplitsOnlyBetweenScalars() {
        // A family emoji with skin tones, repeated inside one ZWJ sequence,
        // runs past 20 units as a single Character; after "xy", unit 20
        // falls between the halves of the first family's last skin tone.
        let family = "👩🏽\u{200D}👨🏽\u{200D}👧🏽\u{200D}👦🏽"
        let text = "xy" + family + "\u{200D}" + family
        XCTAssertEqual(text.count, 3)
        let chunks = UnicodeEventChunks.chunks(text)

        assertEachChunkIsValidUTF16(chunks)
        XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
        XCTAssertTrue(chunks.allSatisfy { $0.count <= UnicodeEventChunks.maxUnits })
    }

    func testPlainASCIIKeepsFullEvents() {
        let text = String(repeating: "a", count: 45)
        XCTAssertEqual(UnicodeEventChunks.chunks(text).map { $0.count }, [20, 20, 5])
        XCTAssertEqual(UnicodeEventChunks.chunks(""), [])
    }
}
