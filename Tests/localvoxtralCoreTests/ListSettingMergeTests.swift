import XCTest

@testable import localvoxtralCore

/// Two running copies editing one list setting (#1575): each copy's adds and
/// removes survive the other's write.
final class ListSettingMergeTests: XCTestCase {
    func testEachCopysAddsAndRemovesSurviveTheOthersWrite() {
        let cases: [(name: String, base: [String], ours: [String], saved: [String], expected: [String])] = [
            ("both add", ["Qwen"], ["Qwen", "Voxtral"], ["Qwen", "Ghostty"], ["Qwen", "Voxtral", "Ghostty"]),
            ("they removed", ["Qwen", "Ghostty"], ["Qwen", "Ghostty", "Voxtral"], ["Qwen"], ["Qwen", "Voxtral"]),
            ("we removed", ["Qwen", "Ghostty"], ["Qwen"], ["Qwen", "Ghostty", "MLX"], ["Qwen", "MLX"]),
            ("we re-add what they removed", ["Qwen"], ["Qwen", "Ghostty"], [], ["Ghostty"]),
            ("we reorder", ["A", "B"], ["B", "A"], ["A", "B"], ["B", "A"]),
            ("nobody else wrote", ["A"], ["A", "B"], ["A"], ["A", "B"]),
        ]
        for c in cases {
            XCTAssertEqual(
                ListSettingMerge.merge(base: c.base, ours: c.ours, saved: c.saved), c.expected, c.name)
        }
    }
}
