import ClaudeContextWire
import Foundation
import localvoxtralTestSupport
import XCTest
@testable import localvoxtral

/// One dictation from start to stop, in process, with every link between the
/// capture callback and the target app running as it does in the app: the
/// session start, the chunk buffer, the send and commit loops, the real
/// `RealtimeAPIWebSocketClient` over a real socket, transcript merging, live
/// insertion or the overlay buffer, and the stop's flush, final commit and
/// commit. The edges are fakes: a microphone that delivers the chunks the
/// test hands it, a loopback server that transcribes what the test says, and
/// an inserter that records what would have been typed.
///
/// The in-process counterpart of `scripts/e2e-dictation.sh`, one test per
/// scenario in `scripts/e2e/scenarios`. What only that check reaches: the
/// packaged app, a real speech model, the target app's window, focus and TCC.
///
/// The session's timers run on a `ManualSessionClock`; the socket's traffic
/// is awaited, never slept for.
#if DEBUG
@MainActor
final class DictationPipelineTests: XCTestCase {
    private static let model = "fake-realtime-model"
    private static let phrase = "hello from localvoxtral. this is an in-process check."

    /// Live Auto-Paste: the words are typed while the dictation runs, and the
    /// stop types nothing twice.
    func testLiveAutoPasteTypesTheTranscriptWhileDictating() async throws {
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        let typed = TypedText()
        pipeline.viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        pipeline.viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { chunk in
                typed.append(chunk)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false }
        )

        await startAndSpeak(pipeline)
        sendPartials(pipeline)
        let typedWhileDictating = await typed.waitFor(Self.phrase)
        XCTAssertTrue(typedWhileDictating, "typed so far: \(typed.text.debugDescription)")
        XCTAssertTrue(pipeline.viewModel.isDictating, "typed before the stop, not by it")

        await stopAndFinalize(pipeline)

