import XCTest
@testable import localvoxtralCore

final class MarkdownCodeFenceTests: XCTestCase {
    func testAFenceLineAnywhereInTheTextCounts() {
        XCTAssertTrue(MarkdownCodeFence.containsFenceLine("see:\n```\nline one\n```\nthanks"))
        XCTAssertTrue(MarkdownCodeFence.containsFenceLine("```swift"))
        XCTAssertTrue(MarkdownCodeFence.containsFenceLine("intro\r\n~~~\ncode"))
    }

    func testAnIndentedFenceCounts() {
        XCTAssertTrue(MarkdownCodeFence.containsFenceLine("list:\n  ```\n  code"))
        XCTAssertTrue(MarkdownCodeFence.containsFenceLine("\t```"))
    }

    func testBackticksLaterInALineDoNot() {
        XCTAssertFalse(MarkdownCodeFence.containsFenceLine("run ```make``` now"))
        XCTAssertFalse(MarkdownCodeFence.containsFenceLine("use `ls` then\n``two"))
        XCTAssertFalse(MarkdownCodeFence.containsFenceLine("first line\nsecond line."))
        XCTAssertFalse(MarkdownCodeFence.containsFenceLine(""))
    }
}
