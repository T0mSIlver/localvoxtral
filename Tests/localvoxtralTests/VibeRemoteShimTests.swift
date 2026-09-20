import ClaudeContextWire
import Foundation
import XCTest

@testable import localvoxtral

/// Runs the REAL remote Vibe shim (`integrations/vibe/remote/post.sh` and
/// `compact.py`) with a stub `curl` on PATH, and reads what it handed curl back
/// through the app's own request parsers — the two sides of the contract
/// meeting on bytes the shim produced.
final class VibeRemoteShimTests: XCTestCase {
    private static let token = "dGVzdC10b2tlbi0xMjM0NTY3ODkwYWJjZGVm"
    private var root: URL!

    private var remoteDir: URL { root.appendingPathComponent("remote") }
    private var captureDir: URL { root.appendingPathComponent("capture") }
    private var stubDir: URL { root.appendingPathComponent("bin") }
    private var transcript: URL { root.appendingPathComponent("session/messages.jsonl") }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vibe-remote-\(UUID().uuidString)")
        for directory in [remoteDir, captureDir, stubDir, transcript.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let source = Self.repositoryRoot.appendingPathComponent("integrations/vibe/remote")
        for name in ["post.sh", "compact.py"] {
            try FileManager.default.copyItem(
                at: source.appendingPathComponent(name), to: remoteDir.appendingPathComponent(name)
            )
        }
        try Data((Self.token + "\n").utf8).write(to: remoteDir.appendingPathComponent("token"))
        try Data("18473\n".utf8).write(to: remoteDir.appendingPathComponent("port"))
        try Data("""
        {"role": "user", "content": "first prompt", "injected": false}
        {"role": "assistant", "content": "ASSISTANT-SECRET", "injected": false}
        {"role": "user", "content": "rename the wire enum", "injected": false}
        {"role": "tool", "content": "TOOL-SECRET", "injected": false}

        """.utf8).write(to: transcript)

        // One numbered capture per invocation: argv, the header file, the body.
        let stub = """
        #!/bin/sh
        n=$(($(ls "$FAKE_CURL_DIR" | grep -c '^argv-') + 1))
        printf '%s\\n' "$@" >"$FAKE_CURL_DIR/argv-$n"
        env >"$FAKE_CURL_DIR/env-$n"
        while [ "$#" -gt 0 ]; do
          case "$1" in
          --header) case "$2" in @*) cp "${2#@}" "$FAKE_CURL_DIR/header-$n" ;; esac; shift ;;
          --data-binary) cp "${2#@}" "$FAKE_CURL_DIR/body-$n"; shift ;;
          esac
          shift
        done
        printf '%s' "${FAKE_CURL_STATUS:-200}"
        exit "${FAKE_CURL_EXIT:-0}"

        """
        let curl = stubDir.appendingPathComponent("curl")
        try Data(stub.utf8).write(to: curl)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Harness

    private func payload(
        event: String,
        parent: String = "null",
        extra: String = ""
    ) -> Data {
        Data("""
        {"session_id":"7f4aefdf","transcript_path":"\(transcript.path)","cwd":"/srv/app",\
        "parent_session_id":\(parent),"hook_event_name":"\(event)"\(extra)}
        """.utf8)
    }

    private struct Run {
        var exitCode: Int32
        var output: Data
    }

    private func runShim(_ payload: Data, environment extra: [String: String] = [:]) throws -> Run {
        let input = root.appendingPathComponent("stdin-\(UUID().uuidString)")
        let output = root.appendingPathComponent("out-\(UUID().uuidString)")
        try payload.write(to: input)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        var environment = [
            "HOME": root.path,
            "PATH": "\(stubDir.path):/usr/bin:/bin",
            "XDG_RUNTIME_DIR": root.appendingPathComponent("run").path,
            "LOCALVOXTRAL_VIBE_REMOTE_DIR": remoteDir.path,
            "FAKE_CURL_DIR": captureDir.path,
            // Off unless a test is about it: the watcher outlives the hook by
            // design, and here it would wait on the test runner itself.
            "LOCALVOXTRAL_VIBE_WATCHER": "off",
        ]
        environment.merge(extra) { $1 }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [remoteDir.appendingPathComponent("post.sh").path]
        process.environment = environment
        process.standardInput = try FileHandle(forReadingFrom: input)
        let sink = try FileHandle(forWritingTo: output)
        process.standardOutput = sink
        process.standardError = sink
        try process.run()
        process.waitUntilExit()
        try sink.close()
        return Run(exitCode: process.terminationStatus, output: try Data(contentsOf: output))
    }

    private var dialCount: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: captureDir.path)) ?? [])
            .filter { $0.hasPrefix("argv-") }.count
    }

    private func captured(_ kind: String, _ index: Int) throws -> String {
        try String(contentsOf: captureDir.appendingPathComponent("\(kind)-\(index)"), encoding: .utf8)
    }

    /// The header file curl was handed, through the listener's own parser.
    private func request(_ index: Int) throws -> ClaudeRemoteHTTPRequest {
        var head = "POST /v1/hook/Stop HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        for line in try captured("header", index).split(separator: "\n") { head += line + "\r\n" }
        head += "Content-Length: 2\r\n\r\n{}"
        return try ClaudeRemoteHTTPCodec.parseRequestHead(Data(head.utf8)).request
    }

    private func parsedBody(_ index: Int, event: String) throws -> ClaudeRemoteHookPayloadParser.Payload {
        try XCTUnwrap(ClaudeRemoteHookPayloadParser.parse(
            data: Data(try captured("body", index).utf8), fallbackEvent: event, timestamp: 1
        ))
    }

    // MARK: - What is sent

    func testATurnEndSendsThePromptThenStopAsVibe() throws {
        let run = try runShim(payload(event: "post_agent"))
        XCTAssertEqual(run.exitCode, 0)
        XCTAssertEqual(run.output, Data(), "Vibe shows any hook output as a failure")
        XCTAssertEqual(dialCount, 2)

        XCTAssertTrue(try captured("argv", 1).hasSuffix("http://127.0.0.1:18473/v1/hook/UserPromptSubmit\n"))
        XCTAssertTrue(try captured("argv", 2).hasSuffix("http://127.0.0.1:18473/v1/hook/Stop\n"))
        XCTAssertEqual(try parsedBody(1, event: "UserPromptSubmit").record.prompt, "rename the wire enum")
        XCTAssertEqual(try parsedBody(2, event: "Stop").record.event, .stop)

        for index in 1...2 {
            let request = try request(index)
            XCTAssertEqual(ClaudeRemoteAgentCodec.agent(in: request.headers), .vibe)
            XCTAssertEqual(request.headers["authorization"], "Bearer \(Self.token)")
            XCTAssertEqual(request.headers["x-lvx-vibe-hooks-version"], "1.0.0")
        }
    }

    func testAFileReadSendsThePathAndAShortExcerptNeverTheFile() throws {
        let big = String(repeating: "x", count: 300_000)
        let extra = #","tool_name":"read_file","tool_input":{"file_path":"src/../note.txt","limit":2000},"#
            + #""tool_output":{"file_path":"/srv/app/note.txt","content":"\#(big)"},"tool_output_text":"\#(big)""#
        let run = try runShim(payload(event: "post_tool", extra: extra))
        XCTAssertEqual(run.exitCode, 0)
        XCTAssertEqual(run.output, Data())
        XCTAssertEqual(dialCount, 2)

        let body = try captured("body", 2)
        XCTAssertLessThan(body.utf8.count, 4096, "a 300 KB payload must not cross the tunnel")
        XCTAssertFalse(body.contains("tool_output_text"))
        let parsed = try parsedBody(2, event: "PostToolUse")
        XCTAssertEqual(parsed.record.files, [ClaudeFileTouch(path: "/srv/app/note.txt", kind: .read)])
        XCTAssertEqual(parsed.snippets.map(\.kind), [.toolOutput])
    }

    func testAnEditIsAnEditAndCarriesItsStrings() throws {
        let extra = #","tool_name":"edit","tool_input":{"file_path":"/srv/app/a.swift","old_string":"case a","new_string":"case b"}"#
        _ = try runShim(payload(event: "post_tool", extra: extra))
        let parsed = try parsedBody(2, event: "PostToolUse")
        XCTAssertEqual(parsed.record.files, [ClaudeFileTouch(path: "/srv/app/a.swift", kind: .edited)])
        XCTAssertEqual(Set(parsed.snippets.map(\.text)), ["case a", "case b"])
    }

    func testNothingFromTheSessionLogButTheLastUserMessageIsSent() throws {
        _ = try runShim(payload(event: "post_agent"))
        for index in 1...2 {
            let body = try captured("body", index)
            XCTAssertFalse(body.contains("SECRET"), body)
            XCTAssertFalse(body.contains("first prompt"), body)
            XCTAssertFalse(body.contains("messages.jsonl"), body)
        }
    }

    func testSubagentsOtherToolsAndUnknownEventsSendNothing() throws {
        _ = try runShim(payload(event: "post_agent", parent: #""parent-1""#))
        _ = try runShim(payload(event: "pre_tool"))
        _ = try runShim(Data(#"{"session_id":"s","cwd":"/r","hook_event_name":"post_agent"}"#.utf8))
        _ = try runShim(Data("not json".utf8))
        XCTAssertEqual(dialCount, 0)

        // A shell command is not a file touch; the prompt still goes.
        let bash = #","tool_name":"bash","tool_input":{"command":"cat /etc/passwd","file_path":"/etc/passwd"}"#
        _ = try runShim(payload(event: "post_tool", extra: bash))
        XCTAssertEqual(dialCount, 1)
        XCTAssertFalse(try captured("body", 1).contains("passwd"))
    }

    // MARK: - Labels

    func testEnvironmentLabelsArriveUnderTheHeadersTheListenerReads() throws {
        _ = try runShim(payload(event: "post_agent"), environment: [
            "HERDR_PANE_ID": "w1:p2",
            "SSH_TTY": "/dev/pts/4",
            "LC_LVX_TTY": "/dev/ttys012",
            "SSH_CONNECTION": "10.0.0.2 50000 10.0.0.9 22",
            "TMUX": "/tmp/tmux-501/default,1,0",
        ])
        let environment = try XCTUnwrap(
            ClaudeRemoteEnvironmentCodec.environment(in: try request(1).headers, limits: .default)
        )
        XCTAssertEqual(environment.herdrPaneID, "w1:p2")
        XCTAssertEqual(environment.sshTTY, "/dev/pts/4")
        XCTAssertEqual(environment.localTTY, "/dev/ttys012")
        XCTAssertEqual(environment.sshConnection, "10.0.0.2,50000,10.0.0.9,22")
        XCTAssertNotNil(environment.tmux)
        let parent = try XCTUnwrap(environment.hookParentPID)
        XCTAssertTrue(parent.allSatisfy(\.isNumber))
    }

    func testClaudeAllocatedSessionHandlesAreNeverSent() throws {
        _ = try runShim(payload(event: "post_agent"), environment: [
            "CLAUDE_CODE_BRIDGE_SESSION_ID": "session_inherited",
            "CLAUDE_CODE_HOST_SESSION_ID": "local_inherited",
        ])
        let header = try captured("header", 1)
        XCTAssertFalse(header.contains("inherited"), header)
    }

    func testAHostileLabelCannotForgeAHeaderLine() throws {
        _ = try runShim(payload(event: "post_agent"), environment: [
            "HERDR_PANE_ID": "p1\r\nX-Lvx-Agent: claude",
            "SSH_TTY": "/dev/pts/4 X-Injected: 1",
        ])
        let request = try request(1)
        XCTAssertEqual(ClaudeRemoteAgentCodec.agent(in: request.headers), .vibe)
        XCTAssertNil(request.headers["x-injected"])
        XCTAssertNil(request.headers["x-lvx-env-herdr-pane-id"])
    }

    // MARK: - The token

    func testTheTokenReachesCurlThroughTheHeaderFileAndNoArgv() throws {
        _ = try runShim(payload(event: "post_agent"))
        for index in 1...2 {
            XCTAssertFalse(try captured("argv", index).contains(Self.token))
            XCTAssertTrue(try captured("argv", index).contains("--header\n@"))
        }
        let code = try String(contentsOf: remoteDir.appendingPathComponent("post.sh"), encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("export TOKEN"), "compact.py must never inherit it")
        XCTAssertFalse(code.contains("printf"), "an external printf would put the token in an argv")
        XCTAssertFalse(code.contains("echo \"$TOKEN"), "same for an external echo")
    }

    func testAnInheritedExportedTOKENNeverReachesAChildsEnvironment() throws {
        // A shell exports what it imported from its environment. Vibe started
        // with TOKEN exported must not make curl (or compact.py) inherit the
        // host's bearer token through that name.
        _ = try runShim(payload(event: "post_agent"), environment: ["TOKEN": "inherited-and-exported"])
        XCTAssertEqual(dialCount, 2)
        for index in 1...2 {
            let environment = try captured("env", index)
            XCTAssertFalse(environment.contains(Self.token), "the token is in curl's environment")
            XCTAssertFalse(environment.contains("TOKEN="), environment)
        }
    }

    func testAMissingOrDamagedTokenSendsNothingAndSaysNothing() throws {
        for damaged in [nil, "", "has space", "line1\r\nX-Lvx-Agent: claude", String(repeating: "a", count: 200)] {
            let file = remoteDir.appendingPathComponent("token")
            try? FileManager.default.removeItem(at: file)
            if let damaged { try Data(damaged.utf8).write(to: file) }
            let run = try runShim(payload(event: "post_agent"))
            XCTAssertEqual(run.exitCode, 0)
            XCTAssertEqual(run.output, Data())
        }
        XCTAssertEqual(dialCount, 0)
    }

    func testABadPortFallsBackToTheDefaultAndNeverReachesTheURL() throws {
        try Data("80; rm -rf /\n".utf8).write(to: remoteDir.appendingPathComponent("port"))
        _ = try runShim(payload(event: "post_agent"))
        XCTAssertTrue(try captured("argv", 1).hasSuffix("http://127.0.0.1:8473/v1/hook/UserPromptSubmit\n"))
    }

    // MARK: - Failing open

    func testADeadTunnelBacksOffFileHooksButATurnEndStillDials() throws {
        let tool = #","tool_name":"read_file","tool_input":{"file_path":"/srv/app/a"}"#
        let dead = ["FAKE_CURL_STATUS": "000", "FAKE_CURL_EXIT": "7"]

        let first = try runShim(payload(event: "post_tool", extra: tool), environment: dead)
        XCTAssertEqual(first.exitCode, 0)
        XCTAssertEqual(first.output, Data())
        XCTAssertEqual(dialCount, 1, "the first failure stops the run: no second dial")

        _ = try runShim(payload(event: "post_tool", extra: tool), environment: dead)
        XCTAssertEqual(dialCount, 1, "backed off")

        _ = try runShim(payload(event: "post_agent"))
        XCTAssertEqual(dialCount, 3, "a turn end always dials, and its success clears the backoff")

        _ = try runShim(payload(event: "post_tool", extra: tool))
        XCTAssertEqual(dialCount, 5)
    }

    func testNoPythonAndNoCurlAreSilentSuccesses() throws {
        // PATH without the stub curl, python3 or vibe: nothing to run.
        let empty = root.appendingPathComponent("empty-bin")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        for name in ["cat", "date", "mktemp", "rm", "awk"] {
            let real = ["/bin/\(name)", "/usr/bin/\(name)"].first { FileManager.default.isExecutableFile(atPath: $0) }
            try FileManager.default.createSymbolicLink(
                atPath: empty.appendingPathComponent(name).path, withDestinationPath: try XCTUnwrap(real)
            )
        }
        let run = try runShim(payload(event: "post_agent"), environment: ["PATH": empty.path])
        XCTAssertEqual(run.exitCode, 0)
        XCTAssertEqual(run.output, Data())
        XCTAssertEqual(dialCount, 0)
    }

    // MARK: - The exit watcher

    func testWhenVibeExitsTheWatcherTellsTheMacTheSessionEnded() throws {
        // A fake Vibe built the way the real one runs hooks: a Python process
        // that starts the hook in a NEW SESSION and then exits. The watcher is
        // a real background process, so there is no clock to inject: the
        // driver below starts the fake Vibe, and then waits (bounded) for the
        // third request to be captured. This test only waits for the driver.
        let payloadFile = root.appendingPathComponent("payload.json")
        try payload(event: "post_agent").write(to: payloadFile)
        let driver = """
        import os, subprocess, sys, time
        shim, payload, capture = sys.argv[1:4]
        fake_vibe = "import subprocess, sys; subprocess.run(['/bin/sh', sys.argv[1]], stdin=open(sys.argv[2], 'rb'), start_new_session=True)"
        subprocess.run([sys.executable, "-c", fake_vibe, shim, payload], check=True)
        for _ in range(400):
            if os.path.exists(os.path.join(capture, "body-3")):
                sys.exit(0)
            time.sleep(0.05)
        sys.exit(3)
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c", driver, remoteDir.appendingPathComponent("post.sh").path, payloadFile.path, captureDir.path,
        ]
        process.environment = [
            "HOME": root.path,
            "PATH": "\(stubDir.path):/usr/bin:/bin",
            "XDG_RUNTIME_DIR": root.appendingPathComponent("run").path,
            "LOCALVOXTRAL_VIBE_REMOTE_DIR": remoteDir.path,
            "FAKE_CURL_DIR": captureDir.path,
            "LOCALVOXTRAL_VIBE_WATCH_INTERVAL": "0.1",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "3 means no SessionEnd within 20 s of Vibe exiting")

        XCTAssertTrue(try captured("argv", 3).hasSuffix("http://127.0.0.1:18473/v1/hook/SessionEnd\n"))
        XCTAssertEqual(
            try captured("body", 3), #"{"hook_event_name":"SessionEnd","session_id":"7f4aefdf"}"# + "\n"
        )
        XCTAssertEqual(ClaudeRemoteAgentCodec.agent(in: try request(3).headers), .vibe)
        XCTAssertFalse(try captured("argv", 3).contains(Self.token))
    }

    func testTheWatcherIsOnePerSessionAndCanBeTurnedOff() throws {
        let source = try String(contentsOf: remoteDir.appendingPathComponent("post.sh"), encoding: .utf8)
        XCTAssertTrue(source.contains(#"mkdir "$LOCK" 2>/dev/null || exit 0"#), "the lock is the atomic mkdir")
        XCTAssertTrue(source.contains(") </dev/null >/dev/null 2>&1 &"), "Vibe waits for the hook's pipes to close")

        _ = try runShim(payload(event: "post_agent")) // harness default: off
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("run/localvoxtral/vibe-watch").path
        ))
    }

    // MARK: - The hooks block

    func testTheRemoteBlockCannotCollideWithTheLocalOne() throws {
        let source = Self.repositoryRoot.appendingPathComponent("integrations/vibe")
        let local = try String(contentsOf: source.appendingPathComponent("hooks.toml"), encoding: .utf8)
        let remote = try String(contentsOf: source.appendingPathComponent("remote/hooks.toml"), encoding: .utf8)
        func names(_ text: String) -> Set<String> {
            Set(text.split(separator: "\n").filter { $0.hasPrefix("name = ") }.map(String.init))
        }
        XCTAssertEqual(names(remote).count, 2)
        XCTAssertTrue(names(local).isDisjoint(with: names(remote)), "Vibe deduplicates hooks by name")
        XCTAssertTrue(remote.hasPrefix("# >>> localvoxtral remote >>>\n"))
        XCTAssertTrue(remote.hasSuffix("# <<< localvoxtral remote <<<\n"))
        XCTAssertFalse(VibeHooksInstallService.block.containsBlock(remote), "one machine can hold both blocks")
        XCTAssertFalse(remote.contains("strict = true"))
        for line in remote.split(separator: "\n") where line.hasPrefix("command = ") {
            XCTAssertTrue(line.hasSuffix(#"2>/dev/null || :""#), String(line))
        }
    }
}
