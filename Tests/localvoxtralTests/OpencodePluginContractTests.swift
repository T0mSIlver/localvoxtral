import Foundation
import JavaScriptCore
import XCTest
@testable import ClaudeContextWire
@testable import localvoxtral

/// Behavior-level contract tests for the opencode plugin
/// (`integrations/opencode/localvoxtral.js`), complementing the artifact pins
/// in `OpencodePluginManifestTests`: the plugin is evaluated under
/// JavaScriptCore with Node built-ins stubbed, its handlers are driven
/// directly, and every line it writes to the fake broker socket is captured
/// and decoded.
///
/// Two invariants earned their tests in review (PR #204 follow-up):
///
/// 1. Focus-declaration state must advance ONLY after a broker reply arrives
///    for that write. `socket.write()` succeeding proves nothing — the runtime
///    buffers writes while connecting, and the broker serves short
///    connections (8 records / 2s deadline), so a written record is routinely
///    lost to a reset. A declaration or retraction the broker never read must
///    be retried at the next sample, not suppressed for the 20s heartbeat.
///
/// 2. Session filtering must fail CLOSED. The server half publishes a
///    session's activity only while its id is in the bounded allowlist of
///    known top-level (parentless) sessions — an evicted child, a deleted
///    session, or an id never seen created is dropped, never published as if
///    it were the session the user is typing into.
///
/// Harness note: the manifest suite enforces zero `await` tokens in the
/// plugin, so stripping the `async ` keyword is semantics-preserving here —
/// handlers become synchronous and no microtask draining is needed.
final class OpencodePluginContractTests: XCTestCase {
    private var context: JSContext!
    private var failure: Box<String?>!

    private final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    // MARK: Harness

    /// Node built-ins the plugin imports, stubbed for a bare JSContext. The
    /// fake socket records every write into `__writes`, keeps its event
    /// handlers reachable so tests can deliver broker replies or fail the
    /// connection, and exposes the created sockets as `__sockets`.
    private static let prelude = #"""
    globalThis.__writes = [];
    globalThis.__sockets = [];
    globalThis.__intervals = [];

