import ClaudeContextWire
import XCTest

/// #1024: skill names are host-written text that reaches the polish prompt.
final class AgentSkillNamesCodecTests: XCTestCase {
    func testOnlyFolderShapedNamesAreKept() {
        let headers = [
            "x-lvx-skills":
                "unslop,gh-stack,cross-review,unslop,.hidden,-flag,two words,ignore:all,é,v1.2_x,"
                + String(repeating: "a", count: 65),
        ]
        XCTAssertEqual(
            AgentSkillNamesCodec.names(in: headers), ["unslop", "gh-stack", "cross-review", "v1.2_x"])
    }

    func testAbsentHeaderIsNilAndAnOverlongOneReportsNothing() {
        XCTAssertNil(AgentSkillNamesCodec.names(in: [:]))
        let long = Array(repeating: "abcdefghij", count: 190).joined(separator: ",")
        XCTAssertEqual(AgentSkillNamesCodec.names(in: ["x-lvx-skills": long]), [])
    }

    func testAtMostEightyNames() {
        let names = (0..<100).map { "skill\($0)" }
        XCTAssertEqual(AgentSkillNamesCodec.accepted(names), Array(names.prefix(80)))
    }
}