        XCTAssertEqual(typed.text, Self.phrase)
        XCTAssertEqual(pipeline.records.all.map(\.rawText), [Self.phrase])
        XCTAssertEqual(pipeline.overlay.commitCallCount, 0)
    }

    /// Overlay Buffer: the words collect in the overlay while the dictation
    /// runs and are committed once, on stop.
    func testOverlayBufferCommitsTheTranscriptOnStop() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        let shown = BoundedWait()
        pipeline.overlay.onRefresh = { call in
            if call.displayText == Self.phrase { shown.resolve() }
        }

        await startAndSpeak(pipeline)
        XCTAssertEqual(pipeline.overlay.startSessionAnchors.count, 1, "the overlay opened with the socket")
        sendPartials(pipeline)
        let shownWhileDictating = await shown.value(failAfter: 10)
        XCTAssertTrue(
            shownWhileDictating,
            "overlay shows: \(pipeline.overlay.refreshCalls.last?.displayText.debugDescription ?? "nothing")"
        )
        XCTAssertEqual(pipeline.overlay.commitCallCount, 0, "nothing is committed before the stop")

        await stopAndFinalize(pipeline)

        XCTAssertEqual(pipeline.overlay.committedTexts, [Self.phrase])
        XCTAssertEqual(pipeline.records.all.map(\.rawText), [Self.phrase])
        XCTAssertEqual(pipeline.records.all.first?.commitSucceeded, true)
    }

    /// Quick capture (#725): the shortcut's dictation runs as Overlay Buffer,
    /// but its stop commits nothing to the focused app. The History record
    /// is written first, then the words go to the Inbox.
    func testAQuickCaptureGoesToTheInboxNeverIntoTheFocusedApp() async throws {
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        let captured = QuickCaptures()
        pipeline.viewModel.session.onQuickCapture = { text, _ in
            captured.all.append((text, pipeline.records.all.count))
        }

        await startAndSpeak(pipeline, start: { $0.session.toggleQuickCapture() })
        XCTAssertEqual(pipeline.overlay.startSessionAnchors.count, 1, "a capture opens the overlay whatever the menu bar mode")
        sendPartials(pipeline)
        await stopAndFinalize(pipeline, finalStatus: DictationViewModel.StatusStrings.quickCaptureSaved)

        XCTAssertEqual(pipeline.overlay.commitCallCount, 0, "nothing reaches the focused app")
        XCTAssertEqual(captured.all.map(\.text), [Self.phrase])
        XCTAssertEqual(captured.all.first?.recordsWritten, 1, "saved in History before the Inbox gets it")
        let record = try XCTUnwrap(pipeline.records.all.first)
        XCTAssertEqual(record.outputMode, DictationSessionRecord.quickCaptureOutputMode)
        XCTAssertEqual(record.quickCaptureDestination, "Inbox")
        XCTAssertNil(record.polishedText)
        XCTAssertFalse(pipeline.viewModel.session.sessionIsQuickCapture, "the next dictation is an ordinary one")
    }

    /// Claude Desktop (#660): a text field whose prompt sends on Return. The
    /// dictation starts before Electron has built its accessibility tree, so
    /// the AX probe finds nothing focused, which alone reads as a terminal.
    /// The session stays a text-field session, and "send it" submits there.
    func testLiveAutoPasteIntoClaudeDesktopSendsOnTheSpokenTrigger() async throws {
        let desktopPID: pid_t = 4343
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        pipeline.viewModel.settings.liveSpokenSendEnabled = true
        pipeline.viewModel.dependencies.bundleIdentifier = {
            $0 == desktopPID ? ClaudeDesktopAllowlist.bundleID : nil
        }
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { ClaudeDesktopAllowlist.bundleID }
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .noFocusedElement }
        TerminalTargetDetector.debugSecureEventInputOverride = { false }
        addTeardownBlock { @MainActor in
            TerminalTargetDetector.debugFrontmostBundleIDOverride = nil
            TerminalTargetDetector.debugFocusedElementProbeOverride = nil
            TerminalTargetDetector.debugSecureEventInputOverride = nil
        }
        let typed = TypedText()
        var returns: [pid_t] = []
        pipeline.viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        pipeline.viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { chunk in
                typed.append(chunk)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false },
            returnKeyPoster: { pid in
                returns.append(pid)
                return true
            },
            frontmostPIDReader: { desktopPID }
        )

        await startAndSpeak(pipeline)
        XCTAssertFalse(pipeline.viewModel.session.sessionTargetIsTerminalLike)
        pipeline.server.send(["type": "transcription.delta", "delta": "run the tests, send"])
        pipeline.server.send(["type": "transcription.done", "text": "run the tests, send it."])
        let typedTheSegment = await typed.waitFor("run the tests")
        XCTAssertTrue(typedTheSegment, "typed so far: \(typed.text.debugDescription)")
        XCTAssertEqual(returns, [desktopPID], "Return follows the segment, in Claude Desktop")

        await stopAndFinalize(pipeline)
        XCTAssertEqual(returns, [desktopPID], "the stop's final holds no trigger")
    }

    /// Claude Desktop (#660): a newline inside a typed unicode event was
    /// dropped or scrambled there, so each one is pressed as Shift+Return.
    func testLiveAutoPasteIntoClaudeDesktopTypesNewlinesAsShiftReturn() async throws {
        let text = "first line\nsecond line."
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { ClaudeDesktopAllowlist.bundleID }
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .noFocusedElement }
        TerminalTargetDetector.debugSecureEventInputOverride = { false }
        addTeardownBlock { @MainActor in
            TerminalTargetDetector.debugFrontmostBundleIDOverride = nil
            TerminalTargetDetector.debugFocusedElementProbeOverride = nil
            TerminalTargetDetector.debugSecureEventInputOverride = nil
        }
        let typed = TypedText()
        pipeline.viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        pipeline.viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { chunk in
                typed.append(chunk)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false },
            shiftReturnPoster: {
                typed.append("⇧⏎")
                return true
            }
        )

        await startAndSpeak(pipeline)
        pipeline.server.send(["type": "transcription.delta", "delta": text])
        await stopAndFinalize(pipeline, finalText: text)

        XCTAssertEqual(typed.text, "first line⇧⏎second line.")
        XCTAssertFalse(typed.chunks.contains { $0.contains(where: \.isNewline) }, "no newline is typed as text")
    }

    /// Claude Desktop (#695): a code fence typed at the start of a line
    /// opened a code block that took the text after it, so a text holding
    /// one is pasted whole, with no typed keys and no Shift+Return.
    func testLiveAutoPasteIntoClaudeDesktopPastesTextWithACodeFence() async throws {
        let text = "see:\n```\nline one\nline two\n```\nthanks."
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { ClaudeDesktopAllowlist.bundleID }
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .noFocusedElement }
        TerminalTargetDetector.debugSecureEventInputOverride = { false }
        addTeardownBlock { @MainActor in
            TerminalTargetDetector.debugFrontmostBundleIDOverride = nil
            TerminalTargetDetector.debugFocusedElementProbeOverride = nil
            TerminalTargetDetector.debugSecureEventInputOverride = nil
        }
        let typed = TypedText()
        var pasted: [String] = []
        pipeline.viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        pipeline.viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { chunk in
                typed.append(chunk)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false },
            shiftReturnPoster: {
                typed.append("⇧⏎")
                return true
            },
            commandVPaster: { text in
                pasted.append(text)
                return true
            }
        )

        await startAndSpeak(pipeline)
        pipeline.server.send(["type": "transcription.delta", "delta": text])
        await stopAndFinalize(pipeline, finalText: text)

        XCTAssertEqual(pasted, [text])
        XCTAssertEqual(typed.text, "", "nothing is typed key by key")
    }

    // MARK: - opencode prompt relay (#719)

    /// Live Auto-Paste into an opencode pane that declared a prompt relay:
    /// the words are appended to its prompt while the dictation runs, and
    /// not one key is typed.
    func testLiveAutoPasteIntoAnOpencodePaneAppendsThroughItsRelay() async throws {
        let relay = try FakeOpencodePromptRelay()
        addTeardownBlock { relay.stop() }
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        joinOpencodePane(pipeline, relay: relay.relay(sessionID: "ses_a").address)
        let typed = recordTypedText(pipeline)

        await startAndSpeak(pipeline)
        sendPartials(pipeline)
        let appendedWhileDictating = await relay.waitForCalls(1)
        XCTAssertTrue(appendedWhileDictating)
        XCTAssertTrue(pipeline.viewModel.isDictating, "appended before the stop, not by it")

        await stopAndFinalize(pipeline)
        let phrase = Self.phrase
        let appendedAll = await relay.waitUntil { calls in
            calls.compactMap(\.text).joined() == phrase
        }
        XCTAssertTrue(appendedAll, "appended: \(relay.appendedText.debugDescription)")
        XCTAssertEqual(Set(relay.calls.map(\.path)), ["/tui/append-prompt"])
        XCTAssertEqual(Set(relay.calls.map(\.sessionID)), ["ses_a"])
        XCTAssertEqual(typed.text, "", "nothing is typed")
    }

    /// The spoken send trigger with the relay: focus moves to another app
    /// after the dictation starts, and the text still lands in the pane's
    /// prompt, submitted by the relay, with no Return pressed anywhere.
    func testLiveAutoPasteSendTriggerSubmitsThroughTheRelayWhereverFocusWent() async throws {
        let relay = try FakeOpencodePromptRelay()
        addTeardownBlock { relay.stop() }
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        pipeline.viewModel.settings.liveSpokenSendEnabled = true
        joinOpencodePane(pipeline, relay: relay.relay(sessionID: "ses_a").address)
        var returns: [pid_t] = []
        let typed = recordTypedText(pipeline, returnKeyPoster: { pid in
            returns.append(pid)
            return true
        })

        await startAndSpeak(pipeline)
        // The user switches to a browser mid-dictation.
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { "com.apple.Safari" }
        pipeline.server.send(["type": "transcription.delta", "delta": "run the tests, send"])
        pipeline.server.send(["type": "transcription.done", "text": "run the tests, send it."])
        let submitted = await relay.waitUntil { $0.last?.path == "/tui/submit-prompt" }
        XCTAssertTrue(submitted, "calls: \(relay.calls)")
        XCTAssertEqual(relay.appendedText, "run the tests")

        await stopAndFinalize(pipeline, finalText: "run the tests, send it.")
        XCTAssertEqual(relay.calls.filter { $0.path == "/tui/submit-prompt" }.count, 1)
        XCTAssertEqual(returns, [], "no Return key")
        XCTAssertEqual(typed.text, "")
    }

    /// Overlay Buffer with the relay: the committed text is appended once and
    /// the spoken trigger submits it.
    func testOverlayBufferCommitsOnceThroughTheRelayAndSubmits() async throws {
        let relay = try FakeOpencodePromptRelay()
        addTeardownBlock { relay.stop() }
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.settings.overlaySpokenSendEnabled = true
        pipeline.overlay.insertsThroughCommitter = true
        joinOpencodePane(pipeline, relay: relay.relay(sessionID: "ses_a").address)
        let typed = recordTypedText(pipeline)

        await startAndSpeak(pipeline)
        pipeline.server.send(["type": "transcription.delta", "delta": "run the tests, send it."])
        await stopAndFinalize(pipeline, finalText: "run the tests, send it.")

        let submitted = await relay.waitUntil { $0.last?.path == "/tui/submit-prompt" }
        XCTAssertTrue(submitted, "calls: \(relay.calls)")
        XCTAssertEqual(relay.calls.map(\.path), ["/tui/append-prompt", "/tui/submit-prompt"])
        XCTAssertEqual(relay.appendedText, "run the tests")
        XCTAssertEqual(pipeline.overlay.commitCallCount, 1)
        XCTAssertEqual(typed.text, "")
    }

    /// A relay that refuses the connection: the dictation types, as it
    /// would with no relay, and nothing is lost or doubled.
    func testLiveAutoPasteFallsBackToKeystrokesWhenTheRelayRefusesTheConnection() async throws {
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        let closedPort = try unusedLoopbackPort()
        joinOpencodePane(
            pipeline,
            relay: OpencodePromptRelayAddress(port: Int(closedPort), token: String(repeating: "5a", count: 32))
        )
        let typed = recordTypedText(pipeline)

        await startAndSpeak(pipeline)
        sendPartials(pipeline)
        await stopAndFinalize(pipeline)

        let typedAll = await typed.waitFor(Self.phrase)
        XCTAssertTrue(typedAll, "typed: \(typed.text.debugDescription)")
        XCTAssertFalse(pipeline.viewModel.textInsertion.promptRelayTakesText)
    }

    /// An opencode pane inside a local herdr, with no context join
    /// (polishing off): the focused TTY is herdr's client, so the relay is
    /// found through herdr's focused pane (#733), and the words go to it.
    func testLiveAutoPasteIntoAnOpencodePaneInHerdrAppendsThroughItsRelayWithoutAJoin() async throws {
        let relay = try FakeOpencodePromptRelay()
        addTeardownBlock { relay.stop() }
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2") { [(4242, "opencode")] })
        addTeardownBlock { herdr.stop() }
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        joinOpencodePane(pipeline, relay: relay.relay(sessionID: "ses_a").address, inHerdr: herdr)
        let typed = recordTypedText(pipeline)

        await startAndSpeak(pipeline)
        XCTAssertNil(pipeline.viewModel.context.claudeSessionJoin, "precondition: no context join")
        sendPartials(pipeline)
        await stopAndFinalize(pipeline)
        let phrase = Self.phrase
        let appendedAll = await relay.waitUntil { calls in
            calls.compactMap(\.text).joined() == phrase
        }
        XCTAssertTrue(appendedAll, "appended: \(relay.appendedText.debugDescription)")
        XCTAssertEqual(Set(relay.calls.map(\.sessionID)), ["ses_a"])
        XCTAssertEqual(herdr.writes, [], "herdr is asked, never written to")
        XCTAssertEqual(typed.text, "")
    }

    /// Joins the dictation to an opencode pane: a Ghostty pane whose TTY a
    /// fresh focus declaration names, with `relay` on it, in a registry the
    /// session's resolver reads.
    /// With `inHerdr`, the session runs in that herdr's pane `w1:p2` and the
    /// focused TTY is herdr's client's, which no session reported.
    private func joinOpencodePane(
        _ pipeline: Pipeline, relay: OpencodePromptRelayAddress, inHerdr herdr: FakeHerdrSocket? = nil
    ) {
        let tty = "/dev/ttys042"
        let opencodePID: Int32 = 4242
        let epoch = Date(timeIntervalSince1970: 3_000_000)
        let registry = ClaudeSessionRegistry(now: { epoch }, isProcessAlive: { _ in true })
        let origin = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
        let process = ClaudeHookProcessInfo(hookPID: opencodePID, claudePID: opencodePID, tty: tty)
        registry.ingest(
            ClaudeHookRecord(event: .sessionStart, agent: .opencode, sessionID: "ses_a", timestamp: 0,
                             process: ClaudeHookProcessInfo(
                                 hookPID: opencodePID, claudePID: opencodePID,
                                 herdrPaneID: herdr.map { _ in "w1:p2" }, herdrSocketPath: herdr?.socketPath
                             )),
            origin: origin
        )
        XCTAssertNotNil(registry.ingest(
            ClaudeHookRecord(event: .focusChanged, agent: .opencode, sessionID: "ses_a", timestamp: 0,
                             process: process, promptRelay: relay),
            origin: origin
        ))
        let client = HerdrSocketClient(timeout: 2)
        pipeline.viewModel.context.claudeSessionJoinResolver = ClaudeSessionJoinResolver(
            registry: registry,
            focusedTerminalTTY: { _ in herdr == nil ? tty : "/dev/ttys-herdr-client" },
            herdrClientProbe: { _ in herdr != nil },
            herdrPanes: herdr == nil ? nil : client
        )
        let ghostty = TerminalScreenAllowlist.ghosttyBundleID
        TerminalScreenContextSource.debugFrontmostTargetOverride = {
            TerminalScreenTarget(pid: 4343, bundleID: ghostty)
        }
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { ghostty }
        TerminalTargetDetector.debugSecureEventInputOverride = { false }
        addTeardownBlock { @MainActor in
            TerminalScreenContextSource.debugFrontmostTargetOverride = nil
            TerminalTargetDetector.debugFrontmostBundleIDOverride = nil
            TerminalTargetDetector.debugSecureEventInputOverride = nil
        }
    }

    // MARK: - herdr pane route (#726)

    /// Live Auto-Paste into a Claude Code pane in herdr: the join resolves
    /// the pane over herdr's socket, and the words go into it through that
    /// same socket while the dictation runs. Not one key is typed.
    func testLiveAutoPasteIntoAJoinedHerdrPaneSendsThroughItsSocket() async throws {
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2") { [(9001, "claude")] })
        addTeardownBlock { herdr.stop() }
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        joinHerdrPane(pipeline, herdr: herdr)
        let typed = recordTypedText(pipeline)

        await startAndSpeak(pipeline)
        XCTAssertEqual(pipeline.viewModel.context.claudeSessionJoin?.mechanism, .herdrPane, "precondition")
        sendPartials(pipeline)
        let sentWhileDictating = await herdr.waitUntil { $0.contains { $0.method == "pane.send_text" } }
        XCTAssertTrue(sentWhileDictating)
        XCTAssertTrue(pipeline.viewModel.isDictating, "sent before the stop, not by it")

        await stopAndFinalize(pipeline)
        let phrase = Self.phrase
        let sentAll = await herdr.waitUntil { requests in
            requests.filter { $0.method == "pane.send_text" }.compactMap(\.text).joined() == phrase
        }
        XCTAssertTrue(sentAll, "sent: \(herdr.sentText.debugDescription)")
        XCTAssertEqual(Set(herdr.writes.map(\.method)), ["pane.send_text"])
        XCTAssertEqual(Set(herdr.writes.map(\.paneID)), ["w1:p2"])
        XCTAssertFalse(herdr.requests.contains { $0.method == "pane.run" })
        XCTAssertEqual(typed.text, "", "nothing is typed")
    }

    /// The spoken send trigger into a herdr pane: focus moves to another app
    /// after the dictation starts; the text still lands in the pane, and the
    /// Enter goes to that pane through the socket, with no Return key.
    func testLiveAutoPasteSendTriggerPressesEnterInTheHerdrPaneWhereverFocusWent() async throws {
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2") { [(9001, "claude")] })
        addTeardownBlock { herdr.stop() }
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        pipeline.viewModel.settings.liveSpokenSendEnabled = true
        joinHerdrPane(pipeline, herdr: herdr)
        var returns: [pid_t] = []
        let typed = recordTypedText(pipeline, returnKeyPoster: { pid in
            returns.append(pid)
            return true
        })

        await startAndSpeak(pipeline)
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { "com.apple.Safari" }
        pipeline.server.send(["type": "transcription.delta", "delta": "run the tests, send"])
        pipeline.server.send(["type": "transcription.done", "text": "run the tests, send it."])
        let submitted = await herdr.waitUntil { $0.last?.method == "pane.send_keys" }
        XCTAssertTrue(submitted, "requests: \(herdr.requests)")
        XCTAssertEqual(herdr.sentText, "run the tests")

        await stopAndFinalize(pipeline, finalText: "run the tests, send it.")
        XCTAssertEqual(herdr.writes.filter { $0.method == "pane.send_keys" }.map(\.keys), [["enter"]])
        XCTAssertEqual(returns, [], "no Return key")
        XCTAssertEqual(typed.text, "")
    }

    /// Overlay Buffer into a herdr pane: the committed text is sent once and
    /// the spoken trigger presses Enter in the pane after it.
    func testOverlayBufferCommitsOnceIntoTheHerdrPaneAndSubmits() async throws {
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2") { [(9001, "claude")] })
        addTeardownBlock { herdr.stop() }
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.settings.overlaySpokenSendEnabled = true
        pipeline.overlay.insertsThroughCommitter = true
        joinHerdrPane(pipeline, herdr: herdr)
        let typed = recordTypedText(pipeline)

        await startAndSpeak(pipeline)
        pipeline.server.send(["type": "transcription.delta", "delta": "run the tests, send it."])
        await stopAndFinalize(pipeline, finalText: "run the tests, send it.")

        let submitted = await herdr.waitUntil { $0.last?.method == "pane.send_keys" }
        XCTAssertTrue(submitted, "requests: \(herdr.requests)")
        XCTAssertEqual(herdr.writes, [
            .init(method: "pane.send_text", paneID: "w1:p2", text: "run the tests", keys: nil),
            .init(method: "pane.send_keys", paneID: "w1:p2", text: nil, keys: ["enter"]),
        ])
        XCTAssertEqual(pipeline.overlay.commitCallCount, 1)
        XCTAssertEqual(typed.text, "")
    }

    /// herdr refuses the write while its pane is in front: the dictation
    /// types, as it would with no route, and nothing is lost or doubled.
    func testLiveAutoPasteFallsBackToKeystrokesWhenHerdrRefusesTheWrite() async throws {
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2", foreground: { [(9001, "claude")] }) { _ in
            .error("pane_send_failed")
        })
        addTeardownBlock { herdr.stop() }
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        joinHerdrPane(pipeline, herdr: herdr)
        let typed = recordTypedText(pipeline)

        await startAndSpeak(pipeline)
        sendPartials(pipeline)
        await stopAndFinalize(pipeline)

        let typedAll = await typed.waitFor(Self.phrase)
        XCTAssertTrue(typedAll, "typed: \(typed.text.debugDescription)")
        XCTAssertFalse(pipeline.viewModel.textInsertion.promptRelayTakesText)
        XCTAssertEqual(herdr.writes.count, 1, "the first refusal ends the route")
    }

    /// Joins the dictation to a Claude Code session in herdr pane `w1:p2`
    /// the way the app does: polishing on (a fake polisher, so nothing leaves
    /// the process) with screen context, a Ghostty surface bound to a herdr
    /// client, and a real `HerdrSocketClient` reading and writing `herdr`.
    private func joinHerdrPane(_ pipeline: Pipeline, herdr: FakeHerdrSocket) {
        let settings = pipeline.viewModel.settings
        settings.llmPolishingEnabled = true
        settings.llmPolishingEndpointURL = "http://127.0.0.1:8080/v1/chat/completions"
        settings.terminalScreenContextEnabled = true
        pipeline.viewModel.llmPolishingService = FakePolishingService()
        let epoch = Date(timeIntervalSince1970: 3_000_000)
        let registry = ClaudeSessionRegistry(now: { epoch }, isProcessAlive: { _ in true })
        XCTAssertNotNil(registry.ingest(
            ClaudeHookRecord(
                event: .sessionStart, sessionID: "s1", timestamp: 0, rawCwd: "/repo", prompt: nil, files: [],
                process: ClaudeHookProcessInfo(
                    hookPID: 777, claudePID: 9001, tty: "/dev/ttys-inner",
                    herdrPaneID: "w1:p2", herdrSocketPath: herdr.socketPath
                )
            ),
            origin: .localAuthenticated(peerUID: 501)
        ))
        let client = HerdrSocketClient(timeout: 2)
        pipeline.viewModel.context.claudeSessionJoinResolver = ClaudeSessionJoinResolver(
            registry: registry,
            focusedTerminalTTY: { _ in "/dev/ttys-outer" },
            herdrClientProbe: { _ in true },
            herdrPanes: client,
            herdrPaneWriter: client
        )
        let ghostty = TerminalScreenAllowlist.ghosttyBundleID
        TerminalScreenContextSource.debugFrontmostTargetOverride = {
            TerminalScreenTarget(pid: 4343, bundleID: ghostty)
        }
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { ghostty }
        TerminalTargetDetector.debugSecureEventInputOverride = { false }
        addTeardownBlock { @MainActor in
            TerminalScreenContextSource.debugFrontmostTargetOverride = nil
            TerminalTargetDetector.debugFrontmostBundleIDOverride = nil
            TerminalTargetDetector.debugSecureEventInputOverride = nil
        }
    }

    /// Records every key the dictation would type.
    private func recordTypedText(
        _ pipeline: Pipeline, returnKeyPoster: ((pid_t) -> Bool)? = nil
    ) -> TypedText {
        let typed = TypedText()
        pipeline.viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        pipeline.viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { chunk in
                typed.append(chunk)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false },
            returnKeyPoster: returnKeyPoster ?? { _ in false },
            frontmostPIDReader: { 4343 },
            commandVPaster: { text in
                typed.append(text)
                return true
            }
        )
        return typed
    }

    // MARK: - The two halves every scenario shares

    /// Start, connect, open the microphone, and get one captured chunk to the
    /// server through the chunk buffer and the send loop.
    private func startAndSpeak(
        _ pipeline: Pipeline,
        start: ((DictationViewModel) -> Void)? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        if let start { start(pipeline.viewModel) } else { pipeline.viewModel.startDictation() }
        await pipeline.microphone.waitUntilCapturing(file: file, line: line)
        XCTAssertTrue(pipeline.viewModel.isDictating, file: file, line: line)
        XCTAssertEqual(pipeline.viewModel.statusText, "Listening...", file: file, line: line)

        let update = await pipeline.server.awaitFrame("session.update", file: file, line: line) {
            $0.type == "session.update"
        }
        XCTAssertEqual(update?.json["model"] as? String, Self.model, file: file, line: line)

        let spoken = Self.speech(seed: 1)
        XCTAssertTrue(pipeline.microphone.deliver(spoken), file: file, line: line)
        // The send loop and the periodic commit sleep on the clock. One send
        // interval later the loop drains what the capture buffered.
        await pipeline.clock.waitForSleepers(2, file: file, line: line)
        pipeline.clock.advance(by: TimingConstants.audioSendInterval)
        await pipeline.server.awaitFrame("the captured audio", file: file, line: line) {
            $0.audio == spoken
        }
    }

    /// The transcript arrives as partials, split mid-phrase the way a
    /// streaming model splits it.
    private func sendPartials(_ pipeline: Pipeline) {
        let split = Self.phrase.index(Self.phrase.startIndex, offsetBy: 18)
        pipeline.server.send(["type": "transcription.delta", "delta": String(Self.phrase[..<split])])
        pipeline.server.send(["type": "transcription.delta", "delta": String(Self.phrase[split...])])
    }

    /// Stop with audio still in the buffer, then play the server's side of
    /// the finalization: the final commit is answered with the full text,
    /// the client closes, and the session commits and records.
    private func stopAndFinalize(
        _ pipeline: Pipeline, finalText: String = DictationPipelineTests.phrase,
        finalStatus: String = DictationViewModel.StatusStrings.ready,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let viewModel = pipeline.viewModel
        let unsent = Self.speech(seed: 2)
        XCTAssertTrue(pipeline.microphone.deliver(unsent), file: file, line: line)

        viewModel.stopDictation(reason: "test")
        XCTAssertFalse(
            pipeline.microphone.deliver(Self.speech(seed: 3)),
            "the microphone is off once the stop returns", file: file, line: line
        )
        XCTAssertTrue(viewModel.isFinalizingStop, file: file, line: line)

        await pipeline.server.awaitFrame("the final commit", file: file, line: line) {
            $0.isFinalCommit
        }
        let frames = pipeline.server.frames
        let flushed = frames.firstIndex { $0.audio == unsent }
        let finalCommit = frames.firstIndex { $0.isFinalCommit }
        XCTAssertNotNil(flushed, "the stop sends the audio the loop had not drained", file: file, line: line)
        if let flushed, let finalCommit {
            XCTAssertLessThan(flushed, finalCommit, "and sends it ahead of the final commit", file: file, line: line)
        }

        pipeline.server.send(["type": "transcription.done", "text": finalText])
        let recorded = await pipeline.records.written.value(failAfter: 10)
        XCTAssertTrue(recorded, "the session never finished and wrote its record", file: file, line: line)
        await pipeline.server.awaitClose(file: file, line: line)

        XCTAssertFalse(viewModel.isFinalizingStop, file: file, line: line)
        XCTAssertFalse(viewModel.isDictating, file: file, line: line)
        XCTAssertEqual(viewModel.statusText, finalStatus, file: file, line: line)
        XCTAssertNil(viewModel.lastError, file: file, line: line)
        XCTAssertTrue(pipeline.presenter.presented.isEmpty, file: file, line: line)
    }

    // MARK: - Harness

    private struct Pipeline {
        let viewModel: DictationViewModel
        let server: FakeRealtimeServer
        let microphone: FakeMicrophoneCaptureService
        let clock: ManualSessionClock
        let overlay: MockOverlayCoordinator
        let presenter: RecordingConnectionFailurePresenter
        let records: SessionRecords
    }

    private func makePipeline(outputMode: DictationOutputMode) async throws -> Pipeline {
        let server = try FakeRealtimeServer()
        addTeardownBlock { server.stop() }
        let endpoint = try await server.start()

        let settings = makeSettings(outputMode: outputMode)
        settings.dictationBackendMode = .externalURL
        settings.polishingBackendMode = .externalURL
        settings.realtimeProvider = .realtimeAPI
        settings.realtimeAPIEndpointURL = endpoint.absoluteString
        settings.realtimeAPIModelName = Self.model
        // As in the e2e check: the inserted text is the transcript.
        settings.llmPolishingEnabled = false
        settings.audioDuckingEnabled = false
        settings.overlayBufferSilenceAutoStop = .off

        let clock = ManualSessionClock()
        let microphone = FakeMicrophoneCaptureService()
        let overlay = MockOverlayCoordinator()
        let presenter = RecordingConnectionFailurePresenter()
        let records = SessionRecords()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: overlay,
            startRuntimeServices: false,
            dependencies: DictationViewModel.Dependencies(
                microphone: { microphone },
                connectionFailurePresenter: presenter,
                onSessionRecord: { records.append($0) },
                clock: clock.clock
            )
        )
        viewModel.appConfigStore = MockAppConfigStore()
        retainForTestProcessLifetime(viewModel)
        // The session start arms Escape as a cancel key; keep it off the
        // host's global hotkeys.
        EscapeCancelHandler.debugConfigureRegistration(status: noErr)
        addTeardownBlock { @MainActor in EscapeCancelHandler.debugConfigureRegistration(status: nil) }

        return Pipeline(
            viewModel: viewModel,
            server: server,
            microphone: microphone,
            clock: clock,
            overlay: overlay,
            presenter: presenter,
            records: records
        )
    }

    /// 100 ms of 16 kHz mono PCM16, different for each seed, so a frame on
    /// the wire names the chunk it carried.
    private static func speech(seed: UInt8) -> Data {
        Data((0..<3_200).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) })
    }
}

/// What the insertion hooks would have typed, in order.
@MainActor
private final class TypedText {
    private(set) var chunks: [String] = []
    private var watches: [(expected: String, wait: BoundedWait)] = []

    var text: String { chunks.joined() }

    func append(_ chunk: String) {
        chunks.append(chunk)
        for watch in watches where watch.expected == text {
            watch.wait.resolve()
        }
    }

    /// True once everything typed reads `expected`; false if it does not
    /// within `failAfter` seconds of wall time.
    func waitFor(_ expected: String, failAfter: TimeInterval = 10) async -> Bool {
        if text == expected { return true }
        let wait = BoundedWait()
        watches.append((expected, wait))
        return await wait.value(failAfter: failAfter)
    }
}

/// What the quick capture sink received, with the records written by then.
private final class QuickCaptures {
    var all: [(text: String, recordsWritten: Int)] = []
}

/// Every record a session wrote; `written` resolves on the first.
@MainActor
private final class SessionRecords {
    private(set) var all: [DictationSessionRecord] = []
    let written = BoundedWait()

    func append(_ record: DictationSessionRecord) {
        all.append(record)
        written.resolve()
    }
}
#endif