    function __utf8Bytes(value) {
      const out = [];
      for (const ch of String(value)) {
        const cp = ch.codePointAt(0);
        if (cp < 0x80) out.push(cp);
        else if (cp < 0x800) out.push(0xc0 | (cp >> 6), 0x80 | (cp & 0x3f));
        else if (cp < 0x10000) {
          out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
        } else {
          out.push(
            0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f),
            0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f)
          );
        }
      }
      return out;
    }
    function __wrapBytes(bytes) {
      bytes.subarray = (from, to) => __wrapBytes(bytes.slice(from, to));
      bytes.toString = () => {
        // ASCII round-trip is all the tests need; payloads stay under limits.
        let text = "";
        for (const byte of bytes) text += String.fromCharCode(byte);
        return text;
      };
      return bytes;
    }
    globalThis.Buffer = {
      byteLength: (value) => __utf8Bytes(value).length,
      from: (value) => __wrapBytes(__utf8Bytes(value)),
    };

    globalThis.process = {
      pid: 4242,
      platform: "linux",
      env: {
        HOME: "/home/tester",
        LOCALVOXTRAL_CLAUDE_SOCKET: "/tmp/lvx-contract-test.sock",
        TERM_PROGRAM: "ghostty",
      },
    };

    globalThis.setInterval = (fn) => {
      globalThis.__intervals.push(fn);
      return { unref() {} };
    };
    globalThis.clearInterval = () => {};

    globalThis.net = {
      createConnection(path) {
        const socket = {
          destroyed: false,
          writableLength: 0,
          handlers: {},
          unref() {},
          on(name, fn) { this.handlers[name] = fn; },
          write(line) {
            globalThis.__writes.push(line);
            return true;
          },
          destroy() {
            if (this.destroyed) return;
            this.destroyed = true;
            if (this.handlers.close) this.handlers.close();
          },
          end() { this.destroy(); },
        };
        globalThis.__sockets.push(socket);
        return socket;
      },
    };
    globalThis.fs = {
      readlinkSync: () => "/dev/pts/7",
    };
    globalThis.isatty = () => true;
    """#

    private func loadPlugin(isMainThread: Bool) throws {
        let pluginURL = try XCTUnwrap(ClaudePluginAssets.developmentOpencodePluginURL())
        var text = try String(contentsOf: pluginURL, encoding: .utf8)
        text = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.hasPrefix("import ") ? "" : String(line) }
            .joined(separator: "\n")
            .replacingOccurrences(of: "export default", with: "globalThis.__module =")
            // Zero `await` tokens is a pinned invariant, so the async keyword
            // is inert: dropping it makes handlers return their values
            // synchronously instead of via an immediately-resolved promise.
            .replacingOccurrences(of: "async ", with: "")

        context = try XCTUnwrap(JSContext())
        failure = Box(nil)
        let box = failure!
        context.exceptionHandler = { _, exception in
            box.value = exception?.toString()
        }
        context.evaluateScript("const isMainThread = \(isMainThread);")
        context.evaluateScript(Self.prelude)
        context.evaluateScript(text)
        if let message = failure.value {
            XCTFail("plugin failed to evaluate: \(message)")
        }
    }

    @discardableResult
    private func run(_ script: String, file: StaticString = #filePath, line: UInt = #line) -> JSValue? {
        let value = context.evaluateScript(script)
        if let message = failure.value {
            XCTFail("script raised: \(message)\nscript: \(script)", file: file, line: line)
            failure.value = nil
        }
        return value
    }

    /// Every record written to any socket so far, decoded, oldest first.
    private func writtenRecords() throws -> [[String: Any]] {
        let json = try XCTUnwrap(run("JSON.stringify(globalThis.__writes)")?.toString())
        let lines = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String]
        )
        return try lines.map { line in
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                "unparseable record line: \(line)"
            )
        }
    }

    private func records(event: String, session: String? = nil) throws -> [[String: Any]] {
        try writtenRecords().filter { record in
            record["event"] as? String == event
                && (session == nil || record["session_id"] as? String == session)
        }
    }

    // MARK: TUI-half helpers

    private func startTUI() throws {
        try loadPlugin(isMainThread: true)
        run(#"""
        globalThis.__api = {
          route: { current: undefined },
          event: { on: (type, fn) => (() => {}) },
          lifecycle: { onDispose: (fn) => { globalThis.__dispose = fn; } },
        };
        globalThis.__module.tui(globalThis.__api);
        """#)
        let sampler = try XCTUnwrap(run("globalThis.__intervals.length")?.toInt32())
        XCTAssertEqual(sampler, 1, "the TUI half must register exactly one sampling interval")
    }

    private func setRoute(sessionID: String?) {
        if let sessionID {
            run(#"__api.route.current = { name: "session", params: { sessionID: "\#(sessionID)" } };"#)
        } else {
            run("__api.route.current = undefined;")
        }
    }

    private func sample() {
        run("globalThis.__intervals[0]();")
    }

    /// Deliver one broker reply line on the most recently created socket —
    /// the shape `ClaudeContextBroker.reply` sends for an opencode record.
    /// `accepted: nil` produces a reply with no `accepted` key at all: the
    /// pre-accepted-era broker shape, which must settle callbacks true.
    private func deliverBrokerReply(accepted: Bool? = nil) {
        let line = String(
            decoding: ClaudeBrokerResponse.encodeLine(
                ClaudeBrokerResponse(marker: nil, accepted: accepted)
            )!,
            as: UTF8.self
        ).replacingOccurrences(of: "\n", with: "\\n")
        deliverRawReplyChunks([line])
    }

    /// Deliver raw bytes on the most recently created socket, one data event
    /// per chunk — for unparseable replies and chunk-boundary splits.
    private func deliverRawReplyChunks(_ chunks: [String]) {
        for chunk in chunks {
            run(#"""
            (() => {
              const socket = globalThis.__sockets[globalThis.__sockets.length - 1];
              socket.handlers.data('\#(chunk)');
            })();
            """#)
        }
    }

    /// Fail the most recently created socket the way a dead broker does:
    /// an error event, then close. No reply is ever delivered.
    private func failConnection() {
        run(#"""
        (() => {
          const socket = globalThis.__sockets[globalThis.__sockets.length - 1];
          if (socket.handlers.error) socket.handlers.error(new Error("connection lost"));
          socket.destroy();
        })();
        """#)
    }

    // MARK: Finding 1 — focus state advances only after a broker reply

    func testFocusDeclarationIsRetriedWhenTheConnectionFailsBeforeAnyReply() throws {
        try startTUI()
        setRoute(sessionID: "sesA")
        sample()
        XCTAssertEqual(
            try records(event: "FocusChanged", session: "sesA").count, 1,
            "first sample must declare the focused session"
        )

        // The write reached the socket but the broker never replied — the
        // connection dies (routine: the broker closes after 8 records or 2s).
        failConnection()

        sample()
        XCTAssertEqual(
            try records(event: "FocusChanged", session: "sesA").count, 2,
            "an unacknowledged declaration must be retried at the next sample, "
                + "not suppressed for the 20s heartbeat"
        )
        let declaration = try XCTUnwrap(try records(event: "FocusChanged").last)
        let process = try XCTUnwrap(declaration["process"] as? [String: Any])
        XCTAssertEqual(process["tty"] as? String, "/dev/pts/7")
    }

    func testFocusRetractionIsRetriedWhenTheConnectionFailsBeforeAnyReply() throws {
        try startTUI()
        setRoute(sessionID: "sesA")
        sample()
        deliverBrokerReply() // declaration acknowledged: sesA is now declared

        setRoute(sessionID: nil)
        sample()
        XCTAssertEqual(try records(event: "FocusCleared", session: "sesA").count, 1)

        // Retraction written, never read by the broker.
        failConnection()

        sample()
        XCTAssertEqual(
            try records(event: "FocusCleared", session: "sesA").count, 2,
            "a lost retraction must be retried — clearing local state on an "
                + "unacknowledged write silently leaves the registry declaring sesA"
        )
    }

    func testFocusStateAdvancesOnReplyAndHeartbeatSuppressesResends() throws {
        // Doubles as the old-broker compat pin: this reply carries no
        // `accepted` field (a pre-accepted-era broker never sends one), and
        // it must settle true — an old broker must not cause retry storms.
        try startTUI()
        setRoute(sessionID: "sesA")
        sample()
        deliverBrokerReply()
        sample()
        sample()
        XCTAssertEqual(
            try records(event: "FocusChanged", session: "sesA").count, 1,
            "an acknowledged declaration must be heartbeat-suppressed, not resent every sample"
        )
    }

    func testRegistryRejectedFocusDeclarationIsRetriedUntilAccepted() throws {
        // The declaration-before-session race #209 documented as residual,
        // now closed: the broker replies `accepted:false` when the registry
        // refused the declaration (it only honors declarations for sessions
        // it knows), and the plugin must treat that as NOT delivered — retry
        // at the next 500ms sample instead of letting the 20s heartbeat
        // suppress the repair while dictation grounds on the previous
        // session's context.
        try startTUI()
        setRoute(sessionID: "sesB")
        sample()
        XCTAssertEqual(try records(event: "FocusChanged", session: "sesB").count, 1)

        deliverBrokerReply(accepted: false)
        sample()
        XCTAssertEqual(
            try records(event: "FocusChanged", session: "sesB").count, 2,
            "a registry-rejected declaration must be retried at the next sample"
        )

        deliverBrokerReply(accepted: true)
        sample()
        sample()
        XCTAssertEqual(
            try records(event: "FocusChanged", session: "sesB").count, 2,
            "once the reply says accepted, the heartbeat takes over"
        )
    }

    func testUnparseableReplyLineSettlesTrueLikeAPreAcceptedEraBroker() throws {
        // The tolerant end of the new contract: a reply line the plugin
        // cannot parse must behave exactly like one with no `accepted` field
        // — settle true. Anything else turns an odd-but-live broker into a
        // permanent retry storm inside the user's agent process.
        try startTUI()
        setRoute(sessionID: "sesA")
        sample()
        deliverRawReplyChunks(["this is not json\\n"])
        sample()
        sample()
        XCTAssertEqual(
            try records(event: "FocusChanged", session: "sesA").count, 1,
            "an unparseable reply must settle true, exactly the pre-accepted behavior"
        )
    }

    func testAcceptedFalseIsParsedAcrossChunkBoundaries() throws {
        // Reply bytes arrive on whatever read boundaries the runtime picked;
        // the verdict must survive a line split mid-key.
        try startTUI()
        setRoute(sessionID: "sesA")
        sample()
        deliverRawReplyChunks([#"{"accep"#, #"ted":false,"v":2}\n"#])
        sample()
        XCTAssertEqual(
            try records(event: "FocusChanged", session: "sesA").count, 2,
            "a rejection split across data events must still be read as one line"
        )
    }

    func testOnlyOneFocusRecordIsInFlightAtATime() throws {
        try startTUI()
        setRoute(sessionID: "sesA")
        sample()
        sample() // no reply yet — must not stack a second declaration
        XCTAssertEqual(
            try records(event: "FocusChanged", session: "sesA").count, 1,
            "sampling while a declaration is unacknowledged must not spam the broker"
        )
        deliverBrokerReply()
        setRoute(sessionID: "sesB")
        sample()
        XCTAssertEqual(
            try records(event: "FocusChanged", session: "sesB").count, 1,
            "a session switch after the reply must declare immediately"
        )
    }

    func testDisposeRetractsTheDeclaredFocusBestEffort() throws {
        try startTUI()
        setRoute(sessionID: "sesA")
        sample()
        deliverBrokerReply()
        run("globalThis.__dispose();")
        XCTAssertEqual(
            try records(event: "FocusCleared", session: "sesA").count, 1,
            "dispose must retract the declared focus (fire-and-forget is fine here)"
        )
    }

    // MARK: Finding 3 — session filtering fails closed

    private func startServer() throws {
        try loadPlugin(isMainThread: false)
        run("globalThis.__hooks = globalThis.__module.server();")
        let kind = try XCTUnwrap(run("typeof globalThis.__hooks")?.toString())
        XCTAssertEqual(kind, "object", "ServerHalf must return its hooks object")
    }

    private func createSession(id: String, parentID: String? = nil, directory: String? = nil) {
        let parent = parentID.map { #", parentID: "\#($0)""# } ?? ""
        let dir = directory.map { #", directory: "\#($0)""# } ?? ""
        run(#"""
        __hooks.event({ event: { type: "session.created", properties: {
          info: { id: "\#(id)"\#(parent)\#(dir) } } } });
        """#)
    }

    private func sendChatMessage(sessionID: String, text: String = "hello") {
        run(#"""
        __hooks["chat.message"](
          { sessionID: "\#(sessionID)" },
          { parts: [{ type: "text", text: "\#(text)" }] }
        );
        """#)
    }

    func testTopLevelSessionLifecyclePublishes() throws {
        try startServer()
        createSession(id: "parent", directory: "/repo/p")
        XCTAssertEqual(try records(event: "SessionStart", session: "parent").count, 1)

        sendChatMessage(sessionID: "parent", text: "hello world")
        let prompt = try XCTUnwrap(try records(event: "UserPromptSubmit", session: "parent").first)
        XCTAssertEqual(prompt["prompt"] as? String, "hello world")
        XCTAssertEqual(prompt["cwd"] as? String, "/repo/p")

        run(#"__hooks.event({ event: { type: "session.idle", properties: { sessionID: "parent" } } });"#)
        XCTAssertEqual(try records(event: "Stop", session: "parent").count, 1)

        run(#"__hooks.event({ event: { type: "session.deleted", properties: { info: { id: "parent" } } } });"#)
        XCTAssertEqual(try records(event: "SessionEnd", session: "parent").count, 1)
    }

    func testChildSessionLifecycleIsNeverPublished() throws {
        try startServer()
        createSession(id: "parent", directory: "/repo/p")
        createSession(id: "child", parentID: "parent")
        sendChatMessage(sessionID: "child")
        run(#"__hooks.event({ event: { type: "session.deleted", properties: { info: { id: "child" } } } });"#)
        let childRecords = try writtenRecords().filter { $0["session_id"] as? String == "child" }
        XCTAssertTrue(
            childRecords.isEmpty,
            "a task-tool child session must never publish; got \(childRecords)"
        )
    }

    func testEvictedChildSessionActivityIsNotPublished() throws {
        try startServer()
        createSession(id: "parent", directory: "/repo/p")
        createSession(id: "child-0", parentID: "parent")
        // Push child-0 out of any bounded tracking structure.
        run(#"""
        for (let index = 1; index <= 64; index += 1) {
          __hooks.event({ event: { type: "session.created", properties: {
            info: { id: "child-" + index, parentID: "parent" } } } });
        }
        """#)
        sendChatMessage(sessionID: "child-0")
        run(#"""
        __hooks["tool.execute.after"]({
          sessionID: "child-0", tool: "read", args: { filePath: "/repo/p/file.txt" },
        });
        """#)
        run(#"__hooks.event({ event: { type: "session.idle", properties: { sessionID: "child-0" } } });"#)
        let escaped = try writtenRecords().filter { $0["session_id"] as? String == "child-0" }
        XCTAssertTrue(
            escaped.isEmpty,
            "an evicted child's later activity must fail closed, not publish as top-level; got \(escaped)"
        )
    }

    func testSessionNeverSeenCreatedIsNotPublished() throws {
        try startServer()
        sendChatMessage(sessionID: "ghost")
        run(#"__hooks.event({ event: { type: "session.idle", properties: { sessionID: "ghost" } } });"#)
        run(#"__hooks.event({ event: { type: "session.deleted", properties: { info: { id: "ghost" } } } });"#)
        let ghost = try writtenRecords().filter { $0["session_id"] as? String == "ghost" }
        XCTAssertTrue(
            ghost.isEmpty,
            "an id with unknown parentage must be dropped — only known top-level sessions publish; got \(ghost)"
        )
    }

    func testDeletedSessionsLateActivityIsNotPublished() throws {
        try startServer()
        createSession(id: "parent", directory: "/repo/p")
        run(#"__hooks.event({ event: { type: "session.deleted", properties: { info: { id: "parent" } } } });"#)
        sendChatMessage(sessionID: "parent")
        XCTAssertEqual(
            try records(event: "UserPromptSubmit", session: "parent").count, 0,
            "activity after SessionEnd must be dropped, not resurrect the session"
        )
    }

    func testEvictedTopLevelSessionFailsClosed() throws {
        try startServer()
        createSession(id: "top-0", directory: "/repo/0")
        run(#"""
        for (let index = 1; index <= 64; index += 1) {
          __hooks.event({ event: { type: "session.created", properties: {
            info: { id: "top-" + index, directory: "/repo/x" } } } });
        }
        """#)
        sendChatMessage(sessionID: "top-0")
        XCTAssertEqual(
            try records(event: "UserPromptSubmit", session: "top-0").count, 0,
            "past the tracking bound the oldest top-level session drops out fail-closed"
        )
    }
}
