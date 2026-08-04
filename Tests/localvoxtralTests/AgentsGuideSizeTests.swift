import XCTest

/// The root `AGENTS.md` is always-loaded context for every coding agent, and
/// some tools truncate it SILENTLY: Codex caps project docs at 32 KiB
/// (`project_doc_max_bytes`, default 32768) and drops everything past the cap
/// with only a tracing warning. At 68 KB the old file lost its entire
/// invariants section to that cap. Deep material belongs in `docs/agent/` or
/// a colocated `AGENTS.md`, routed to from the root file — this test is the
/// backstop that keeps the root file under the cap with headroom.
final class AgentsGuideSizeTests: XCTestCase {
    private static let codexProjectDocMaxBytes = 32_768

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testRootAgentsGuideStaysUnderTheCodexTruncationCap() throws {
        let agentsGuide = repoRoot.appendingPathComponent("AGENTS.md")
        let byteCount = try Data(contentsOf: agentsGuide).count

        XCTAssertLessThan(
            byteCount,
            Self.codexProjectDocMaxBytes,
            """
            AGENTS.md is \(byteCount) bytes; Codex silently truncates it at \
            \(Self.codexProjectDocMaxBytes). Move deep or situational content \
            into docs/agent/ (or a colocated AGENTS.md) and route to it from \
            the root file — see "Rules for editing THIS file" in AGENTS.md.
            """
        )
    }

    func testRouterTargetsExist() throws {
        // The router is only worth its lines if every pointer resolves; a
        // moved guide must update the router in the same PR.
        let routedPaths = [
            "docs/architecture.md",
            "docs/agent/invariants.md",
            "docs/agent/field-debugging.md",
            "docs/agent/test-tiers.md",
            "PolishHelper/AGENTS.md",
            "SpeechHelper/AGENTS.md",
            "EvalCorpus/agent-dictation/AGENTS.md",
            "Sources/localvoxtral/ClaudeContext/AGENTS.md",
            "integrations/claude-code/AGENTS.md",
        ]
        for path in routedPaths {
            let url = repoRoot.appendingPathComponent(path)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "AGENTS.md routes agents to \(path), which does not exist"
            )
        }
    }
}
