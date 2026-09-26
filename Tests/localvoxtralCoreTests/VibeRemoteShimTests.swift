import ClaudeContextWire
import Foundation
import XCTest

@testable import localvoxtralCore
import localvoxtralTestSupport

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `python3` for these tests: a link, under the name the shim's fallback looks
/// for, to the interpreter `/usr/bin/python3` itself runs. On macOS that path
/// is an `xcrun` trampoline, and under the stripped environment the shim runs
/// in (no `TMPDIR`, a temporary `HOME`) it was most of each hook's cost on the
/// build host. The shim still finds the interpreter through its `command -v
/// python3` fallback, under the same name check.
enum VibeTestPython {
    static let directory: URL = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-python-\(UUID().uuidString)")
        atexit { try? FileManager.default.removeItem(at: VibeTestPython.directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent("python3").path, withDestinationPath: resolved()
        )
        return directory
    }()

    static var executable: URL { directory.appendingPathComponent("python3") }

    /// The interpreter behind `/usr/bin/python3`, or that path when it will not say.
    private static func resolved() -> String {
        let fallback = "/usr/bin/python3"
        let answer = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-python-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: answer) }
        guard FileManager.default.createFile(atPath: answer.path, contents: nil),
              let sink = try? FileHandle(forWritingTo: answer) else { return fallback }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: fallback)
        process.arguments = ["-c", "import sys; print(sys.executable)"]
        process.standardOutput = sink
        process.standardError = FileHandle.nullDevice
        guard (try? process.runUntilExit()) != nil, process.terminationStatus == 0 else { return fallback }
        try? sink.close()
        let path = ((try? String(contentsOf: answer, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : fallback
    }
}

/// Runs the REAL remote Vibe shim (`integrations/vibe/remote/post.sh` and
/// `compact.py`) with a stub `curl` on PATH, and reads what it handed curl back
/// through the app's own request parsers — the two sides of the contract
/// meeting on bytes the shim produced.
final class VibeRemoteShimTests: XCTestCase {
    private static let token = "dGVzdC10b2tlbi0xMjM0NTY3ODkwYWJjZGVm"
    private var root: URL!

    private var remoteDir: URL { root.appendingPathComponent("remote") }
    private var captureDir: URL { root.appendingPathComponent("capture") }
    private var stubDir: URL { Self.sharedStubDir }
    private var transcript: URL { root.appendingPathComponent("session/messages.jsonl") }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The stub `curl`, written once for the class: everything that varies per
    /// call reaches it through the environment. Executing a script the system
    /// has not seen before cost 170–260 ms on the build host against 23 ms for
    /// one it has, and every test here used to write its own.
    private static let sharedStubDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("vibe-remote-stub-\(UUID().uuidString)")

    private static func writeStubCurlOnce() throws {
        let curl = sharedStubDir.appendingPathComponent("curl")
        guard !FileManager.default.fileExists(atPath: curl.path) else { return }
        // One numbered capture per invocation: argv, the header file, the body.
        //
        // Everything here that can be a shell builtin is one: the suite runs
        // the REAL shim, which already spends ~15 process spawns per hook
        // (`ps -ax` in compact.py among them), and a stub that added `ls`,
        // `grep` and `env` to each of the two dials per run made the test
        // harness a measurable share of the suite. The invocation counter is a
        // probe loop rather than `ls | grep -c`, and the environment dump is
        // written only for the one case that reads it.
        let stub = """
        #!/bin/sh
        n=1
        while [ -e "$FAKE_CURL_DIR/argv-$n" ]; do n=$((n + 1)); done
        printf '%s\\n' "$@" >"$FAKE_CURL_DIR/argv-$n"
        [ -n "${FAKE_CURL_DUMP_ENV:-}" ] && env >"$FAKE_CURL_DIR/env-$n"
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
        try FileManager.default.createDirectory(at: sharedStubDir, withIntermediateDirectories: true)
        try Data(stub.utf8).write(to: curl)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: sharedStubDir)
        super.tearDown()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try Self.writeStubCurlOnce()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vibe-remote-\(UUID().uuidString)")
        for directory in [remoteDir, captureDir, transcript.deletingLastPathComponent()] {
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
        var environment = [
            "HOME": root.path,
            "PATH": "\(stubDir.path):\(VibeTestPython.directory.path):/usr/bin:/bin",
            "XDG_RUNTIME_DIR": root.appendingPathComponent("run").path,
            "LOCALVOXTRAL_VIBE_REMOTE_DIR": remoteDir.path,
            "FAKE_CURL_DIR": captureDir.path,
            // Off unless a test is about it: the watcher outlives the hook by
            // design, and here it would wait on the test runner itself.
            "LOCALVOXTRAL_VIBE_WATCHER": "off",
        ]
        environment.merge(extra) { $1 }

        // Not `Process`: on Linux it would also wait for the exit watcher the
        // shim leaves running (`SpawnAndWait`).
        let exitCode = try SpawnAndWait.run(
            "/bin/sh",
            arguments: [remoteDir.appendingPathComponent("post.sh").path],
            environment: environment,
            standardInput: input.path,
            output: output.path
        )
        return Run(exitCode: exitCode, output: try Data(contentsOf: output))
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
            XCTAssertEqual(request.headers["x-lvx-vibe-hooks-version"], "1.1.0")
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
        _ = try runShim(payload(event: "post_agent"), environment: [
            "TOKEN": "inherited-and-exported", "FAKE_CURL_DUMP_ENV": "1",
        ])
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
        process.executableURL = VibeTestPython.executable
        process.arguments = [
            "-c", driver, remoteDir.appendingPathComponent("post.sh").path, payloadFile.path, captureDir.path,
        ]
        process.environment = [
            "HOME": root.path,
            "PATH": "\(stubDir.path):\(VibeTestPython.directory.path):/usr/bin:/bin",
            "XDG_RUNTIME_DIR": root.appendingPathComponent("run").path,
            "LOCALVOXTRAL_VIBE_REMOTE_DIR": remoteDir.path,
            "FAKE_CURL_DIR": captureDir.path,
            "LOCALVOXTRAL_VIBE_WATCH_INTERVAL": "0.1",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.runUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "3 means no SessionEnd within 20 s of Vibe exiting")

        XCTAssertTrue(try captured("argv", 3).hasSuffix("http://127.0.0.1:18473/v1/hook/SessionEnd\n"))
        XCTAssertEqual(
            try captured("body", 3), #"{"hook_event_name":"SessionEnd","session_id":"7f4aefdf"}"# + "\n"
        )
        XCTAssertEqual(ClaudeRemoteAgentCodec.agent(in: try request(3).headers), .vibe)
        XCTAssertFalse(try captured("argv", 3).contains(Self.token))
    }

    /// Runs `driver` (Python) with the watcher on, and returns its exit code.
    private func runWatcherDriver(
        _ driver: String, extraPath: String? = nil, arguments: [String] = []
    ) throws -> Int32 {
        let payloadFile = root.appendingPathComponent("payload.json")
        try payload(event: "post_agent").write(to: payloadFile)
        let process = Process()
        process.executableURL = VibeTestPython.executable
        process.arguments = [
            "-c", driver, remoteDir.appendingPathComponent("post.sh").path, payloadFile.path, captureDir.path,
        ] + arguments
        process.environment = [
            "HOME": root.path,
            "PATH": "\(extraPath.map { $0 + ":" } ?? "")\(stubDir.path):\(VibeTestPython.directory.path):/usr/bin:/bin",
            "XDG_RUNTIME_DIR": root.appendingPathComponent("run").path,
            "LOCALVOXTRAL_VIBE_REMOTE_DIR": remoteDir.path,
            "FAKE_CURL_DIR": captureDir.path,
            "LOCALVOXTRAL_VIBE_WATCH_INTERVAL": "0.1",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.runUntilExit()
        return process.terminationStatus
    }

    func testAVibeThatIsAlreadyGoneGetsItsSessionEndAtOnce() throws {
        // The hook outlives its Vibe: Ctrl-C at the end of a turn, a closed
        // pane. The Vibe has to die in a window — after compact.py has read it
        // out of the process table, before the watcher asks `ps` whether it is
        // alive — and a sleep cannot hold a window open on a loaded host. A
        // FIFO does: the stub curl below waits on it before the hook's first
        // request, which is already past compact.py, and the driver opens the
        // writing end, kills and REAPS the Vibe, and only then lets the hook
        // run on. Nothing here is timed; the order is the handshake.
        let gate = root.appendingPathComponent("vibe-reaped")
        XCTAssertEqual(mkfifo(gate.path, 0o600), 0, String(cString: strerror(errno)))
        let held = root.appendingPathComponent("held")
        try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
        let wrapper = """
        #!\(VibeTestPython.executable.path)
        import os, select, sys
        if not os.path.exists("\(held.path)/passed"):
            open("\(held.path)/passed", "w").close()
            # O_NONBLOCK, so that opening the reading end never blocks: a
            # driver that has already given up must not leave this process,
            # and the hook waiting on it, here for good. Both are orphans by
            # then, and neither the test's own cleanup nor unlinking the FIFO
            # can free a process asleep in open(). The wait itself ends on the
            # driver's write, or on the EOF its exit sends, and the cap is the
            # driver's own deadline so that neither outlives the other by long.
            gate = os.open("\(gate.path)", os.O_RDONLY | os.O_NONBLOCK)
            select.select([gate], [], [], 60)
            os.close(gate)
        os.execv("\(stubDir.path)/curl", ["\(stubDir.path)/curl"] + sys.argv[1:])

        """
        try Data(wrapper.utf8).write(to: held.appendingPathComponent("curl"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: held.path + "/curl")

        let driver = """
        import os, subprocess, sys, threading, time
        shim, payload, capture, gate = sys.argv[1:5]
        # A Vibe that lives until it is killed, so `$PPID` and compact.py's
        # process table name the real process on every host.
        fake_vibe = ("import subprocess, sys, time;"
                     " subprocess.Popen(['/bin/sh', sys.argv[1]], stdin=open(sys.argv[2], 'rb'),"
                     " start_new_session=True); time.sleep(600)")
        vibe = subprocess.Popen([sys.executable, "-c", fake_vibe, shim, payload])
        with open(os.path.join(capture, "vibe-pid-0"), "w") as handle:
            handle.write(str(vibe.pid))
        # Opening the writing end returns when the hook opens the reading one,
        # inside its first request. A deadline, because a hook that never gets
        # there must fail the test rather than hang the suite.
        opened = []
        thread = threading.Thread(target=lambda: opened.append(open(gate, "w")), daemon=True)
        thread.start()
        thread.join(60)
        if not opened:
            vibe.kill()
            vibe.wait()
            sys.exit(4)
        vibe.kill()
        vibe.wait()  # gone AND reaped: `ps -o lstart=` has no answer for it now
        opened[0].write("go\\n")
        opened[0].close()
        # The SessionEnd is owed from here on. Only the watcher's own request
        # is still in flight, which is another process, so it is watched for.
        for _ in range(400):
            if os.path.exists(os.path.join(capture, "body-3")):
                sys.exit(0)
            time.sleep(0.05)
        # Which silence this is: a shim that named no Vibe never armed a
        # watcher at all, which is a different bug from one that stayed quiet.
        try:
            with open(os.path.join(capture, "header-1")) as handle:
                named = "X-Lvx-Env-Hook-Parent-Pid" in handle.read()
        except OSError:
            named = False
        sys.exit(3 if named else 5)
        """
        XCTAssertEqual(
            try runWatcherDriver(driver, extraPath: held.path, arguments: [gate.path]), 0,
            """
            3 means a watcher was armed and sent no SessionEnd, 4 means the hook \
            never reached its first request, 5 means compact.py named no Vibe \
            (its `ps -ax` runs under a 0.5 s timeout) so no watcher was armed
            """
        )
        XCTAssertTrue(try captured("argv", 3).hasSuffix("/v1/hook/SessionEnd\n"))
        // The watcher has to be the one the dead Vibe left behind. Named after
        // init instead, it would report the end of a session on every hook
        // whose wrapper died early, and this test would pass without ever
        // running the path it is about.
        XCTAssertEqual(
            try request(1).headers["x-lvx-env-hook-parent-pid"], try captured("vibe-pid", 0),
            "the SessionEnd must come from a watcher armed on the Vibe this test killed"
        )
    }

    // MARK: - Unified Harness payloads

    // As `_foreign_hooks.py` builds them in mistralai-vibe-local-harness 0.5.1:
    // no session id, no parent, no transcript path, group-qualified tools.

    func testAUnifiedTurnEndIsSentUnderAnIdNamedAfterTheVibeProcess() throws {
        let run = try runShim(Data(#"{"cwd":"/srv/app","hook_event_name":"post_agent"}"#.utf8))
        XCTAssertEqual(run.exitCode, 0)
        XCTAssertEqual(run.output, Data())
        XCTAssertEqual(dialCount, 1, "this runner names no session log, so there is no prompt record")

        let first = try parsedBody(1, event: "Stop").record
        XCTAssertEqual(first.event, .stop)
        XCTAssertNotNil(
            first.sessionID.range(of: "^process-[0-9]+-[A-Za-z0-9]+$", options: .regularExpression),
            first.sessionID
        )
        XCTAssertEqual(ClaudeRemoteAgentCodec.agent(in: try request(1).headers), .vibe)

        // The same process is the same session on its next hook.
        _ = try runShim(Data(#"{"cwd":"/srv/app","hook_event_name":"post_agent"}"#.utf8))
        XCTAssertEqual(try parsedBody(2, event: "Stop").record.sessionID, first.sessionID)
    }

    func testAUnifiedFileReadSendsThePathFromThePathArgument() throws {
        let run = try runShim(Data("""
        {"cwd":"/srv/app","hook_event_name":"post_tool","tool_name":"file_system.read_file",\
        "tool_call_id":"c1","tool_input":{"path":"src/main.py","offset":0},"tool_status":"success",\
        "tool_output":null,"tool_output_text":"whole file","tool_error":null,"duration_ms":0}
        """.utf8))
        XCTAssertEqual(run.exitCode, 0)
        XCTAssertEqual(dialCount, 1)
        XCTAssertFalse(try captured("body", 1).contains("whole file"), "the file never crosses")
        XCTAssertEqual(
            try parsedBody(1, event: "PostToolUse").record.files,
            [ClaudeFileTouch(path: "/srv/app/src/main.py", kind: .read)]
        )
    }

    func testAUnifiedPayloadWithoutAProcessTableSendsNothing() throws {
        // No pid means no id to publish under, and a guess could land one
        // pane's records on another's session.
        let broken = root.appendingPathComponent("broken-unified")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: broken.appendingPathComponent("ps"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.path + "/ps")
        let run = try runShim(Data(#"{"cwd":"/srv/app","hook_event_name":"post_agent"}"#.utf8), environment: [
            "PATH": "\(broken.path):\(stubDir.path):\(VibeTestPython.directory.path):/usr/bin:/bin",
        ])
        XCTAssertEqual(run.exitCode, 0)
        XCTAssertEqual(run.output, Data())
        XCTAssertEqual(dialCount, 0)
    }

    /// compact.py run directly, as post.sh runs it, with a chosen start pid.
    private func runCompactor(_ payload: String, startPID: Int32) throws -> URL {
        let work = root.appendingPathComponent("work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let input = work.appendingPathComponent("payload")
        try Data(payload.utf8).write(to: input)
        let process = Process()
        process.executableURL = VibeTestPython.executable
        process.arguments = ["-I", remoteDir.appendingPathComponent("compact.py").path, work.path, String(startPID)]
        process.standardInput = try FileHandle(forReadingFrom: input)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.runUntilExit()
        return work
    }

    func testAnOrphanedHookNeverNamesASessionAfterInit() throws {
        // A hook whose wrapper died before its shell read `$PPID` starts from
        // pid 1. Every such hook on the host would publish under that one
        // process, one session for every pane (GLM review, 2026-09-21).
        let unified = #"{"cwd":"/srv/app","hook_event_name":"post_agent"}"#
        let legacy = """
        {"session_id":"7f4aefdf","transcript_path":"\(transcript.path)","cwd":"/srv/app",\
        "parent_session_id":null,"hook_event_name":"post_agent"}
        """
        for start in [Int32(1)] {
            let work = try runCompactor(unified, startPID: start)
            XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("plan").path), "\(start)")

            // A payload with its own id is still sent: its watcher cannot
            // signal init, so it ends the session at once the same way a Vibe
            // that really died does in
            // testAVibeThatIsAlreadyGoneGetsItsSessionEndAtOnce — there on an
            // empty start time, here on a `kill -0` a non-root user loses.
            let named = try runCompactor(legacy, startPID: start)
            XCTAssertTrue(FileManager.default.fileExists(atPath: named.appendingPathComponent("plan").path), "\(start)")
        }
        // The control: started from a real process, the same payload is planned.
        let work = try runCompactor(unified, startPID: getpid())
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.appendingPathComponent("plan").path))
    }

    func testASessionIdWithoutTheParentFieldStillSendsNothing() throws {
        let run = try runShim(Data(#"{"session_id":"s","cwd":"/srv/app","hook_event_name":"post_agent"}"#.utf8))
        XCTAssertEqual(run.exitCode, 0)
        XCTAssertEqual(dialCount, 0)
    }

    func testWithoutAProcessTableNoPidIsPublishedAndNoWatcherStarts() throws {
        // No usable `ps`: the only pid left is the `sh -c` wrapper, and a
        // watcher on it would end a live session two seconds later.
        let broken = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: broken.appendingPathComponent("ps"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.path + "/ps")
        let run = try runShim(payload(event: "post_agent"), environment: [
            "PATH": "\(broken.path):\(stubDir.path):\(VibeTestPython.directory.path):/usr/bin:/bin",
            "LOCALVOXTRAL_VIBE_WATCHER": "on",
        ])
        XCTAssertEqual(run.exitCode, 0)
        XCTAssertEqual(dialCount, 2, "the records still go")
        XCTAssertNil(try request(1).headers["x-lvx-env-hook-parent-pid"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("run/localvoxtral/vibe-watch").path
        ))
    }

    func testAReusedSessionIdReplacesTheWatcherOfTheOldProcess() throws {
        // A lock held by a live watcher of ANOTHER agent pid: stand-ins are a
        // sleeping process as the old watcher and pid 1 as the old agent.
        let lock = root.appendingPathComponent("run/localvoxtral/vibe-watch/7f4aefdf")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        let oldWatcher = Process()
        oldWatcher.executableURL = URL(fileURLWithPath: "/bin/sleep")
        oldWatcher.arguments = ["600"]
        let oldWatcherExited = DispatchSemaphore(value: 0)
        oldWatcher.terminationHandler = { _ in oldWatcherExited.signal() }
        try oldWatcher.run()
        defer { if oldWatcher.isRunning { oldWatcher.terminate() } }
        try Data("\(oldWatcher.processIdentifier)\n".utf8).write(to: lock.appendingPathComponent("pid"))
        try Data("1\n".utf8).write(to: lock.appendingPathComponent("agent"))

        _ = try runShim(payload(event: "post_agent"), environment: ["LOCALVOXTRAL_VIBE_WATCHER": "on"])
        oldWatcherExited.wait()
        XCTAssertFalse(oldWatcher.isRunning, "its SessionEnd would have evicted the session that is live now")
        let agent = try String(contentsOf: lock.appendingPathComponent("agent"), encoding: .utf8)
        XCTAssertNotEqual(agent, "1\n", "the lock now names the process this hook belongs to")
        // Stop the watcher this test started, which is waiting on the runner.
        if let pid = Int32(try String(contentsOf: lock.appendingPathComponent("pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGTERM) }
    }

    func testTheWatcherIsOnePerSessionAndCanBeTurnedOff() throws {
        let source = try String(contentsOf: remoteDir.appendingPathComponent("post.sh"), encoding: .utf8)
        XCTAssertTrue(source.contains(#"mkdir "$LOCK" 2>/dev/null || exit 0"#), "the lock is the atomic mkdir")
        XCTAssertTrue(source.contains(") </dev/null >/dev/null 2>&1 &"), "Vibe waits for the hook's pipes to close")
        // The watcher tests shorten the interval through the environment; the
        // shipped default stays two seconds.
        XCTAssertTrue(source.contains(#"WATCH_INTERVAL="${LOCALVOXTRAL_VIBE_WATCH_INTERVAL:-2}""#))
        XCTAssertTrue(source.contains("*) WATCH_INTERVAL=2 ;; esac"))

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
