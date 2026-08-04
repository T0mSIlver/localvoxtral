import Foundation
import JavaScriptCore
import XCTest
@testable import ClaudeContextWire
@testable import localvoxtral

/// Validates the opencode plugin (`integrations/opencode/localvoxtral.js`) as
/// an artifact, the way `ClaudeRemotePluginManifestTests` pins the remote
/// shim: the file runs inside the user's agent process on a machine where
/// nothing of ours is watching, so every drift below would fail open and
/// silently — wrong socket path, wrong wire constants, an event name the
/// broker drops, or a stray write that corrupts the user's TUI.
///
/// What is mechanically checkable is pinned here; actually loading under
/// opencode's two plugin loaders is proven by the scripted TUI run in the
/// PR's Proof section (opencode is not installed on CI machines).
final class OpencodePluginManifestTests: XCTestCase {
    private var pluginURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        pluginURL = try XCTUnwrap(ClaudePluginAssets.developmentOpencodePluginURL())
    }

    private func source() throws -> String {
        try String(contentsOf: pluginURL, encoding: .utf8)
    }

    private var readmeURL: URL {
        pluginURL.deletingLastPathComponent().appendingPathComponent("README.md")
    }

    // MARK: Blast radius — the plugin runs inside the user's agent process

    func testPluginExistsAndStaysSmall() throws {
        let bytes = try Data(contentsOf: pluginURL).count
        XCTAssertGreaterThan(bytes, 0)
        // One dependency-free file is the premise; a bundle would mean the
        // premise is gone.
        XCTAssertLessThan(bytes, 24 * 1024, "the plugin must stay one small auditable file")
    }

    func testNoAwaitAnywhereSoNoHookCanStallTheUsersTurn() throws {
        // The hard blast-radius rule: handlers are fire-and-forget. Zero
        // occurrences of the keyword anywhere (code or comments) keeps this
        // trivially checkable — a legitimate future use must restructure, not
        // relax.
        XCTAssertFalse(try source().contains("await"), "no handler may suspend on anything")
    }

    func testNeverTouchesTheTerminalOrSpawnsAnything() throws {
        let text = try source()
        for forbidden in [
            "console.", // any logging corrupts the TUI or the turn
            "process.stdout",
            "process.stderr",
            // The blocklist above misses raw descriptor writes (review C6):
            // fs.writeSync(1, …) reaches the terminal without ever naming
            // stdout. No form of writeSync has a legitimate use here.
            "writeSync",
            "child_process",
            "Bun.spawn",
            "fetch(",
            "require(",
            "\\x1b", // no escape sequences: this plugin has no title channel
            "\\u001b",
            "]2;",
        ] {
            XCTAssertFalse(text.contains(forbidden), "forbidden pattern in plugin: \(forbidden)")
        }
    }

    func testServerHalfSpanNeverMentionsATTY() throws {
        // The server half must be UNABLE to publish a TTY (invariant 1: under
        // `opencode serve` an isatty answer names a pane that does not display
        // the session). record()'s tty parameter is only reachable from the
        // TUI half; pin that mechanically by asserting the server half's whole
        // span never contains the token at all (review C6 / opencode F2).
        let text = try source()
        let start = try XCTUnwrap(text.range(of: "const ServerHalf"))
        let end = try XCTUnwrap(text.range(of: "// TUI half"))
        XCTAssertLessThan(start.lowerBound, end.lowerBound, "server half must precede the TUI half")
        let span = text[start.lowerBound..<end.lowerBound].lowercased()
        XCTAssertFalse(span.contains("tty"), "the server half may never touch a TTY, even lexically")
    }

    func testSocketIsUnrefedSoThePluginCannotKeepOpencodeAlive() throws {
        XCTAssertTrue(try source().contains(".unref()"))
    }

    func testBackpressureIsBoundedByADropNeverAWait() throws {
        // Review C5: socket.write with the broker not draining must never
        // queue unboundedly inside the agent process. The plugin checks the
        // queued-byte watermark and resets the connection past the cap.
        let text = try source()
        XCTAssertTrue(text.contains("const MAX_QUEUED_BYTES = 64 * 1024;"))
        XCTAssertTrue(
            text.contains("writableLength > MAX_QUEUED_BYTES"),
            "the queued-bytes watermark must gate every write"
        )
    }

    func testPendingBrokerRepliesAreBoundedByAReset() throws {
        // The reply-callback queue must be bounded the same way queued bytes
        // are: a peer that reads but never answers must reset the connection,
        // not grow a callback queue inside the agent process.
        let text = try source()
        XCTAssertTrue(text.contains("const MAX_PENDING_REPLIES = 16;"))
        XCTAssertTrue(
            text.contains("pendingReplies.length >= MAX_PENDING_REPLIES"),
            "the pending-reply watermark must gate every write"
        )
    }

    // MARK: Wire contract — pinned to the Swift constants, not to copies

    func testWireVersionAndAgentMatchTheSwiftWire() throws {
        let text = try source()
        XCTAssertTrue(
            text.contains("const WIRE_VERSION = \(ClaudeHookWire.version);"),
            "plugin wire version must equal ClaudeHookWire.version"
        )
        XCTAssertTrue(
            text.contains("const AGENT = \"\(ClaudeHookAgent.opencode.rawValue)\";"),
            "plugin agent tag must equal ClaudeHookAgent.opencode"
        )
    }

    func testSocketPathResolutionMirrorsClaudeHookSocketPath() throws {
        let text = try source()
        XCTAssertTrue(text.contains(ClaudeHookSocketPath.environmentKey))
        // The darwin default, assembled from the same components the Swift
        // resolver uses — a drifted directory name would fail open forever.
        let darwin = "/Library/Application Support/localvoxtral/"
            + ClaudeHookSocketPath.runDirectoryName + "/" + ClaudeHookSocketPath.socketFileName
        XCTAssertTrue(text.contains(darwin), "darwin socket path must match ClaudeHookSocketPath")
    }

    func testEveryPublishedEventNameIsAKnownWireEvent() throws {
        let text = try source()
        let published = [
            "SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd",
            "FocusChanged", "FocusCleared",
        ]
        for event in published {
            XCTAssertTrue(text.contains("\"\(event)\""), "plugin should publish \(event)")
            XCTAssertNotNil(
                ClaudeHookEvent(rawValue: event),
                "\(event) is not a wire event; the broker would drop every record"
            )
        }
    }

    func testBoundsMirrorClaudeHookLimits() throws {
        let text = try source()
        let pins: [(String, Int)] = [
            ("const MAX_LINE_BYTES = 64 * 1024;", ClaudeHookLimits.default.maxLineBytes),
            ("const MAX_PROMPT_BYTES = 8 * 1024;", ClaudeHookLimits.default.maxPromptBytes),
            ("const MAX_PATH_BYTES = 4 * 1024;", ClaudeHookLimits.default.maxPathBytes),
            ("const MAX_FILES_PER_RECORD = 16;", ClaudeHookLimits.default.maxFilePathsPerRecord),
        ]
        let values = [64 * 1024, 8 * 1024, 4 * 1024, 16]
        for (index, (line, swiftValue)) in pins.enumerated() {
            XCTAssertTrue(text.contains(line), "missing bound pin: \(line)")
            XCTAssertEqual(swiftValue, values[index], "Swift limit drifted from the plugin's pin")
        }
    }

    func testFocusHeartbeatAndSampleCadenceFitTheRegistryTTL() throws {
        let text = try source()
        XCTAssertTrue(text.contains("const FOCUS_HEARTBEAT_MS = 20000;"))
        // The half-second sample is what bounds switch latency (no
        // route-change event exists in opencode 1.17.x's TUI plugin API).
        XCTAssertTrue(text.contains("const FOCUS_POLL_MS = 500;"))
        // One lost 20s heartbeat plus sampling jitter must still leave a live
        // declaration; more than that and the pane has gone silent for real.
        XCTAssertGreaterThanOrEqual(
            ClaudeRegistryLimits.defaultFocusDeclarationTTL, 2 * 20 + 5,
            "registry focus TTL must cover one lost 20s heartbeat plus jitter"
        )
    }

    func testHerdrPaneIdentityIsForwarded() throws {
        let text = try source()
        XCTAssertTrue(text.contains("HERDR_PANE_ID"))
        XCTAssertTrue(text.contains("HERDR_SOCKET_PATH"))
    }

    // MARK: Realm split — evaluate the file and check both export shapes
    //
    // JavaScriptCore is the same engine Bun embeds, so a syntax error here is
    // a syntax error there. ESM statements are rewritten (imports stripped,
    // `export default` captured) because JSC's evaluateScript is not a module
    // loader; only `isMainThread` needs stubbing for top-level evaluation.

    private func evaluateDefaultExport(isMainThread: Bool) throws -> JSValue {
        var text = try source()
        text = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.hasPrefix("import ") ? "" : String(line) }
            .joined(separator: "\n")
            .replacingOccurrences(of: "export default", with: "globalThis.__defaultExport =")

        let context = try XCTUnwrap(JSContext())
        let failure = Box<String?>(nil)
        context.exceptionHandler = { _, exception in
            failure.value = exception?.toString()
        }
        context.evaluateScript("const isMainThread = \(isMainThread);")
        context.evaluateScript(text)
        if let message = failure.value {
            XCTFail("plugin failed to evaluate: \(message)")
        }
        return try XCTUnwrap(context.evaluateScript("globalThis.__defaultExport"))
    }

    private final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    func testMainRealmExportsTheTuiHalfOnly() throws {
        // opencode's loaders reject a default export carrying both server()
        // and tui() (plugin/shared.ts, readV1Plugin), and the local TUI runs
        // its server in a Worker realm — so the export must be exactly one
        // half per realm, chosen by isMainThread.
        let module = try evaluateDefaultExport(isMainThread: true)
        XCTAssertEqual(module.forProperty("id").toString(), "localvoxtral")
        XCTAssertTrue(module.forProperty("tui").isObject, "main realm must export tui()")
        XCTAssertTrue(module.forProperty("server").isUndefined, "main realm must not export server()")
    }

    func testWorkerRealmExportsTheServerHalfOnly() throws {
        let module = try evaluateDefaultExport(isMainThread: false)
        XCTAssertEqual(module.forProperty("id").toString(), "localvoxtral")
        XCTAssertTrue(module.forProperty("server").isObject, "worker realm must export server()")
        XCTAssertTrue(module.forProperty("tui").isUndefined, "worker realm must not export tui()")
    }

    // MARK: README — the only install instructions a user gets

    private func readmeLines() throws -> [String] {
        try String(contentsOf: readmeURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func testReadmeDocumentsBothInstallStepsAndUninstall() throws {
        let lines = try readmeLines()
        XCTAssertTrue(lines.contains("cp localvoxtral.js ~/.config/opencode/plugins/"))
        // The tui.json step is the one users will skip; it must be present and
        // must explain the cost of skipping it.
        XCTAssertTrue(lines.contains(#""plugin": ["./plugins/localvoxtral.js"]"#))
        XCTAssertTrue(lines.contains { $0.contains("vocabulary-only") })
        XCTAssertTrue(lines.contains("rm ~/.config/opencode/plugins/localvoxtral.js"))
    }

    func testReadmeIsHonestAboutHeadlessModes() throws {
        // `opencode run`/`serve` publishing nothing is deliberate; undocumented
        // it reads as a bug and invites a "fix" that would publish a
        // mis-joining TTY from a serve process.
        let lines = try readmeLines()
        XCTAssertTrue(lines.contains { $0.contains("`opencode run` and `opencode serve`") })
        XCTAssertTrue(lines.contains { $0.contains("never") && $0.contains("TTY") })
    }
}
