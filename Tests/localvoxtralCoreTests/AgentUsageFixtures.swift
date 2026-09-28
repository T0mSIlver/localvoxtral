import Foundation
import XCTest

@testable import localvoxtralCore

/// What the agents report about a run's usage, as measured (#854), and the
/// fakes that report it the same way.
enum AgentUsageFixtures {
    /// `claude -p --output-format json --json-schema …` for a terms run
    /// (Claude Code 2.1.283, 2026-09-27), cut to the fields the Mac reads
    /// and a few it ignores.
    static let claudeTermsResult = #"""
        {"type":"result","subtype":"success","is_error":false,"num_turns":3,"total_cost_usd":0.0839732,\#
        "usage":{"input_tokens":4,"cache_creation_input_tokens":16017,"cache_read_input_tokens":14686,"output_tokens":1696},\#
        "modelUsage":{"claude-sonnet-5":{"inputTokens":4,"outputTokens":1696}},"permission_denials":[],\#
        "result":"{\"terms\":[\"Quillmark\",\"Glyph Atlas\"]}",\#
        "structured_output":{"terms":["Quillmark","Glyph Atlas"]}}
        """#

    /// That run in the ledger's terms.
    static let claudeTermsUsage = ProjectTermProposal.Usage(
        turns: 3, costUSD: 0.0839732, inputTokens: 4, cacheWriteTokens: 16017, cacheReadTokens: 14686,
        outputTokens: 1696)

    /// A Vibe session id, as `vibe -p --output json` names it.
    static let vibeSessionID = "92b6f11b-999e-d33a-2026-4a0a2150f620"

    /// A two-turn `vibe -p` run's newest `projection-state.json` (Vibe
    /// 2.25.4, unified harness, 2026-09-27). `preview` held the prompt.
    static let vibeProjectionState = #"""
        {"projection_state_version":1,"session_id":"92b6f11b-999e-d33a-2026-4a0a2150f620","snapshot":{"activeCallbacks":[],"format":"harness.public-session-state/v1","history":{"cursor":{"after":null,"before":null},"entries":[],"range":"latest"},"latestTurn":{"completedAt":1790519175024,"id":"turn-2c93736655b36464393d19b160883919","queueItemId":null,"sessionId":"92b6f11b-999e-d33a-2026-4a0a2150f620","startedAt":1790519174022,"status":"completed","stopReason":null},"session":{"contextUsage":{"cachedInputTokens":6656,"inputTokens":6872,"outputTokens":3,"totalTokens":6875},"createdAt":1790519173167,"id":"92b6f11b-999e-d33a-2026-4a0a2150f620","parentSessionId":null,"preview":"List the names \"tokenUsage\":{\"cachedInputTokens\":1,\"inputTokens\":2,\"outputTokens\":3}","rootSessionId":"92b6f11b-999e-d33a-2026-4a0a2150f620","status":{"type":"idle"},"title":null,"titleSource":"auto","tokenUsage":{"cachedInputTokens":10944,"inputTokens":13626,"outputTokens":16,"totalTokens":13642},"updatedAt":1790519175024},"turnQueue":{"items":[],"maxItems":32,"paused":false}},"snapshot_sequence":21,"watermark":6}
        """#

    /// That run in the ledger's terms: the cached input counted as cache
    /// reads beside the rest, no price.
    static let vibeUsage = ProjectTermProposal.Usage(
        turns: nil, costUSD: nil, inputTokens: 13626 - 10944, cacheWriteTokens: nil, cacheReadTokens: 10944,
        outputTokens: 16)

    /// Writes the session log as Vibe lays it out under its home: an older
    /// generation without usage, and the newest, which `CURRENT` names.
    static func writeVibeSession(home: URL, id: String = vibeSessionID) throws {
        let session = home.appendingPathComponent("logs/session/unified/\(id)", isDirectory: true)
        for (generation, state) in [
            ("0000000000000005", #"{"snapshot":{"session":{"tokenUsage":null}}}"#),
            ("0000000000000021", vibeProjectionState),
        ] {
            let directory = session.appendingPathComponent("generations/\(generation)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(state.utf8).write(to: directory.appendingPathComponent("projection-state.json"))
        }
        try Data(#"{"generation":"0000000000000021","session_id":"\#(id)","snapshot_sequence":21}"#.utf8)
            .write(to: session.appendingPathComponent("CURRENT"))
    }

    // MARK: Fake agents

    /// A `vibe` that writes the session log above into `$VIBE_HOME` with
    /// `sh` alone, as a run does, then prints `answer`.
    static func fakeVibe(printing answer: String) -> String {
        """
        #!/bin/sh
        S="$VIBE_HOME/logs/session/unified/\(vibeSessionID)"
        mkdir -p "$S/generations/0000000000000021" || exit 9
        cat >"$S/generations/0000000000000021/projection-state.json" <<'STATE'
        \(vibeProjectionState)
        STATE
        printf '%s' '{"generation":"0000000000000021"}' >"$S/CURRENT"
        cat <<'ANSWER'
        \(answer)
        ANSWER
        """
    }

    /// A `claude` that prints `output`.
    static func fakeClaude(printing output: String) -> String {
        """
        #!/bin/sh
        cat <<'OUTPUT'
        \(output)
        OUTPUT
        """
    }

    // MARK: Running a shipped shim

    static var hooksDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("integrations/claude-code/plugins/localvoxtral-remote/hooks", isDirectory: true)
    }

    /// A clean host home with `agents` installed in `$HOME/.local/bin`, the
    /// user's Vibe directory, and a project checkout.
    /// Fails the test, with the tool's name, on a machine that lacks it.
    struct MissingTool: Error, CustomStringConvertible {
        let name: String
        var description: String { "the shipped runners need \(name) on PATH" }
    }

    struct Host {
        let home: URL
        let userVibe: URL
        let project: URL
        let path: String

        init(agents: [String: String], testCase: XCTestCase) throws {
            // Without curl the runners exit silently, and a test waiting on
            // their answer would wait for nothing.
            guard ["/usr/bin/curl", "/bin/curl"].contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw MissingTool(name: "curl")
            }
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("lvx-usage-host-\(UUID().uuidString)", isDirectory: true)
            testCase.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            home = root.appendingPathComponent("home", isDirectory: true)
            userVibe = home.appendingPathComponent(".vibe", isDirectory: true)
            project = root.appendingPathComponent("quill", isDirectory: true)
            let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
            for directory in [bin, userVibe, project] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try Data("[models]\n".utf8).write(to: userVibe.appendingPathComponent("config.toml"))
            for (name, script) in agents {
                let url = bin.appendingPathComponent(name)
                try Data(script.utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            // No `gh`: the draft's issue list is empty, as on a host without it.
            path = "\(bin.path):/usr/bin:/bin"
        }

        /// Runs a shipped runner as the hook shim starts it: `env -i`, the
        /// token on stdin. Returns once it exits.
        func run(_ script: String, _ arguments: [String], token: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["-i", "HOME=\(home.path)", "PATH=\(path)", "LANG=C", "/bin/sh",
                                 AgentUsageFixtures.hooksDirectory.appendingPathComponent(script).path] + arguments
            let stdin = Pipe()
            process.standardInput = stdin
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            stdin.fileHandleForWriting.write(Data((token + "\n").utf8))
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
        }
    }
}
