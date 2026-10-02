import Foundation
import XCTest
@testable import localvoxtralCore

/// The round trip every caller relies on: whatever the user's file looked
/// like, adding our block and taking it back out leaves it byte for byte
/// (#1178). The shell rc, Vibe's `hooks.toml` and the dictation note files
/// all go through this type.
final class MarkedTextBlockTests: XCTestCase {
    private let block = MarkedTextBlock(markerBegin: "# >>> test >>>", markerEnd: "# <<< test <<<")
    private let snippet = "# >>> test >>>\nexport TEST=1\n# <<< test <<<"

    /// Every shape the issue names: LF and CRLF, with and without a final
    /// newline, and zero, one or two trailing blank lines.
    private var shapes: [String] {
        let lf = [
            "",
            "# Notes",
            "# Notes\n",
            "# Notes\n\n",
            "# Notes\n\n\n",
            "first\nsecond",
            "first\nsecond\n",
            "first\n\nsecond\n\n",
            "\n",
            "\n\n",
        ]
        let mixed = ["first\r\nsecond\n", "first\nsecond\r\n", "first\r\nsecond", "first\nsecond\r\n\r\n"]
        return lf + lf.map { $0.replacingOccurrences(of: "\n", with: "\r\n") } + mixed
    }

    func testApplyThenRemoveIsByteIdenticalForEveryShape() throws {
        for original in shapes {
            let applied = try XCTUnwrap(block.apply(to: original, snippet: snippet))
            XCTAssertTrue(block.containsBlock(applied), "\(original.debugDescription)")
            let removed = try XCTUnwrap(block.remove(from: applied))
            XCTAssertEqual(
                removed, original,
                "apply then remove of \(original.debugDescription) went through \(applied.debugDescription)"
            )
        }
    }

    func testAFileEndingInABlankLineKeepsItThroughTheRoundTrip() throws {
        // The audit's case (s19-a-1): the blank line is the user's, not a
        // separator we added, so remove must not take it.
        let applied = try XCTUnwrap(block.apply(to: "# Notes\n\n", snippet: snippet))
        XCTAssertEqual(try XCTUnwrap(block.remove(from: applied)), "# Notes\n\n")
    }

    func testApplyStillSeparatesTheBlockFromTheUsersLastLine() throws {
        XCTAssertEqual(block.apply(to: "# Notes\n", snippet: snippet), "# Notes\n\n" + snippet + "\n")
        XCTAssertEqual(block.apply(to: "", snippet: snippet), snippet + "\n")
    }

    func testABlockAnOlderBuildWroteRemovesAsBefore() throws {
        // Older builds added no separator after a trailing blank line, and
        // terminated the file after the block. Remove keeps reading those
        // the way it always has.
        XCTAssertEqual(block.remove(from: "# Notes\n\n" + snippet + "\n"), "# Notes\n")
        XCTAssertEqual(block.remove(from: "# Notes\n\n" + snippet + "\n# More\n"), "# Notes\n# More\n")
    }
}
