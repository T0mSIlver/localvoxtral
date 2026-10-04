import ClaudeContextWire
import Foundation
import localvoxtralTestSupport
import Synchronization
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
        XCTAssertEqual(pipeline.records.all.first?.commitSucceeded, true)
        XCTAssertEqual(pipeline.overlay.commitCallCount, 0)
    }

    /// The field stops taking keystrokes before the last segment lands: the
    /// stop says so and History saves the dictation as not inserted (#1176).
    func testLiveAutoPasteWhoseLastTextFailedToInsertIsSavedAsNotInserted() async throws {
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        let typed = TypedText()
        var fieldAccepts = true
        let refused = BoundedWait()
        pipeline.viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        pipeline.viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { chunk in
                guard fieldAccepts else {
                    refused.resolve()
                    return false
                }
                typed.append(chunk)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false }
        )

        await startAndSpeak(pipeline)
        pipeline.server.send(["type": "transcription.delta", "delta": "First part"])
        pipeline.server.send(["type": "transcription.done", "text": "First part."])
        let typedFirst = await typed.waitFor("First part.")
        XCTAssertTrue(typedFirst, "typed so far: \(typed.text.debugDescription)")
        fieldAccepts = false
        pipeline.server.send(["type": "transcription.done", "text": " Second part."])
        let attempted = await refused.value(failAfter: 10)
        XCTAssertTrue(attempted, "the second segment was never offered to the field")
        XCTAssertTrue(pipeline.viewModel.textInsertion.hasPendingInsertionText)

        await stopAndFinalize(
            pipeline, finalText: "",
            expectedError: "Some realtime text could not be inserted into the focused app."
        )

        XCTAssertEqual(typed.text, "First part.")
        XCTAssertEqual(pipeline.records.all.map(\.rawText), ["First part. Second part."])
        XCTAssertEqual(pipeline.records.all.first?.commitSucceeded, false)
    }

    /// Secure Keyboard Entry turns on mid-dictation: macOS swallows the keys
    /// while posting them reports success, so the words after it are not
    /// typed, and the stop saves the dictation as not inserted.
    func testSecureInputTurnedOnMidLiveAutoPasteKeepsTheTextNotInserted() async throws {
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        addTeardownBlock { TerminalTargetDetector.debugSecureEventInputOverride = nil }
        let typed = TypedText()
        var secureInput = false
        let offered = BoundedWait()
        pipeline.viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        pipeline.viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { chunk in
                guard !secureInput else {
                    offered.resolve()
                    return true
                }
                typed.append(chunk)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in
                offered.resolve()
                return false
            }
        )

        await startAndSpeak(pipeline)
        pipeline.server.send(["type": "transcription.delta", "delta": "First part"])
        pipeline.server.send(["type": "transcription.done", "text": "First part."])
        let typedFirst = await typed.waitFor("First part.")
        XCTAssertTrue(typedFirst, "typed so far: \(typed.text.debugDescription)")
        secureInput = true
        TerminalTargetDetector.debugSecureEventInputOverride = { true }
        pipeline.server.send(["type": "transcription.done", "text": " Second part."])
        let attempted = await offered.value(failAfter: 10)
        XCTAssertTrue(attempted, "the second segment was never offered to the field")

        await stopAndFinalize(
            pipeline, finalText: "",
            expectedError: "Some realtime text could not be inserted into the focused app."
        )

        XCTAssertEqual(typed.text, "First part.")
        XCTAssertEqual(pipeline.records.all.first?.commitSucceeded, false)
    }

    /// A cancel while the stream still holds the last word back (a speaker
    /// term gives it rules) types nothing more (#1222).
    func testACancelTypesNothingTheLiveStreamStillHolds() async throws {
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        pipeline.viewModel.settings.polishSpeakerTerms = ["macOS"]
        let typed = recordTypedText(pipeline)

        await startAndSpeak(pipeline)
        pipeline.server.send(["type": "transcription.delta", "delta": "hello there"])
        let typedHello = await typed.waitFor("hello ")
        XCTAssertTrue(typedHello, "typed so far: \(typed.text.debugDescription)")

        pipeline.viewModel.cancelDictation()

        XCTAssertFalse(pipeline.viewModel.isDictating)
        XCTAssertFalse(pipeline.viewModel.isFinalizingStop)
        XCTAssertEqual(typed.text, "hello ", "the held word is not typed by the cancel")
    }

    /// A later segment's first delta keeps its leading space, and its period
    /// arrives only in the final: the period is still typed (#1091).
    func testLiveAutoPasteTypesALaterSegmentsFinalOnlyPeriod() async throws {
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
        pipeline.server.send(["type": "transcription.delta", "delta": "First part"])
        pipeline.server.send(["type": "transcription.done", "text": "First part."])
        pipeline.server.send(["type": "transcription.delta", "delta": " Second"])
        pipeline.server.send(["type": "transcription.delta", "delta": " part"])
        pipeline.server.send(["type": "transcription.done", "text": " Second part."])
        let typedWhileDictating = await typed.waitFor("First part. Second part.")
        XCTAssertTrue(typedWhileDictating, "typed so far: \(typed.text.debugDescription)")

        await stopAndFinalize(pipeline, finalText: "")

        XCTAssertEqual(typed.text, "First part. Second part.")
        XCTAssertEqual(pipeline.records.all.map(\.rawText), ["First part. Second part."])
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
        XCTAssertFalse(pipeline.viewModel.session.escapeCancelHandler.debugIsRegistered, "the commit releases Escape")
    }

    /// The Mac sleeps mid-dictation while the bundled helper still holds the
    /// last words in its decoder. The sleep stop sends the final commit and
    /// takes its answer before the socket closes, so History holds the whole
    /// dictation (#1584).
    func testSleepFinalizesTheDictationBeforeTheSocketCloses() async throws {
        let workspace = NotificationCenter()
        let pipeline = try await makePipeline(outputMode: .overlayBuffer, workspaceCenter: workspace)
        let head = "hello from localvoxtral."

        await startAndSpeak(pipeline)
        pipeline.server.send(["type": "transcription.delta", "delta": head])
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)

        let finalCommit = await pipeline.server.awaitFrame("the final commit") { $0.isFinalCommit }
        XCTAssertNotNil(finalCommit, "the sleep stop asks the helper for its tail")
        pipeline.server.send(["type": "transcription.done", "text": Self.phrase])
        let recorded = await pipeline.records.waitForCount(1)

        XCTAssertTrue(recorded)
        XCTAssertEqual(pipeline.records.all.map(\.rawText), [Self.phrase])
        XCTAssertFalse(pipeline.viewModel.isDictating)
    }

    /// The sleep stop waits for the helper's answer for a short bound only:
    /// macOS promises no time before it suspends the process (#1584).
    func testSleepFinalizationGivesUpAfterItsShortBound() async throws {
        let workspace = NotificationCenter()
        let pipeline = try await makePipeline(outputMode: .overlayBuffer, workspaceCenter: workspace)
        let head = "hello from localvoxtral."
        let shown = BoundedWait()
        pipeline.overlay.onRefresh = { if $0.displayText == head { shown.resolve() } }

        await startAndSpeak(pipeline)
        pipeline.server.send(["type": "transcription.delta", "delta": head])
        let arrived = await shown.value(failAfter: 10)
        XCTAssertTrue(arrived)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        await pipeline.server.awaitFrame("the final commit") { $0.isFinalCommit }
        // The socket's keepalive, the stop's watchdog and its finalization
        // loop. The helper never answers.
        await pipeline.clock.waitForSleepers(3)
        pipeline.clock.advance(by: TimingConstants.sleepStopFinalizationTimeout)
        let recorded = await pipeline.records.waitForCount(1)

        XCTAssertTrue(recorded)
        XCTAssertEqual(pipeline.records.all.map(\.rawText), [head])
        XCTAssertFalse(pipeline.viewModel.isFinalizingStop)
    }

    /// The Mac loses its network while dictating to a speech server on
    /// loopback, as the bundled one is: the socket is unaffected, so the
    /// dictation keeps listening and its stop still sends the final commit
    /// that flushes the server's tail.
    func testNetworkLossKeepsALoopbackDictationAndItsFinalCommit() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)

        await startAndSpeak(pipeline)
        pipeline.viewModel.session.handleNetworkChange(connected: false)

        XCTAssertTrue(pipeline.viewModel.isDictating, "a loopback socket outlives the network")
        XCTAssertEqual(pipeline.viewModel.statusText, "Listening...")
        XCTAssertNil(pipeline.viewModel.lastError)

        await stopAndFinalize(pipeline)

        XCTAssertEqual(pipeline.server.frames.filter(\.isFinalCommit).count, 1)
        XCTAssertEqual(pipeline.overlay.committedTexts, [Self.phrase])
    }

    /// Without a network, a dictation to a loopback speech server needs none:
    /// the idle status does not report the loss, and the start goes ahead.
    func testWithoutANetworkADictationToALoopbackServerStarts() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        let idleStatus = pipeline.viewModel.statusText
        reportNetworkLoss(pipeline)

        XCTAssertEqual(pipeline.viewModel.statusText, idleStatus)

        await startAndSpeak(pipeline)
        await stopAndFinalize(pipeline)

        XCTAssertEqual(pipeline.overlay.committedTexts, [Self.phrase])
    }

    /// Without a network, a dictation to a server on another host is still
    /// refused before the microphone opens.
    func testWithoutANetworkADictationToARemoteServerIsRefused() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.settings.realtimeAPIEndpointURL = "ws://192.0.2.1:8000/v1/realtime"
        reportNetworkLoss(pipeline)

        XCTAssertEqual(pipeline.viewModel.statusText, DictationViewModel.StatusStrings.noNetworkConnection)

        pipeline.viewModel.startDictation()

        XCTAssertFalse(pipeline.viewModel.isDictating)
        XCTAssertFalse(pipeline.viewModel.session.isConnectingRealtimeSession)
        XCTAssertEqual(pipeline.viewModel.statusText, DictationViewModel.StatusStrings.noNetworkConnection)
        XCTAssertEqual(pipeline.viewModel.lastError, "Connect to a network before starting dictation.")
        XCTAssertFalse(pipeline.microphone.deliver(Self.speech(seed: 1)), "the microphone stays off")
    }

    /// The path goes unsatisfied, handled in line rather than through the
    /// monitor's hop to the main actor.
    private func reportNetworkLoss(_ pipeline: Pipeline) {
        let monitor = pipeline.viewModel.session.networkMonitor
        monitor.onChange = nil
        monitor.debugReportPath(connected: false)
        pipeline.viewModel.session.handleNetworkChange(connected: false)
    }

    /// #1317, #1423: the start cancels a voice memo streaming through the
    /// engine, so the stop keeps its usual rules: a final that never comes is
    /// given up on once the stream has been idle, long before the 7 s limit.
    func testADictationStartedDuringAVoiceMemoCancelsItAndStopsOnTheIdleRule() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        var yields = 0
        pipeline.viewModel.session.yieldVoiceMemoEngine = { yields += 1 }

        await startAndSpeak(pipeline)
        XCTAssertEqual(yields, 1)

        pipeline.viewModel.stopDictation(reason: "test")
        await pipeline.server.awaitFrame("the final commit") { $0.isFinalCommit }
        // The stop's two polls: the finalization and its watchdog.
        await pipeline.clock.waitForSleepers(2)
        XCTAssertTrue(pipeline.viewModel.isFinalizingStop)

        pipeline.clock.advance(by: TimingConstants.finalizationMinimumOpen + TimingConstants.finalizationPollInterval)
        await pipeline.server.awaitClose()

        XCTAssertFalse(pipeline.viewModel.isFinalizingStop, "closed on the idle rule")
        XCTAssertEqual(yields, 1, "only the start yields")
        // This backend has sent no final: the idle rule is its normal end (#1659).
        XCTAssertEqual(pipeline.viewModel.statusText, DictationViewModel.StatusStrings.ready)
    }

    /// A settled sentence past 30 words, the first piece early polish takes.
    private static let settledPiece =
        "the first part of this dictation is long enough to settle into a piece of its own "
        + "because it has more than thirty words in it and ends right here."
    private static let tail = "and this is the tail."

    /// Overlay Buffer with polishing (#709): a settled piece is polished
    /// while the user still speaks, and the stop polishes only the tail.
    func testOverlayBufferPolishesTheSettledPieceWhileDictatingAndOnlyTheTailAtStop() async throws {
        let polish = FakePolishingService { "<\($0.inputText)>" }
        let pipeline = try await makePipeline(outputMode: .overlayBuffer, polish: polish)

        await startAndSpeak(pipeline)
        pipeline.server.send(["type": "transcription.done", "text": Self.settledPiece])
        let pieceSent = await waitForPolishRequests(polish, 1)
        XCTAssertTrue(pieceSent, "no piece was polished while dictating")
        XCTAssertTrue(pipeline.viewModel.isDictating, "polished before the stop, not by it")

        await stopAndFinalize(pipeline, finalText: Self.tail)

        let inputs = await polish.requests.map(\.inputText)
        XCTAssertEqual(inputs, [Self.settledPiece, Self.tail])
        XCTAssertEqual(pipeline.overlay.committedTexts, ["<\(Self.settledPiece)> <\(Self.tail)>"])
        XCTAssertEqual(pipeline.records.all.map(\.rawText), ["\(Self.settledPiece) \(Self.tail)"])
        XCTAssertEqual(pipeline.records.all.first?.polishedText, "<\(Self.settledPiece)> <\(Self.tail)>")
    }

    /// A stop that skips finalization (network lost, a new microphone,
    /// sleep) pins the commit target at the stop, as a finalizing stop does:
    /// focus that moves while the polish runs does not take the text (#1478).
    /// Against the real overlay coordinator, which owns the target.
    func testAStopWithoutFinalizationCommitsIntoTheAppFocusedAtTheStop() async throws {
        let focus = MockOverlayAnchorResolver()
        focus.focusedPID = 4242
        let renderer = MockOverlayRenderer()
        let overlay = OverlayBufferSessionCoordinator(
            stateMachine: OverlayBufferStateMachine(),
            renderer: renderer,
            anchorResolver: focus,
            now: { Date(timeIntervalSince1970: 0) },
            sleepFor: { _ in },
            copyToPasteboard: { _ in true }
        )
        let polish = FakePolishingService()
        let pipeline = try await makePipeline(
            outputMode: .overlayBuffer, polish: polish, earlyPolish: false, overlayCoordinator: overlay
        )
        TerminalTargetDetector.debugSecureEventInputOverride = { false }
        addTeardownBlock { TerminalTargetDetector.debugSecureEventInputOverride = nil }
        var inserted: [(text: String, pid: pid_t?)] = []
        pipeline.viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        pipeline.viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { _ in false },
            modifierStateReader: { false },
            // The keyboard path needs a real app to activate: the text lands
            // through Accessibility, which reports the pid it targeted.
            accessibilityInserter: { text, pid in
                inserted.append((text, pid))
                return true
            },
            returnKeyPoster: { _ in false },
            frontmostPIDReader: { focus.focusedPID },
            commandVPaster: { _ in false }
        )
        let shown = BoundedWait()
        renderer.onRender = { if $0?.bufferText == Self.phrase { shown.resolve() } }

        await startAndSpeak(pipeline)
        sendPartials(pipeline)
        let shownWhileDictating = await shown.value(failAfter: 10)
        XCTAssertTrue(shownWhileDictating)
        renderer.onRender = nil
        await polish.holdNextRequest()
        pipeline.viewModel.stopDictation(reason: "network lost", finalizeRemainingAudio: false)
        let polishing = await waitForPolishRequests(polish, 1)
        XCTAssertTrue(polishing)
        focus.focusedPID = 5151
        await polish.releaseHeldRequest()
        await awaitStoppedSessionCommit(pipeline.viewModel)

        XCTAssertEqual(inserted.map(\.text), [Self.phrase])
        XCTAssertEqual(inserted.map(\.pid), [4242], "the app focused at the stop")
    }

    /// A new microphone restarts the dictation while the stopped text still
    /// waits on its polish: that text is saved as not inserted, and the next
    /// dictation's stop commits (#1055).
    func testAMicrophoneChangeSavesTheTextStillPolishingAndLaterStopsCommit() async throws {
        let polish = FakePolishingService { "<\($0.inputText)>" }
        let pipeline = try await makePipeline(outputMode: .overlayBuffer, polish: polish, earlyPolish: false)
        let builtIn = MicrophoneInputDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", channelCount: 1)
        let usb = MicrophoneInputDevice(id: "AppleUSBAudioEngine:Rode:NT-USB:1", name: "NT-USB", channelCount: 1)
        pipeline.microphone.configureDevices([builtIn, usb], defaultInputDeviceID: builtIn.id)
        let shown = BoundedWait()
        pipeline.overlay.onRefresh = { call in
            if call.displayText == Self.phrase { shown.resolve() }
        }

        await startAndSpeak(pipeline)
        sendPartials(pipeline)
        let shownWhileDictating = await shown.value(failAfter: 10)
        XCTAssertTrue(shownWhileDictating)
        pipeline.overlay.onRefresh = nil
        pipeline.server.forgetFrames()
        await startAndSpeak(pipeline, start: { $0.selectMicrophoneInput(id: usb.id) })

        XCTAssertEqual(pipeline.records.all.map(\.rawText), [Self.phrase], "the old text is in History")
        XCTAssertEqual(pipeline.records.all.first?.commitSucceeded, false)
        XCTAssertEqual(pipeline.overlay.committedTexts, [])

        await stopAndFinalize(pipeline)
        XCTAssertEqual(pipeline.overlay.committedTexts, ["<\(Self.phrase)>"], "the new dictation commits")
    }

    /// A cancel while the stopped text waits on its polish: nothing is
    /// inserted when the reply comes, and History keeps the text (#1059).
    func testACancelDuringThePolishInsertsNothing() async throws {
        let polish = FakePolishingService { "<\($0.inputText)>" }
        let pipeline = try await makePipeline(outputMode: .overlayBuffer, polish: polish, earlyPolish: false)
        await polish.holdNextRequest()

        await startAndSpeak(pipeline)
        pipeline.viewModel.stopDictation(reason: "test")
        await pipeline.server.awaitFrame("the final commit") { $0.isFinalCommit }
        pipeline.server.send(["type": "transcription.done", "text": Self.phrase])
        let polishing = await waitForPolishRequests(polish, 1)
        XCTAssertTrue(polishing, "the polish never started")

        pipeline.viewModel.cancelDictation()
        await polish.releaseHeldRequest()
        let recorded = await pipeline.records.waitForCount(1)
        XCTAssertTrue(recorded)
        await pipeline.viewModel.session.polishAndCommitTask?.value

        XCTAssertEqual(pipeline.overlay.commitCallCount, 0, "nothing is inserted after a cancel")
        XCTAssertEqual(pipeline.records.all.map(\.rawText), [Self.phrase])
        XCTAssertEqual(pipeline.records.all.first?.commitSucceeded, false)
        XCTAssertFalse(pipeline.viewModel.isFinalizingStop)
    }

    /// Escape while the stopped text waits on its polish cancels the commit,
    /// as it does while recording, and is released once the stop is done
    /// (#1221).
    func testEscapeDuringThePolishInsertsNothing() async throws {
        let polish = FakePolishingService { "<\($0.inputText)>" }
        let pipeline = try await makePipeline(outputMode: .overlayBuffer, polish: polish, earlyPolish: false)
        await polish.holdNextRequest()
        let escape = pipeline.viewModel.session.escapeCancelHandler

        await startAndSpeak(pipeline)
        pipeline.viewModel.stopDictation(reason: "test")
        await pipeline.server.awaitFrame("the final commit") { $0.isFinalCommit }
        pipeline.server.send(["type": "transcription.done", "text": Self.phrase])
        let polishing = await waitForPolishRequests(polish, 1)
        XCTAssertTrue(polishing, "the polish never started")

        escape.debugPressEscape()
        await polish.releaseHeldRequest()
        let recorded = await pipeline.records.waitForCount(1)
        XCTAssertTrue(recorded)
        await pipeline.viewModel.session.polishAndCommitTask?.value

        XCTAssertEqual(pipeline.overlay.commitCallCount, 0, "nothing is inserted after Escape")
        XCTAssertEqual(pipeline.records.all.first?.commitSucceeded, false)
        XCTAssertFalse(escape.debugIsRegistered, "Escape goes back to the focused app")
    }

    /// A start cancelled while its context capture still waits on the focused
    /// app, then a dictation that connects before that read returns: the late
    /// read leaves the new dictation's connection and join alone, and its
    /// words commit.
    func testACancelledStartsLateContextCaptureLeavesTheNextDictationAlone() async throws {
        let polish = FakePolishingService { $0.inputText }
        let pipeline = try await makePipeline(outputMode: .overlayBuffer, polish: polish, earlyPolish: false)
        let viewModel = pipeline.viewModel
        viewModel.settings.claudeRepoContextEnabled = true
        viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        let desktop = TerminalScreenTarget(pid: 6060, bundleID: ClaudeDesktopAllowlist.bundleID)
        TerminalScreenContextSource.debugFrontmostTargetOverride = { desktop }
        addTeardownBlock { @MainActor in
            TerminalScreenContextSource.debugFrontmostTargetOverride = nil
            viewModel.textInsertion.debugSetAccessibilityTrusted(nil)
        }
        // One Claude Desktop session per start: the cancelled one's, and the
        // next dictation's.
        let cancelledDesktopID = "local_fb53459c-6a7b-43b1-a326-52258b970501"
        let nextDesktopID = "local_0c1d7a52-2f4e-4b8e-9a51-3d6f0e7c2b14"
        let registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 1_000) },
            isProcessAlive: { _ in true }
        )
        for (sessionID, desktopID, claudePID) in [
            ("s-cancelled", cancelledDesktopID, Int32(9001)), ("s-next", nextDesktopID, Int32(9002)),
        ] {
            registry.ingest(
                ClaudeHookRecord(
                    event: .sessionStart,
                    sessionID: sessionID,
                    timestamp: 0,
                    rawCwd: "/repo",
                    process: ClaudeHookProcessInfo(hookPID: 777, claudePID: claudePID, desktopSessionID: desktopID)
                ),
                origin: .localAuthenticated(peerUID: 501)
            )
        }
        // The first start's read of the focused app is held, as a slow
        // AppleScript reply would be; the next one answers at once.
        let reads = DesktopReadCounter()
        let firstReadStarted = BoundedWait()
        let releaseFirstRead = BoundedWait()
        viewModel.context.claudeSessionJoinResolver = ClaudeSessionJoinResolver(
            registry: registry,
            focusedDesktopSessionURL: { _ in
                guard await reads.next() == 1 else { return "https://claude.ai/epitaxy/\(nextDesktopID)" }
                firstReadStarted.resolve()
                _ = await releaseFirstRead.value(failAfter: 30)
                return "https://claude.ai/epitaxy/\(cancelledDesktopID)"
            }
        )

        viewModel.startDictation()
        let cancelledStart = try XCTUnwrap(viewModel.session.managedStartupTask)
        let reading = await firstReadStarted.value(failAfter: 10)
        XCTAssertTrue(reading, "the first start never read the focused app")
        viewModel.cancelDictation()

        await startAndSpeak(pipeline)
        releaseFirstRead.resolve()
        await cancelledStart.value

        XCTAssertEqual(
            viewModel.context.claudeSessionJoin?.snapshot.sessionID, "s-next",
            "the cancelled start's late capture replaced or cleared the new dictation's join"
        )
        await stopAndFinalize(pipeline)
        XCTAssertEqual(pipeline.overlay.committedTexts, [Self.phrase])
        XCTAssertEqual(pipeline.records.all.map(\.rawText), [Self.phrase])
    }

    /// A 200 reply with no usable text, through the real client: the raw
    /// transcript is committed once and the failure is shown (#1111).
    func testAMalformedPolishReplyCommitsTheTranscriptOnceAndSaysSo() async throws {
        try await assertUnusablePolishReply(#"{"choices":[{"message":"#)
    }

    func testAPolishReplyWithoutContentCommitsTheTranscriptOnceAndSaysSo() async throws {
        try await assertUnusablePolishReply(#"{"choices":[{"message":{"role":"assistant"}}]}"#)
    }

    func testAWhitespacePolishReplyCommitsTheTranscriptOnceAndSaysSo() async throws {
        try await assertUnusablePolishReply(#"{"choices":[{"message":{"role":"assistant","content":" \n\t "}}]}"#)
    }

    private func assertUnusablePolishReply(
        _ body: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        StubHTTPProtocol.reply.withLock { $0 = .http(200, body) }
        let pipeline = try await makePipeline(
            outputMode: .overlayBuffer,
            polish: LLMPolishingService(session: StubHTTPProtocol.session()),
            polishEndpoint: "http://\(StubHTTPProtocol.host)/v1/chat/completions",
            earlyPolish: false
        )

        await startAndSpeak(pipeline, file: file, line: line)
        await stopAndFinalize(
            pipeline,
            expectedError: "The LLM polishing endpoint answered with no usable text, so the transcript was not polished."
                + " [endpoint: http://\(StubHTTPProtocol.host)/v1/chat/completions]",
            finalStatus: "LLM polishing failed.",
            alerts: ["LLM Polishing Returned No Text"],
            file: file, line: line
        )

        XCTAssertEqual(pipeline.overlay.committedTexts, [Self.phrase], file: file, line: line)
        XCTAssertEqual(pipeline.records.all.map(\.status), [DictationSessionStatus.llmFailed.rawValue], file: file, line: line)
    }

    /// A polish cut off at the backend's output limit (#1109): the real
    /// client refuses the prefix, and the stop commits the whole transcript
    /// once and says why.
    func testAPolishCutOffAtTheOutputLimitCommitsTheTranscriptAndSaysSo() async throws {
        StubHTTPProtocol.reply.withLock {
            $0 = .http(200, #"{"choices":[{"index":0,"message":{"role":"assistant","content":"Hello from"},"finish_reason":"length"}]}"#)
        }
        let endpoint = "https://\(StubHTTPProtocol.host)/v1/chat/completions"
        let pipeline = try await makePipeline(
            outputMode: .overlayBuffer, polish: LLMPolishingService(session: StubHTTPProtocol.session()), polishEndpoint: endpoint, earlyPolish: false)

        await startAndSpeak(pipeline)
        let notice = "The polish reached the model's output limit, so the transcript was not polished."
        await stopAndFinalize(
            pipeline,
            expectedError: "\(notice) [endpoint: \(endpoint)]",
            finalStatus: "LLM polishing failed.",
            alerts: ["LLM Polishing Cut Off"]
        )

        XCTAssertEqual(pipeline.overlay.committedTexts, [Self.phrase])
        XCTAssertEqual(pipeline.records.all.map(\.rawText), [Self.phrase])
        XCTAssertNil(pipeline.records.all.first?.polishedText)
    }

    /// A new dictation while the stopped one waits on its polish: the one
    /// saved as not inserted keeps its audio in History (#1090).
    func testANewDictationDuringThePolishKeepsTheOldDictationsAudio() async throws {
        let polish = FakePolishingService { "<\($0.inputText)>" }
        let pipeline = try await makePipeline(outputMode: .overlayBuffer, polish: polish, earlyPolish: false)
        pipeline.viewModel.settings.dictationAudioEnabled = true
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-audio-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let audioStore = DictationAudioStore(directoryURL: directory)
        let store = try XCTUnwrap(DictationSessionStore.inMemory())
        store.audioStore = audioStore
        pipeline.viewModel.sessionStore = store
        await polish.holdNextRequest()

        await startAndSpeak(pipeline)
        pipeline.viewModel.stopDictation(reason: "test")
        await pipeline.server.awaitFrame("the final commit") { $0.isFinalCommit }
        pipeline.server.send(["type": "transcription.done", "text": Self.phrase])
        let polishing = await waitForPolishRequests(polish, 1)
        XCTAssertTrue(polishing, "the polish never started")

        pipeline.server.forgetFrames()
        await startAndSpeak(pipeline)
        await polish.releaseHeldRequest()
        _ = await store.count()

        let interrupted = try XCTUnwrap(pipeline.records.all.first)
        XCTAssertEqual(pipeline.records.all.map(\.commitSucceeded), [false])
        XCTAssertEqual(audioStore.storedIDs(), [interrupted.id])
        XCTAssertEqual(
            try Data(contentsOf: audioStore.fileURL(for: interrupted.id)),
            DictationAudioRecording.wav(fromPCM16: Self.speech(seed: 1)))

        await stopAndFinalize(pipeline)
        XCTAssertEqual(pipeline.overlay.committedTexts, ["<\(Self.phrase)>"], "the new dictation commits")
    }

    /// Quit while the stopped dictation waits on its polish: it reaches the
    /// History write queue, with its audio, before the quit drains that
    /// queue, and nothing is inserted (#1284).
    func testQuitDuringThePolishSavesTheDictationAsNotInserted() async throws {
        let polish = FakePolishingService { "<\($0.inputText)>" }
        let pipeline = try await makePipeline(outputMode: .overlayBuffer, polish: polish, earlyPolish: false)
        pipeline.viewModel.settings.dictationAudioEnabled = true
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-audio-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let audioStore = DictationAudioStore(directoryURL: directory)
        let store = try XCTUnwrap(DictationSessionStore.inMemory())
        store.audioStore = audioStore
        pipeline.viewModel.sessionStore = store
        await polish.holdNextRequest()

        await startAndSpeak(pipeline)
        pipeline.viewModel.stopDictation(reason: "test")
        await pipeline.server.awaitFrame("the final commit") { $0.isFinalCommit }
        pipeline.server.send(["type": "transcription.done", "text": Self.phrase])
        let polishing = await waitForPolishRequests(polish, 1)
        XCTAssertTrue(polishing, "the polish never started")

        let commit = try XCTUnwrap(pipeline.viewModel.session.polishAndCommitTask)
        // What `applicationWillTerminate` runs before it drains History.
        pipeline.viewModel.saveStoppedDictationForQuit()
        await store.pendingWrites?.value

        let saved = try XCTUnwrap(pipeline.records.all.first, "the quit lost the dictation")
        XCTAssertEqual(pipeline.records.all.map(\.commitSucceeded), [false])
        XCTAssertEqual(saved.rawText, Self.phrase)
        XCTAssertEqual(audioStore.storedIDs(), [saved.id])
        XCTAssertEqual(
            try Data(contentsOf: audioStore.fileURL(for: saved.id)),
            DictationAudioRecording.wav(fromPCM16: Self.speech(seed: 1)))

        await polish.releaseHeldRequest()
        await commit.value
        XCTAssertEqual(pipeline.overlay.commitCallCount, 0, "nothing is inserted after the quit")
        XCTAssertEqual(pipeline.records.all.count, 1, "the polish answering later saves nothing more")
    }

    /// Quit after the stop, before the final transcript arrives: the text
    /// received so far reaches the History write queue, with its audio, as
    /// not inserted (#1296).
    func testQuitBeforeTheFinalTranscriptSavesTheTextSoFar() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.settings.dictationAudioEnabled = true
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-audio-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let audioStore = DictationAudioStore(directoryURL: directory)
        let store = try XCTUnwrap(DictationSessionStore.inMemory())
        store.audioStore = audioStore
        pipeline.viewModel.sessionStore = store

        await startAndSpeak(pipeline)
        await sendSettledFinal(pipeline, Self.settledPiece)
        pipeline.viewModel.stopDictation(reason: "test")
        await pipeline.server.awaitFrame("the final commit") { $0.isFinalCommit }
        XCTAssertTrue(pipeline.viewModel.isFinalizingStop)

        // What `applicationWillTerminate` runs before it drains History.
        pipeline.viewModel.saveStoppedDictationForQuit()
        await store.pendingWrites?.value

        let saved = try XCTUnwrap(pipeline.records.all.first, "the quit lost the dictation")
        XCTAssertEqual(pipeline.records.all.map(\.commitSucceeded), [false])
        XCTAssertEqual(saved.rawText.trimmingCharacters(in: .whitespaces), Self.settledPiece)
        XCTAssertEqual(audioStore.storedIDs(), [saved.id])
        XCTAssertEqual(
            try Data(contentsOf: audioStore.fileURL(for: saved.id)),
            DictationAudioRecording.wav(fromPCM16: Self.speech(seed: 1)))
        XCTAssertEqual(pipeline.overlay.commitCallCount, 0, "nothing is inserted at quit")
        XCTAssertFalse(pipeline.viewModel.isFinalizingStop, "the stop is over")
    }

    /// Quit while still dictating: the stop the terminate observer schedules
    /// may never run, so the text and audio so far reach the History write
    /// queue as not inserted, before the quit drains it (#1568).
    func testQuitWhileDictatingSavesTheTextSoFar() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.settings.dictationAudioEnabled = true
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-audio-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let audioStore = DictationAudioStore(directoryURL: directory)
        let store = try XCTUnwrap(DictationSessionStore.inMemory())
        store.audioStore = audioStore
        pipeline.viewModel.sessionStore = store

        await startAndSpeak(pipeline)
        await sendSettledFinal(pipeline, Self.settledPiece)
        XCTAssertTrue(pipeline.viewModel.isDictating)

        // What `applicationWillTerminate` runs before it drains History.
        pipeline.viewModel.saveStoppedDictationForQuit()
        await store.pendingWrites?.value

        let saved = try XCTUnwrap(pipeline.records.all.first, "the quit lost the dictation")
        XCTAssertEqual(pipeline.records.all.map(\.commitSucceeded), [false])
        XCTAssertEqual(saved.rawText.trimmingCharacters(in: .whitespaces), Self.settledPiece)
        XCTAssertEqual(audioStore.storedIDs(), [saved.id])
        XCTAssertEqual(
            try Data(contentsOf: audioStore.fileURL(for: saved.id)),
            DictationAudioRecording.wav(fromPCM16: Self.speech(seed: 1)))
        XCTAssertEqual(pipeline.overlay.commitCallCount, 0, "nothing is inserted at quit")
        XCTAssertFalse(pipeline.viewModel.isDictating)
        XCTAssertFalse(pipeline.viewModel.isFinalizingStop, "the stop is over")
    }

    /// The same quit during a quick capture files the words so far as the
    /// stop would: in History as a capture, then in the Inbox (#1296).
    func testQuitBeforeTheFinalTranscriptFilesAQuickCapture() async throws {
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        let captured = QuickCaptures()
        pipeline.viewModel.session.onQuickCapture = { text, _, _ in
            captured.all.append((text, pipeline.records.all.count))
        }

        await startAndSpeak(pipeline, start: { $0.session.toggleQuickCapture() })
        await sendSettledFinal(pipeline, Self.settledPiece)
        pipeline.viewModel.stopDictation(reason: "test")
        await pipeline.server.awaitFrame("the final commit") { $0.isFinalCommit }

        pipeline.viewModel.saveStoppedDictationForQuit()

        XCTAssertEqual(captured.all.map { $0.text.trimmingCharacters(in: .whitespaces) }, [Self.settledPiece])
        XCTAssertEqual(captured.all.first?.recordsWritten, 1, "saved in History before the Inbox gets it")
        let record = try XCTUnwrap(pipeline.records.all.first)
        XCTAssertEqual(record.outputMode, DictationSessionRecord.quickCaptureOutputMode)
        XCTAssertEqual(record.quickCaptureDestination, "Inbox")
        XCTAssertEqual(pipeline.overlay.commitCallCount, 0, "nothing reaches the focused app")
        XCTAssertFalse(pipeline.viewModel.isFinalizingStop, "the stop is over")
    }

    /// With Polish while you speak off, nothing is polished while the user
    /// speaks: the stop sends the whole text in one request, as before #709.
    func testOverlayBufferWithEarlyPolishOffPolishesOnlyTheWholeTextAtStop() async throws {
        let polish = FakePolishingService { "<\($0.inputText)>" }
        let pipeline = try await makePipeline(outputMode: .overlayBuffer, polish: polish, earlyPolish: false)
        let whole = "\(Self.settledPiece) \(Self.tail)"

        await startAndSpeak(pipeline)
        XCTAssertNil(pipeline.viewModel.session.earlyPolishRun)
        await sendSettledFinal(pipeline, Self.settledPiece)

        await stopAndFinalize(pipeline, finalText: Self.tail)

        let requests = await polish.requests
        XCTAssertEqual(requests.map(\.inputText), [whole])
        XCTAssertEqual(pipeline.overlay.committedTexts, ["<\(whole)>"])
        XCTAssertEqual(pipeline.records.all.map(\.rawText), [whole])
        XCTAssertEqual(pipeline.records.all.first?.polishedText, "<\(whole)>")
    }

    /// Grounding is sampled at stop: when the stop's request carries context
    /// the piece was polished without (here the clipboard), the piece is
    /// discarded and the whole text is polished in one request, as before.
    func testOverlayBufferPolishesTheWholeTextWhenTheStopGroundsItInContext() async throws {
        let polish = FakePolishingService { "<\($0.inputText)>" }
        let pipeline = try await makePipeline(outputMode: .overlayBuffer, polish: polish)
        pipeline.viewModel.settings.polishClipboardContextEnabled = true
        pipeline.viewModel.dependencies.pasteboardReader = {
            PasteboardStub(string: "error in PolishContextBudget.swift line 40", types: [.string])
        }
        let whole = "\(Self.settledPiece) \(Self.tail)"

        await startAndSpeak(pipeline)
        pipeline.server.send(["type": "transcription.done", "text": Self.settledPiece])
        let pieceSent = await waitForPolishRequests(polish, 1)
        XCTAssertTrue(pieceSent, "no piece was polished while dictating")

        await stopAndFinalize(pipeline, finalText: Self.tail)

        let requests = await polish.requests
        XCTAssertEqual(requests.map(\.inputText), [Self.settledPiece, whole])
        XCTAssertTrue(
            requests.last?.userPrompts.last?.contains("PolishContextBudget.swift") == true,
            "the stop's request carries the clipboard"
        )
        XCTAssertEqual(pipeline.overlay.committedTexts, ["<\(whole)>"])
    }

    /// Clipboard context switched off while the stop waits on the piece in
    /// flight: the request leaves without the clipboard, and nothing the
    /// clipboard grounded is learned for the project (#1293).
    func testClipboardTurnedOffWhileTheStopWaitsOnAPieceIsNeitherSentNorLearned() async throws {
        let polish = FakePolishingService { "<\($0.inputText)>" }
        let pipeline = try await makePipeline(outputMode: .overlayBuffer, polish: polish)
        let settings = pipeline.viewModel.settings
        settings.polishClipboardContextEnabled = true
        settings.repoVocabularyEnabled = true
        pipeline.viewModel.dependencies.pasteboardReader = {
            PasteboardStub(string: "error in PolishContextBudget.swift line 40", types: [.string])
        }
        // A project to learn into; the repository itself has no vocabulary.
        let gathered = Mutex(false)
        pipeline.viewModel.dependencies.repoVocabularyGrounding = FakeRepoVocabularyGrounding(
            root: "/nonexistent-1293/project"
        ) { _ in
            gathered.withLock { $0 = true }
            return nil
        }
        let store = LearnedTermStore(fileURL: nil)
        pipeline.viewModel.learnedTermStore = store
        // The first clock read after the stop's gather is the early polish's
        // `finish()`: the moment the stop waits on the piece.
        let waitsOnPiece = BoundedWait()
        let now = pipeline.viewModel.dependencies.clock.now
        pipeline.viewModel.dependencies.clock.now = {
            if gathered.withLock({ $0 }) { waitsOnPiece.resolve() }
            return now()
        }
        let tail = "and open polishcontextbudget.swift now."
        await polish.holdNextRequest()

        await startAndSpeak(pipeline)
        pipeline.server.send(["type": "transcription.done", "text": Self.settledPiece])
        let pieceSent = await waitForPolishRequests(polish, 1)
        XCTAssertTrue(pieceSent, "no piece was polished while dictating")

        pipeline.viewModel.stopDictation(reason: "test")
        await pipeline.server.awaitFrame("the final commit") { $0.isFinalCommit }
        pipeline.server.send(["type": "transcription.done", "text": tail])
        let waiting = await waitsOnPiece.value(failAfter: 10)
        XCTAssertTrue(waiting, "the stop never waited on the piece")

        settings.polishClipboardContextEnabled = false
        await polish.releaseHeldRequest()
        let recorded = await pipeline.records.waitForCount(1)
        XCTAssertTrue(recorded)
        await pipeline.viewModel.session.polishAndCommitTask?.value
        store.waitForPendingWrites()

        let requests = await polish.requests
        XCTAssertFalse(
            requests.contains { request in
                ([request.inputText] + request.userPrompts).contains { $0.contains("PolishContextBudget") }
            },
            "the withdrawn clipboard was sent"
        )
        XCTAssertEqual(store.summary().terms, 0, "a term from the withdrawn clipboard was learned")
    }

    /// The joined session's host is revoked while the stop waits on the
    /// piece in flight: the prompt gathered from that session, and every
    /// spelling it grounded, stay out of every request (#1600).
    func testARevokedHostsSessionContextIsNotSentAfterTheStopWaitsOnAPiece() async throws {
        let polish = FakePolishingService { "<\($0.inputText)>" }
        let pipeline = try await makePipeline(outputMode: .overlayBuffer, polish: polish)
        let settings = pipeline.viewModel.settings
        settings.claudeRepoContextEnabled = true
        settings.repoVocabularyEnabled = true
        // A remote Claude Desktop session, its last prompt naming the sentinel.
        let registry = ClaudeSessionRegistry(
            now: { Date(timeIntervalSince1970: 2_000_000) },
            isProcessAlive: { _ in true }
        )
        let desktopID = "local_fb53459c-6a7b-43b1-a326-52258b970501"
        XCTAssertNotNil(registry.ingest(
            ClaudeHookRecord(
                event: .userPromptSubmit, sessionID: "s1", timestamp: 0,
                rawCwd: "/repo", prompt: "rename ZebraSentinel42 everywhere"
            ),
            origin: .remote(channel: "ssh:host-a"),
            environment: ClaudeRemoteSessionEnvironment(desktopSessionID: desktopID)
        ))
        let resolver = ClaudeSessionJoinResolver(
            registry: registry,
            focusedTerminalTTY: { _ in nil },
            focusedBrowserTabURL: { _ in nil },
            focusedDesktopSessionURL: { _ in "https://claude.ai/epitaxy/\(desktopID)" },
            focusedWindowID: { _ in nil }
        )
        let resolved = await resolver.resolve(
            target: TerminalScreenTarget(pid: 6060, bundleID: ClaudeDesktopAllowlist.bundleID)
        )
        let join = try XCTUnwrap(resolved)
        pipeline.viewModel.context.claudeSessionJoinResolver = resolver
        // The repository seam marks the end of the gather; the first clock
        // read after it is the early polish's `finish()`, the stop's wait.
        let gathered = Mutex(false)
        pipeline.viewModel.dependencies.repoVocabularyGrounding = FakeRepoVocabularyGrounding { _ in
            gathered.withLock { $0 = true }
            return nil
        }
        let waitsOnPiece = BoundedWait()
        let now = pipeline.viewModel.dependencies.clock.now
        pipeline.viewModel.dependencies.clock.now = {
            if gathered.withLock({ $0 }) { waitsOnPiece.resolve() }
            return now()
        }
        await polish.holdNextRequest()

        await startAndSpeak(pipeline)
        pipeline.viewModel.context.claudeSessionJoin = join
        pipeline.server.send(["type": "transcription.done", "text": Self.settledPiece])
        let pieceSent = await waitForPolishRequests(polish, 1)
        XCTAssertTrue(pieceSent, "no piece was polished while dictating")

        pipeline.viewModel.stopDictation(reason: "test")
        await pipeline.server.awaitFrame("the final commit") { $0.isFinalCommit }
        pipeline.server.send(["type": "transcription.done", "text": Self.tail])
        let waiting = await waitsOnPiece.value(failAfter: 10)
        XCTAssertTrue(waiting, "the stop never waited on the piece")

        // What revoking the host does to its sessions.
        XCTAssertEqual(registry.evictRemoteSessions(notIn: []), 1)
        await polish.releaseHeldRequest()
        let recorded = await pipeline.records.waitForCount(1)
        XCTAssertTrue(recorded)
        await pipeline.viewModel.session.polishAndCommitTask?.value

        let requests = await polish.requests
        XCTAssertFalse(
            requests.contains { request in
                ([request.systemPrompt, request.inputText] + request.userPrompts)
                    .contains { $0.contains("ZebraSentinel42") }
            },
            "the revoked host's session context was sent"
        )
    }

    /// A quick capture is never polished, so no piece of it is sent to the
    /// polisher while the user speaks (#709).
    func testAQuickCaptureSendsNoPieceToThePolisher() async throws {
        let polish = FakePolishingService { "<\($0.inputText)>" }
        let pipeline = try await makePipeline(outputMode: .overlayBuffer, polish: polish)
        let captured = QuickCaptures()
        pipeline.viewModel.session.onQuickCapture = { text, _, _ in
            captured.all.append((text, pipeline.records.all.count))
        }

        await startAndSpeak(pipeline, start: { $0.session.toggleQuickCapture() })
        XCTAssertNil(pipeline.viewModel.session.earlyPolishRun)
        await sendSettledFinal(pipeline, Self.settledPiece)
        await stopAndFinalize(
            pipeline, finalText: Self.tail, finalStatus: DictationViewModel.StatusStrings.quickCaptureSaved
        )

        let requests = await polish.requests
        XCTAssertEqual(requests.count, 0)
        XCTAssertEqual(captured.all.count, 1)
    }

    /// Another running copy turned History on after this one launched with
    /// it off: the capture is saved, so the Inbox gets its History id, or
    /// polishing and routing never update the entry (#1605 review).
    func testAQuickCaptureSavedAfterAnotherCopyTurnedHistoryOnGetsItsHistoryID() async throws {
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        pipeline.viewModel.sessionStore = try XCTUnwrap(DictationSessionStore.inMemory())
        pipeline.viewModel.settings.dictationHistoryRetention = .off
        makeSettings(defaults: pipeline.viewModel.settings.defaults).dictationHistoryRetention = .forever
        let ids = QuickCaptureHistoryIDs()
        pipeline.viewModel.session.onQuickCapture = { _, id, _ in ids.all.append(id) }

        await startAndSpeak(pipeline, start: { $0.session.toggleQuickCapture() })
        sendPartials(pipeline)
        await stopAndFinalize(pipeline, finalStatus: DictationViewModel.StatusStrings.quickCaptureSaved)

        let record = try XCTUnwrap(pipeline.records.all.first, "the capture is saved")
        XCTAssertEqual(ids.all, [record.id])
    }

    /// Quick capture (#725): the shortcut's dictation runs as Overlay Buffer,
    /// but its stop commits nothing to the focused app. The History record
    /// is written first, then the words go to the Inbox.
    func testAQuickCaptureGoesToTheInboxNeverIntoTheFocusedApp() async throws {
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        let captured = QuickCaptures()
        pipeline.viewModel.session.onQuickCapture = { text, _, _ in
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

    /// A quick capture said while joined to a Work project goes to the
    /// Inbox with that group, so it is polished and routed among Work
    /// projects only (#1005).
    func testAQuickCaptureCarriesTheJoinedProjectsGroupToTheInbox() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        let store = LearnedTermStore(fileURL: nil, now: { Date(timeIntervalSince1970: 0) })
        store.recordCorrection("Kubrix", project: .init(key: "/nonexistent-1005/acme", name: "acme"))
        store.setGroup(.work, keys: ["/nonexistent-1005/acme"])
        store.waitForPendingWrites()
        pipeline.viewModel.learnedTermStore = store
        let groups = QuickCaptureGroups()
        pipeline.viewModel.session.onQuickCapture = { _, _, group in groups.all.append(group) }

        await startAndSpeak(pipeline, start: { $0.session.toggleQuickCapture() })
        let origin = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
        var snapshot = ClaudeSessionSnapshot(
            sessionID: "s1", origin: origin, agent: .claude, firstSeen: Date(timeIntervalSince1970: 0))
        snapshot.workspace = ClaudeWorkspaceReference.make(rawCwd: "/nonexistent-1005/acme/Sources", origin: origin)
        pipeline.viewModel.session.context.claudeSessionJoin = ClaudeSessionJoin(
            target: TerminalScreenTarget(pid: 4242, bundleID: "com.apple.Terminal"),
            snapshot: snapshot, windowID: 101, mechanism: .ttyDevice)
        sendPartials(pipeline)
        await stopAndFinalize(pipeline, finalStatus: DictationViewModel.StatusStrings.quickCaptureSaved)

        XCTAssertEqual(groups.all, [.work])
    }

    /// A quick capture joined to a session in a worktree outside its Work
    /// checkout reaches the Inbox in Work, through the git root the start
    /// looked up (#1155).
    func testAQuickCaptureInAWorktreeOutsideItsCheckoutCarriesTheCheckoutsGroup() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        let store = LearnedTermStore(fileURL: nil, now: { Date(timeIntervalSince1970: 0) })
        store.recordCorrection("Kubrix", project: .init(key: "/nonexistent-1155/acme", name: "acme"))
        store.setGroup(.work, keys: ["/nonexistent-1155/acme"])
        store.waitForPendingWrites()
        pipeline.viewModel.learnedTermStore = store
        let grounding = FakeRepoVocabularyGrounding(outcome: nil)
        grounding.secondPassRoot = .root("/nonexistent-1155/acme-feature", mainCheckout: "/nonexistent-1155/acme")
        pipeline.viewModel.dependencies.repoVocabularyGrounding = grounding
        let groups = QuickCaptureGroups()
        pipeline.viewModel.session.onQuickCapture = { _, _, group in groups.all.append(group) }

        await startAndSpeak(pipeline, start: { $0.session.toggleQuickCapture() })
        let origin = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
        var snapshot = ClaudeSessionSnapshot(
            sessionID: "s1", origin: origin, agent: .claude, firstSeen: Date(timeIntervalSince1970: 0))
        snapshot.workspace = ClaudeWorkspaceReference.make(
            rawCwd: "/nonexistent-1155/acme-feature/Sources", origin: origin)
        pipeline.viewModel.session.context.claudeSessionJoin = ClaudeSessionJoin(
            target: TerminalScreenTarget(pid: 4242, bundleID: "com.apple.Terminal"),
            snapshot: snapshot, windowID: 101, mechanism: .ttyDevice)
        await pipeline.viewModel.session.lookUpJoinedRepositoryRoot()
        sendPartials(pipeline)
        await stopAndFinalize(pipeline, finalStatus: DictationViewModel.StatusStrings.quickCaptureSaved)

        XCTAssertEqual(grounding.rootLookups, ["/nonexistent-1155/acme-feature/Sources"])
        XCTAssertEqual(groups.all, [.work])
    }

    // MARK: - Destinations (#840)

    /// Tab moves an ordinary dictation to the Inbox: it stops as a quick
    /// capture, saved in History first, and nothing reaches the focused app.
    func testTabToTheInboxSavesTheDictationThereAndNothingReachesTheFocusedApp() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        let captured = QuickCaptures()
        pipeline.viewModel.session.onQuickCapture = { text, _, _ in
            captured.all.append((text, pipeline.records.all.count))
        }

        await startAndSpeak(pipeline)
        XCTAssertEqual(
            pipeline.overlay.shownDestinations.last??.items.map(\.kind),
            [.focusedApp(joined: nil), .inbox],
            "with nobody waiting the overlay offers the focused app and the Inbox"
        )
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .focusedApp(joined: nil))

        pipeline.viewModel.session.moveDestination(forward: true)
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .inbox)
        XCTAssertTrue(pipeline.viewModel.session.sessionIsQuickCapture)

        sendPartials(pipeline)
        await stopAndFinalize(pipeline, finalStatus: DictationViewModel.StatusStrings.quickCaptureSaved)

        XCTAssertEqual(pipeline.overlay.commitCallCount, 0, "nothing reaches the focused app")
        XCTAssertEqual(captured.all.map(\.text), [Self.phrase])
        XCTAssertEqual(captured.all.first?.recordsWritten, 1, "saved in History before the Inbox gets it")
        XCTAssertEqual(pipeline.records.all.first?.outputMode, DictationSessionRecord.quickCaptureOutputMode)
        XCTAssertFalse(pipeline.viewModel.session.sessionIsQuickCapture, "the next dictation is an ordinary one")
    }

    /// The overlay lists every destination while the user moves between
    /// them (#1015): Tab opens the list, each move keeps it open for
    /// another `DestinationListRule.openFor`, and it closes on the pick.
    /// Closed, a click on the picked destination opens it without a move.
    func testTabOpensTheDestinationListUntilTheMovesStop() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.session.onQuickCapture = { _, _, _ in }
        await startAndSpeak(pipeline)
        let session = pipeline.viewModel.session
        func shown() -> OverlayDestinationStrip? { pipeline.overlay.shownDestinations.last ?? nil }
        XCTAssertEqual(shown()?.isOpen, false, "the overlay opens with the list closed")
        let openFor = Double(DestinationListRule.openFor.components.seconds)

        let armed = pipeline.clock.pendingSleepers
        session.moveDestination(forward: true)
        XCTAssertEqual(shown()?.isOpen, true)
        XCTAssertEqual(shown()?.selectedKind, .inbox)
        await pipeline.clock.waitForSleepers(armed + 1)
        pipeline.clock.advance(by: openFor - 0.5)

        session.moveDestination(forward: true)
        XCTAssertEqual(shown()?.selectedKind, .focusedApp(joined: nil))
        await pipeline.clock.waitForSleepers(armed + 1)
        pipeline.clock.advance(by: 0.5)
        XCTAssertEqual(shown()?.isOpen, true, "the second Tab restarted the wait")
        pipeline.clock.advance(by: openFor - 0.5)
        await session.destinationListCloseTask?.value
        XCTAssertEqual(shown()?.isOpen, false)
        XCTAssertEqual(shown()?.selectedKind, .focusedApp(joined: nil), "closing keeps the pick")

        session.clickDestination(.focusedApp)
        XCTAssertEqual(shown()?.isOpen, true, "a click on the picked destination opens the list")
        XCTAssertEqual(shown()?.selectedKind, .focusedApp(joined: nil))
        session.cancelDictation()
        XCTAssertNil(session.destinationListCloseTask, "the stop ends the wait")
    }

    /// A quick capture opens on the Inbox; Tab from there wraps to the
    /// focused app, and the stop commits there as any dictation does.
    func testTabFromTheInboxBackToTheFocusedAppCommitsThere() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        let captured = QuickCaptures()
        pipeline.viewModel.session.onQuickCapture = { text, _, _ in captured.all.append((text, 0)) }

        await startAndSpeak(pipeline, start: { $0.session.toggleQuickCapture() })
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .inbox)
        pipeline.viewModel.session.moveDestination(forward: true)
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .focusedApp(joined: nil))

        sendPartials(pipeline)
        await stopAndFinalize(pipeline)

        XCTAssertEqual(pipeline.overlay.commitCallCount, 1)
        XCTAssertEqual(pipeline.overlay.committedTexts, [Self.phrase])
        XCTAssertTrue(captured.all.isEmpty)
    }

    /// The quick capture shortcut during a dictation picks the Inbox, and
    /// pressed again on the Inbox it stops.
    func testTheQuickCaptureKeyDuringADictationPicksTheInboxThenStops() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.session.onQuickCapture = { _, _, _ in }
        await startAndSpeak(pipeline)

        pipeline.viewModel.session.toggleQuickCapture()
        XCTAssertTrue(pipeline.viewModel.isDictating)
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .inbox)

        pipeline.viewModel.session.toggleQuickCapture()
        XCTAssertFalse(pipeline.viewModel.isDictating, "pressed on the Inbox, it stops")
        pipeline.server.send(["type": "transcription.done", "text": Self.phrase])
        _ = await pipeline.records.waitForCount(1)
        XCTAssertEqual(pipeline.overlay.commitCallCount, 0)
    }

    /// Tab to a session that needs you brings its pane forward, and only
    /// once the terminal confirmed it does the overlay switch. The stop
    /// commits into that pane like any dictation, and answering takes the
    /// session out of the queue.
    func testTabToAWaitingSessionBringsItsPaneForwardAndCommitsThere() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        let waiting = installWaitingSessions(pipeline, ["pay": "/r/payments"])
        // At the stop, the terminal holding the pane is in front.
        let terminalPID: pid_t = 5151
        pipeline.viewModel.dependencies.bundleIdentifier = {
            $0 == terminalPID ? TerminalScreenAllowlist.ghosttyBundleID : nil
        }

        await startAndSpeak(pipeline)
        let strip = try XCTUnwrap(pipeline.overlay.shownDestinations.last ?? nil)
        XCTAssertEqual(strip.items.map(\.label).dropFirst(), ["Inbox", "payments"])

        pipeline.viewModel.session.moveDestination(forward: true)
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .inbox, "the first Tab reaches the Inbox")
        pipeline.viewModel.session.moveDestination(forward: true)
        await pipeline.viewModel.session.destinationFocusTask?.value
        XCTAssertEqual(waiting.focuser.focusedSessionIDs, ["pay"])
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .session)
        XCTAssertTrue(waiting.tracker.queue.isEmpty, "answering takes it out of the queue")
        XCTAssertEqual(
            pipeline.overlay.shownDestinations.last??.items.map(\.label).dropFirst(), ["Inbox", "payments"],
            "the picked session keeps its pill after it left the queue"
        )

        pipeline.overlay.commitTargetAppPID = terminalPID
        sendPartials(pipeline)
        await stopAndFinalize(pipeline)
        XCTAssertEqual(pipeline.overlay.committedTexts, [Self.phrase])
        XCTAssertEqual(waiting.focuser.readBackSessionIDs, ["pay"], "the stop asked which session the pane shows")
    }

    /// The dictation starts in a session with a prompt route, and Tab picks
    /// another one: the words go into the picked pane by keyboard, and the
    /// start session's route gets nothing (#1054).
    func testTabToAnotherSessionNeverWritesThroughTheStartSessionsRoute() async throws {
        let relay = try FakeOpencodePromptRelay()
        addTeardownBlock { relay.stop() }
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.overlay.insertsThroughCommitter = true
        pipeline.overlay.passesTargetPIDToCommitter = false
        joinOpencodePane(pipeline, relay: relay.relay(sessionID: "ses_a").address)
        let waiting = installWaitingSessions(pipeline, ["pay": "/r/payments"])
        let typed = recordTypedText(pipeline)
        let terminalPID: pid_t = 4343
        pipeline.viewModel.dependencies.bundleIdentifier = {
            $0 == terminalPID ? TerminalScreenAllowlist.ghosttyBundleID : nil
        }

        await startAndSpeak(pipeline)
        XCTAssertTrue(pipeline.viewModel.textInsertion.promptRelayTakesText, "precondition: the relay is armed")
        pipeline.viewModel.session.moveDestination(forward: false)
        await pipeline.viewModel.session.destinationFocusTask?.value
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .session)

        pipeline.overlay.commitTargetAppPID = terminalPID
        sendPartials(pipeline)
        await stopAndFinalize(pipeline)

        XCTAssertEqual(waiting.focuser.readBackSessionIDs, ["pay"])
        let typedAll = await typed.waitFor(Self.phrase)
        XCTAssertTrue(typedAll, "typed: \(typed.text.debugDescription)")
        XCTAssertEqual(relay.calls.map(\.path), [], "the start session's prompt gets nothing")
    }

    // MARK: - The session's mod fills the prompt box (#1409)

    /// A Claude Code session joined by tty, with a mod attached: the overlay
    /// commit asks the mod to fill the prompt and posts no key. A second
    /// dictation into the same unsent prompt fills with its leading space.
    func testAnOverlayCommitIntoAClaudeSessionWithAModFillsItsPromptAndTypesNothing() async throws {
        let (pipeline, typed, fills) = try await modChannelPipeline(answers: [.fill])
        let settled = FillSettled()
        ModChannelOverlayCommitter.debugFillSettled = { settled.note($0) }
        addTeardownBlock { @MainActor in ModChannelOverlayCommitter.debugFillSettled = nil }

        await dictate(pipeline, "that's what I was doing.")
        let first = await settled.wait(for: 1)
        await dictate(pipeline, "Usually it works.")
        let second = await settled.wait(for: 2)

        XCTAssertEqual(first && second, true, "both fills settled")
        XCTAssertEqual(settled.outcomes, [true, true])
        XCTAssertEqual(fills.texts, ["that's what I was doing.", " Usually it works."])
        XCTAssertEqual(typed.text, "", "no key went to the terminal")
        XCTAssertEqual(pipeline.records.all.map(\.commitSucceeded), [true, true])
    }

    /// The prompt box already holds typed words when the dictation starts:
    /// the mod reads it at the stop, so the first commit continues it with a
    /// space instead of gluing to its last word, which no earlier commit
    /// could have told the app (#1406).
    func testAFillAfterWordsTypedInThePromptBoxStartsWithASpace() async throws {
        let (pipeline, typed, fills) = try await modChannelPipeline(
            answers: [.fill], drafts: [(text: "fix the flaky", cursor: 13)]
        )
        let settled = FillSettled()
        ModChannelOverlayCommitter.debugFillSettled = { settled.note($0) }
        addTeardownBlock { @MainActor in ModChannelOverlayCommitter.debugFillSettled = nil }

        await dictate(pipeline, "reconnect test.")
        let filled = await settled.wait(for: 1)

        XCTAssertTrue(filled)
        XCTAssertEqual(fills.texts, [" reconnect test."])
        XCTAssertEqual(typed.text, "")
    }

    /// The person cleared the box after the last commit without sending it:
    /// the mod reads it empty, so `/compact` stays a command, where the
    /// guess from the last commit would have put a space in front (#802).
    func testAFillIntoABoxTheModReadsEmptyTakesNoSpaceAfterAnEarlierCommit() async throws {
        let (pipeline, _, fills) = try await modChannelPipeline(
            answers: [.fill], drafts: [(text: "", cursor: 0)]
        )
        let settled = FillSettled()
        ModChannelOverlayCommitter.debugFillSettled = { settled.note($0) }
        addTeardownBlock { @MainActor in ModChannelOverlayCommitter.debugFillSettled = nil }

        await dictate(pipeline, "run the tests.")
        _ = await settled.wait(for: 1)
        await dictate(pipeline, "/compact")
        let both = await settled.wait(for: 2)

        XCTAssertTrue(both)
        XCTAssertEqual(fills.texts, ["run the tests.", "/compact"])
    }

    /// With session context on, the polish request carries the draft behind
    /// its label, so the model sees what the dictation continues.
    func testThePromptDraftReachesThePolishRequest() async throws {
        let (pipeline, _, _) = try await modChannelPipeline(
            answers: [.fill], drafts: [(text: "fix the flaky\nWebSocketClient", cursor: 29)]
        )
        let polish = FakePolishingService()
        pipeline.viewModel.llmPolishingService = polish
        pipeline.viewModel.settings.claudeRepoContextEnabled = true

        await dictate(pipeline, "reconnect test.")
        let sent = await waitForPolishRequests(polish, 1)

        XCTAssertTrue(sent)
        let prompts = await polish.lastRequest?.userPrompts.joined(separator: "\n") ?? ""
        XCTAssertTrue(
            prompts.contains(ClaudePromptDraft.beforeCursorLabel + "fix the flaky / WebSocketClient"),
            prompts
        )
    }

    /// The mod got the fill and never answered: it may have filled the box,
    /// so the words stay in History instead of going in twice.
    func testAFillTheModNeverAnswersIsKeptNotTyped() async throws {
        let answered = BoundedWait()
        let (pipeline, typed, fills) = try await modChannelPipeline(answers: [.silent], answerGate: answered)
        let settled = FillSettled()
        ModChannelOverlayCommitter.debugFillSettled = { settled.note($0) }
        addTeardownBlock { @MainActor in ModChannelOverlayCommitter.debugFillSettled = nil }

        await dictate(pipeline, "run the tests.")
        answered.resolve()
        let done = await settled.wait(for: 1)

        XCTAssertTrue(done)
        XCTAssertEqual(settled.outcomes, [false])
        XCTAssertEqual(fills.texts, ["run the tests."])
        XCTAssertEqual(typed.text, "", "nothing typed over a fill that may have landed")
        XCTAssertEqual(pipeline.viewModel.lastError, DictationViewModel.StatusStrings.agentPromptTextKeptInHistory)
        XCTAssertEqual(pipeline.records.all.map(\.rawText), ["run the tests."])
    }

    /// The same with History off, where Copy last dictation is all that
    /// holds the text until the next dictation replaces it: the text goes
    /// on the clipboard, the popover says so, and the next dictation leaves
    /// it there (#1499).
    func testAnUnansweredModFillWithHistoryOffSurvivesTheNextDictation() async throws {
        let answered = BoundedWait()
        let (pipeline, typed, fills) = try await modChannelPipeline(answers: [.silent], answerGate: answered)
        pipeline.viewModel.settings.dictationHistoryRetention = .off
        pipeline.viewModel.settings.autoCopyEnabled = false
        let copied = pipeline.viewModel.recordPasteboardWrites()
        let settled = FillSettled()
        ModChannelOverlayCommitter.debugFillSettled = { settled.note($0) }
        addTeardownBlock { @MainActor in ModChannelOverlayCommitter.debugFillSettled = nil }

        await dictate(pipeline, "run the tests.")
        answered.resolve()
        let done = await settled.wait(for: 1)
        XCTAssertTrue(done)
        XCTAssertEqual(fills.texts, ["run the tests."])
        XCTAssertEqual(pipeline.viewModel.lastError, DictationViewModel.StatusStrings.overlayCopiedToClipboard)
        XCTAssertEqual(copied.values, ["run the tests."])

        // The next dictation goes in by keys: the mod is gone.
        pipeline.viewModel.context.claudeModChannels = nil
        await dictate(pipeline, "/compact")

        XCTAssertEqual(typed.text, "/compact", "precondition: the next dictation committed, and A was never typed")
        XCTAssertEqual(copied.values, ["run the tests."], "the next dictation leaves the clipboard alone")
    }

    // MARK: - A spoken send through the session's mod (#1644)

    /// "Send it" into a Claude Code session with its mod: the mod fills and
    /// submits, once, and no key is posted, so Secure Keyboard Entry does
    /// not stop it.
    func testASpokenSendThroughTheModSubmitsOnceAndPostsNoKey() async throws {
        var returns: [pid_t] = []
        let (pipeline, typed, fills) = try await modChannelPipeline(
            answers: [.sent], returnKeyPoster: { pid in
                returns.append(pid)
                return true
            }
        )
        pipeline.viewModel.settings.overlaySpokenSendEnabled = true
        TerminalTargetDetector.debugSecureEventInputOverride = { true }
        addTeardownBlock { @MainActor in TerminalTargetDetector.debugSecureEventInputOverride = nil }
        let settled = FillSettled()
        ModChannelOverlayCommitter.debugFillSettled = { settled.note($0) }
        addTeardownBlock { @MainActor in ModChannelOverlayCommitter.debugFillSettled = nil }

        await dictate(pipeline, "run the tests, send it.")
        let done = await settled.wait(for: 1)

        XCTAssertTrue(done)
        XCTAssertEqual(fills.kinds, [.send])
        XCTAssertEqual(fills.texts, ["run the tests"])
        XCTAssertEqual(returns, [], "no Return key")
        XCTAssertEqual(typed.text, "", "no key at all")
    }

    /// The session is mid-turn: the mod's submit waits for it, and the
    /// popover says so instead of reporting the prompt as sent.
    func testASpokenSendTheModQueuesSaysItRunsAfterTheTurn() async throws {
        let (pipeline, typed, fills) = try await modChannelPipeline(answers: [.queued])
        pipeline.viewModel.settings.overlaySpokenSendEnabled = true
        let settled = FillSettled()
        ModChannelOverlayCommitter.debugFillSettled = { settled.note($0) }
        addTeardownBlock { @MainActor in ModChannelOverlayCommitter.debugFillSettled = nil }

        await dictate(pipeline, "run the tests, send it.")
        let done = await settled.wait(for: 1)

        XCTAssertTrue(done)
        XCTAssertEqual(fills.kinds, [.send])
        XCTAssertEqual(typed.text, "")
        XCTAssertEqual(pipeline.viewModel.lastError, DictationSessionController.ModChannelStatus.queued)
    }

    /// The mod refused (a dialog held the keys): the words are typed into
    /// the session's pane, which is in front, and Return follows once, as
    /// before the mod.
    func testASpokenSendTheModRefusesIsTypedThenReturnedOnce() async throws {
        var returns: [pid_t] = []
        let (pipeline, typed, fills) = try await modChannelPipeline(
            answers: [.refuse], returnKeyPoster: { pid in
                returns.append(pid)
                return true
            }
        )
        pipeline.viewModel.settings.overlaySpokenSendEnabled = true
        pipeline.viewModel.dependencies.bundleIdentifier = {
            $0 == 4343 ? TerminalScreenAllowlist.ghosttyBundleID : nil
        }
        let settled = FillSettled()
        ModChannelOverlayCommitter.debugFillSettled = { settled.note($0) }
        addTeardownBlock { @MainActor in ModChannelOverlayCommitter.debugFillSettled = nil }

        await dictate(pipeline, "run the tests, send it.")
        let done = await settled.wait(for: 1)

        XCTAssertTrue(done)
        XCTAssertEqual(fills.kinds, [.send])
        XCTAssertEqual(typed.text, "run the tests")
        XCTAssertEqual(returns, [4343])
    }

    /// The joined session's band follows the dictation: listening with the
    /// words so far, then finishing, then done, which clears it (#1411).
    func testTheJoinedSessionsBandFollowsTheDictationAndClearsAtTheEnd() async throws {
        let (pipeline, _, recorder) = try await modChannelPipeline(answers: [.fill])
        let shown = BoundedWait()
        pipeline.overlay.onRefresh = { call in
            if call.displayText == Self.phrase { shown.resolve() }
        }

        await startAndSpeak(pipeline)
        sendPartials(pipeline)
        let shownWhileDictating = await shown.value(failAfter: 10)
        XCTAssertTrue(shownWhileDictating)
        await stopAndFinalize(pipeline)

        let states = recorder.states
        let phases = states.map(\.phase)
        XCTAssertEqual(phases.first, .listening, "phases: \(phases)")
        XCTAssertEqual(phases.last, .done)
        XCTAssertTrue(phases.contains(.finishing), "phases: \(phases)")
        XCTAssertTrue(
            states.contains { $0.phase == .listening && $0.text == Self.phrase },
            "the band showed the words: \(states.map(\.text))"
        )
        XCTAssertNil(states.last?.text, "done carries no words")
        XCTAssertEqual(phases.filter { $0 == .done }.count, 1)
    }

    /// The band says the same thing for longer than the mod keeps a band it
    /// has not heard about (30 s): the user paused, or a polish runs long.
    /// The app sends it again in time, so the band goes only when the app
    /// does.
    func testAnUnchangedBandIsSentAgainBeforeTheModWouldClearIt() async throws {
        let (pipeline, _, recorder) = try await modChannelPipeline(answers: [.fill])
        let shown = BoundedWait()
        pipeline.overlay.onRefresh = { call in
            if call.displayText == Self.phrase { shown.resolve() }
        }

        await startAndSpeak(pipeline)
        sendPartials(pipeline)
        let shownWhileDictating = await shown.value(failAfter: 10)
        XCTAssertTrue(shownWhileDictating)
        await pipeline.clock.waitForSleepers(pipeline.listeningTimers + 1)
        let resent = BoundedWait()
        recorder.onState = { resent.resolve() }
        pipeline.clock.advance(by: 10)
        let repeated = await resent.value(failAfter: 10)
        recorder.onState = nil

        XCTAssertTrue(repeated, "the unchanged band was sent again")
        XCTAssertEqual(recorder.states.last?.phase, .listening)
        XCTAssertEqual(recorder.states.last?.text, Self.phrase)
        await stopAndFinalize(pipeline)
        XCTAssertEqual(recorder.states.last?.phase, .done)
    }

    /// The mod could not fill (a dialog held the keys): the words go in by
    /// keyboard, once.
    func testAFillTheModRefusesIsTypedInstead() async throws {
        let (pipeline, typed, fills) = try await modChannelPipeline(answers: [.refuse])

        await dictate(pipeline, "run the tests.")
        let typedAll = await typed.waitFor("run the tests.")

        XCTAssertTrue(typedAll, "typed: \(typed.text.debugDescription)")
        XCTAssertEqual(fills.texts, ["run the tests."])
    }

    /// The user switched to another tab of the same terminal before the mod
    /// refused. The app pid still matches, but keys would reach the other
    /// tab's prompt, so the words stay in History.
    func testAFillRefusedAfterATabSwitchIsKeptNotTyped() async throws {
        let focus = FocusedPane("/dev/ttys042")
        let answered = BoundedWait()
        let (pipeline, typed, fills) = try await modChannelPipeline(
            answers: [.refuse], focus: focus, answerGate: answered, beforeAnswer: { focus.tty = "/dev/ttys099" }
        )
        let settled = FillSettled()
        ModChannelOverlayCommitter.debugFillSettled = { settled.note($0) }
        addTeardownBlock { @MainActor in ModChannelOverlayCommitter.debugFillSettled = nil }

        await dictate(pipeline, "run the tests.")
        answered.resolve()
        let done = await settled.wait(for: 1)

        XCTAssertTrue(done)
        XCTAssertEqual(fills.texts, ["run the tests."])
        XCTAssertEqual(typed.text, "", "nothing typed into the other tab")
        XCTAssertEqual(pipeline.viewModel.lastError, DictationViewModel.StatusStrings.agentPromptTextKeptInHistory)
    }

    /// The mod refused, and while the fallback asked herdr what runs in the
    /// session's pane, the user moved to another pane of the same herdr.
    /// The app pid still matches and the session still runs in its pane,
    /// but keys would reach the other pane, so the words stay in History
    /// (#1498).
    func testARefusedModFillNeverTypesAfterAPaneSwitchDuringTheFocusLookup() async throws {
        try await assertRefusedModFillNotTyped(switchingPanesDuring: .foreground)
    }

    /// The same switch during the lookup's second tty read, which follows
    /// the pane's foreground query: a pane switch keeps the tty, so the
    /// focused pane must be the last thing read before the keys.
    func testARefusedModFillNeverTypesAfterAPaneSwitchDuringTheTTYReRead() async throws {
        try await assertRefusedModFillNotTyped(switchingPanesDuring: .tty)
    }

    /// The fallback's lookup reads the tty, then herdr's focused pane and
    /// its foreground, then the tty again. With `.tty` the switch lands on
    /// the second tty read.
    private func assertRefusedModFillNotTyped(
        switchingPanesDuring switchDuring: HerdrFocus.Read
    ) async throws {
        let focus = HerdrFocus("w1:p2")
        let sessionPane = FakeHerdrSocket.focusedPane("w1:p2") { [(9001, "claude")] }
        let herdr = try FakeHerdrSocket(answer: { request in
            switch request.method {
            case "pane.current":
                return .result(#"{"type":"pane_current","pane":{"pane_id":"\#(focus.pane)","focused":true}}"#)
            case "pane.process_info":
                defer { focus.read(.foreground) }
                return sessionPane(request)
            default:
                return sessionPane(request)
            }
        })
        addTeardownBlock { herdr.stop() }
        let answered = BoundedWait()
        let (pipeline, typed, fills) = try await modChannelPipeline(
            answers: [.refuse], herdr: herdr, herdrFocus: focus, answerGate: answered,
            beforeAnswer: { focus.switchTo("w1:p3", during: switchDuring, count: switchDuring == .tty ? 2 : 1) }
        )
        let settled = FillSettled()
        ModChannelOverlayCommitter.debugFillSettled = { settled.note($0) }
        addTeardownBlock { @MainActor in ModChannelOverlayCommitter.debugFillSettled = nil }

        await dictate(pipeline, "run the tests.") {
            XCTAssertEqual(pipeline.viewModel.context.claudeSessionJoin?.mechanism, .herdrPane, "precondition")
        }
        answered.resolve()
        let done = await settled.wait(for: 1)

        XCTAssertTrue(done)
        XCTAssertEqual(fills.texts, ["run the tests."])
        XCTAssertEqual(focus.pane, "w1:p3", "precondition: the switch happened during the lookup")
        XCTAssertEqual(typed.text, "", "nothing typed into the other pane")
        XCTAssertEqual(pipeline.viewModel.lastError, DictationViewModel.StatusStrings.agentPromptTextKeptInHistory)
        XCTAssertEqual(pipeline.records.all.map(\.rawText), ["run the tests."])
    }

    /// The mod refused a fill and Secure Keyboard Entry sent the words to
    /// the clipboard: the prompt is still empty, so the next dictation into
    /// it starts with no space.
    func testAFillThatEndedOnTheClipboardLeavesNoLeadingSpaceForTheNext() async throws {
        let answered = BoundedWait()
        let (pipeline, _, fills) = try await modChannelPipeline(answers: [.refuse, .fill], answerGate: answered)
        let settled = FillSettled()
        ModChannelOverlayCommitter.debugFillSettled = { settled.note($0) }
        addTeardownBlock { @MainActor in ModChannelOverlayCommitter.debugFillSettled = nil }

        TerminalTargetDetector.debugSecureEventInputOverride = { true }
        await dictate(pipeline, "that's what I was doing.")
        answered.resolve()
        let first = await settled.wait(for: 1)
        XCTAssertEqual(pipeline.viewModel.lastError, DictationViewModel.StatusStrings.overlayCopiedToClipboard)
        TerminalTargetDetector.debugSecureEventInputOverride = { false }
        await dictate(pipeline, "/compact")
        let second = await settled.wait(for: 2)

        XCTAssertEqual(first && second, true, "both fills settled")
        XCTAssertEqual(fills.texts, ["that's what I was doing.", "/compact"])
    }

    // MARK: - Live Auto-Paste through the session's mod (#1645)

    /// Each delta goes to the mod as an append, in order, while the
    /// dictation runs; the stop's ack confirms them all, so no key is typed
    /// and the record says inserted.
    func testLiveAutoPasteIntoAClaudeSessionWithAModFillsEveryDeltaInOrderAndTypesNothing() async throws {
        let mod = FakeClaudeMod()
        let (pipeline, typed) = try await modLivePipeline(mod)

        await startAndSpeak(pipeline)
        XCTAssertTrue(pipeline.viewModel.textInsertion.promptRelaySink?.route is ClaudeModPromptRoute)
        sendPartials(pipeline)
        await stopAndFinalize(pipeline)

        XCTAssertEqual(mod.box, Self.phrase)
        XCTAssertEqual(mod.kinds, [.ack, .append, .append, .ack], "opened, two deltas, the stop's count")
        XCTAssertEqual(typed.text, "", "no key went to the terminal")
        XCTAssertEqual(pipeline.records.all.map(\.commitSucceeded), [true])
    }

    /// The mod stopped filling at the second delta (a gap, or a dialog took
    /// the box): its ack says one landed, so the stop types the second, once,
    /// after the first.
    func testDeltasTheModDidNotFillAreTypedOnceAtTheStop() async throws {
        let split = Self.phrase.index(Self.phrase.startIndex, offsetBy: 18)
        let mod = FakeClaudeMod(refuses: String(Self.phrase[split...]))
        let (pipeline, typed) = try await modLivePipeline(mod)

        await startAndSpeak(pipeline)
        sendPartials(pipeline)
        await stopAndFinalize(pipeline)

        XCTAssertEqual(mod.box, String(Self.phrase[..<split]))
        XCTAssertEqual(typed.text, String(Self.phrase[split...]))
        XCTAssertEqual(pipeline.records.all.map(\.commitSucceeded), [true])
    }

    /// The stop's ack never comes back: every delta may be in the box, so
    /// none is typed, and the record says not inserted.
    func testAnUnansweredStopAckKeepsTheDictationInHistoryAndTypesNothing() async throws {
        let mod = FakeClaudeMod(acksToAnswer: 1)
        // The opening ack is answered; the stop's times out at once.
        let timers = Mutex(0)
        let (pipeline, typed) = try await modLivePipeline(mod, sleep: { _ in
            if timers.withLock({ $0 += 1; return $0 }) == 1 { try? await Task.sleep(for: .seconds(3600)) }
        })

        await startAndSpeak(pipeline)
        sendPartials(pipeline)
        await stopAndFinalize(pipeline, expectedError: DictationViewModel.StatusStrings.agentPromptTextKeptInHistory)

        XCTAssertEqual(typed.text, "")
        XCTAssertEqual(pipeline.records.all.map(\.commitSucceeded), [false])
    }

    /// Secure Keyboard Entry would swallow every key, which refuses a live
    /// start: a mod that takes the deltas posts none, so the dictation runs.
    func testSecureKeyboardEntryDoesNotRefuseALiveDictationTheModTakes() async throws {
        let mod = FakeClaudeMod()
        let (pipeline, typed) = try await modLivePipeline(mod)
        TerminalTargetDetector.debugSecureEventInputOverride = { true }

        await startAndSpeak(pipeline)
        sendPartials(pipeline)
        await stopAndFinalize(pipeline)

        XCTAssertEqual(mod.box, Self.phrase)
        XCTAssertEqual(typed.text, "")
    }

    /// A newline the server sends is filled as text, where the keys would
    /// have turned it into a space so it could not submit the prompt.
    func testANewlineGoesToTheModAsText() async throws {
        let mod = FakeClaudeMod()
        let (pipeline, typed) = try await modLivePipeline(mod)

        await startAndSpeak(pipeline)
        pipeline.server.send(["type": "transcription.delta", "delta": "first line\nsecond line"])
        await stopAndFinalize(pipeline, finalText: "first line\nsecond line")

        XCTAssertEqual(mod.box, "first line\nsecond line")
        XCTAssertEqual(typed.text, "")
    }

    /// Live Auto-Paste joined to Claude Code session `s1` in a terminal by
    /// its tty, with `mod` attached to its channel.
    private func modLivePipeline(
        _ mod: FakeClaudeMod,
        sleep: @escaping @Sendable (Duration) async -> Void = { _ in try? await Task.sleep(for: .seconds(3600)) }
    ) async throws -> (Pipeline, TypedText) {
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        pipeline.viewModel.sessionStore = try XCTUnwrap(DictationSessionStore.inMemory())
        _ = joinClaudeCodeTerminal(pipeline)
        let typed = recordTypedText(pipeline)
        let hub = ClaudeModChannelHub(sleep: sleep)
        mod.attach(to: hub)
        pipeline.viewModel.context.claudeModChannels = hub
        return (pipeline, typed)
    }

    /// How the fake mod answers a fill.
    private enum FakeModAnswer { case fill, refuse, silent, sent, queued }

    /// A dictation joined to Claude Code session `s1` in a terminal, whose
    /// mod answers the fills in turn with `answers`, the last one repeating.
    /// `focus` is the terminal's focused tty, and `beforeAnswer` runs as each
    /// fill arrives, before the mod answers it.
    /// `answerGate`, when given, holds every answer (and a silent mod's
    /// timeout) until it resolves: a test whose fill ends in a status line
    /// opens it once the dictation's own checks are done, since the fill
    /// settles on a task of its own.
    private func modChannelPipeline(
        answers: [FakeModAnswer],
        focus: FocusedPane? = nil,
        herdr: FakeHerdrSocket? = nil,
        herdrFocus: HerdrFocus? = nil,
        answerGate: BoundedWait? = nil,
        drafts: [(text: String, cursor: Int)] = [],
        returnKeyPoster: ((pid_t) -> Bool)? = nil,
        beforeAnswer: @escaping @Sendable () -> Void = {}
    ) async throws -> (Pipeline, TypedText, FillRecorder) {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.sessionStore = try XCTUnwrap(DictationSessionStore.inMemory())
        pipeline.overlay.insertsThroughCommitter = true
        pipeline.overlay.commitTargetAppPID = 4343
        pipeline.overlay.passesTargetPIDToCommitter = false
        if let herdr {
            joinHerdrPane(pipeline, herdr: herdr, ttyRead: { herdrFocus?.read(.tty) })
        } else {
            var focusedTTY: (@Sendable () -> String)?
            if let focus { focusedTTY = { focus.tty } }
            _ = joinClaudeCodeTerminal(pipeline, focusedTTY: focusedTTY)
        }
        let typed = recordTypedText(pipeline, returnKeyPoster: returnKeyPoster)

        // A silent mod's fill times out at once, or when the gate opens;
        // the others' timer never fires before their reply cancels it.
        let sleep: @Sendable (Duration) async -> Void = answers.contains(.silent)
            ? { @Sendable _ in _ = await answerGate?.value(failAfter: 60) }
            : { @Sendable _ in try? await Task.sleep(for: .seconds(3600)) }
        let hub = ClaudeModChannelHub(sleep: sleep)
        let fills = FillRecorder()
        _ = hub.attach(sessionID: "s1", channel: .init(
            write: { line in
                guard let message = ClaudeModChannelWire.decode(
                    ClaudeModChannelWire.Message.self, from: line.dropLast()
                ) else { return false }
                if message.kind == .state {
                    fills.appendState(message.phase, message.text)
                    return true
                }
                if message.kind == .draft {
                    // A mod older than `draft` is one that is never asked.
                    guard !drafts.isEmpty else { return false }
                    let box = drafts[min(fills.takeDraftIndex(), drafts.count - 1)]
                    hub.deliver(.init(sessionID: "s1", id: message.id, ok: true, text: box.text, cursor: box.cursor))
                    return true
                }
                guard message.kind == .fill || message.kind == .send else { return false }
                let answer = answers[min(fills.texts.count, answers.count - 1)]
                fills.append(message.text ?? "", kind: message.kind)
                beforeAnswer()
                if answer != .silent {
                    let ok = answer != .refuse
                    let reply = ClaudeModChannelWire.Reply(
                        sessionID: "s1", id: message.id, ok: ok, reason: ok ? nil : "dialog",
                        submitted: message.kind == .send && ok ? true : nil,
                        queued: answer == .queued ? true : nil
                    )
                    if let answerGate {
                        Task {
                            _ = await answerGate.value(failAfter: 60)
                            hub.deliver(reply)
                        }
                    } else {
                        hub.deliver(reply)
                    }
                }
                return true
            },
            close: {}
        ))
        pipeline.viewModel.context.claudeModChannels = hub
        return (pipeline, typed, fills)
    }

    /// Two sessions in two tabs of one terminal share its app. The user
    /// switched tabs between the pick and the stop: the focused pane no
    /// longer shows the picked session, so the words stay in History.
    func testATabSwitchInTheSameTerminalAfterThePickKeepsTheWordsInHistory() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.sessionStore = try XCTUnwrap(DictationSessionStore.inMemory())
        let waiting = installWaitingSessions(pipeline, ["pay": "/r/payments"])
        let terminalPID: pid_t = 5151
        pipeline.viewModel.dependencies.bundleIdentifier = {
            $0 == terminalPID ? TerminalScreenAllowlist.ghosttyBundleID : nil
        }
        await startAndSpeak(pipeline)
        pipeline.viewModel.session.moveDestination(forward: false)
        await pipeline.viewModel.session.destinationFocusTask?.value
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .session)

        // Same Ghostty, another tab.
        pipeline.overlay.commitTargetAppPID = terminalPID
        waiting.focuser.paneStillShowsSession = false
        sendPartials(pipeline)
        await stopAndFinalize(pipeline, finalStatus: DictationSessionController.DestinationStatus.paneLeftFront)

        XCTAssertEqual(waiting.focuser.readBackSessionIDs, ["pay"])
        XCTAssertEqual(pipeline.overlay.commitCallCount, 0, "the other tab's session never gets the words")
        XCTAssertEqual(pipeline.records.all.first?.commitSucceeded, false)
    }

    /// The picked pane read back at the stop, and the user switched tabs of
    /// the same terminal while the polish ran: the pane is read back again
    /// before the insertion, and the words stay in History (#1056).
    func testATabSwitchWhileThePolishRunsKeepsTheWordsInHistory() async throws {
        let polish = FakePolishingService { "<\($0.inputText)>" }
        let pipeline = try await makePipeline(outputMode: .overlayBuffer, polish: polish, earlyPolish: false)
        pipeline.viewModel.sessionStore = try XCTUnwrap(DictationSessionStore.inMemory())
        let waiting = installWaitingSessions(pipeline, ["pay": "/r/payments"])
        let terminalPID: pid_t = 5151
        pipeline.viewModel.dependencies.bundleIdentifier = {
            $0 == terminalPID ? TerminalScreenAllowlist.ghosttyBundleID : nil
        }
        await polish.holdNextRequest()

        await startAndSpeak(pipeline)
        pipeline.viewModel.session.moveDestination(forward: false)
        await pipeline.viewModel.session.destinationFocusTask?.value
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .session)
        pipeline.overlay.commitTargetAppPID = terminalPID
        pipeline.viewModel.stopDictation(reason: "test")
        await pipeline.server.awaitFrame("the final commit") { $0.isFinalCommit }
        pipeline.server.send(["type": "transcription.done", "text": Self.phrase])
        let polishing = await waitForPolishRequests(polish, 1)
        XCTAssertTrue(polishing, "the polish never started")
        XCTAssertEqual(waiting.focuser.readBackSessionIDs, ["pay"], "read back before the polish")

        // Same Ghostty, another tab, while the polish runs.
        waiting.focuser.paneStillShowsSession = false
        await polish.releaseHeldRequest()
        let recorded = await pipeline.records.waitForCount(1)
        XCTAssertTrue(recorded)

        XCTAssertEqual(waiting.focuser.readBackSessionIDs, ["pay", "pay"], "and again before the insertion")
        XCTAssertEqual(pipeline.overlay.commitCallCount, 0, "the other tab's session never gets the words")
        XCTAssertEqual(pipeline.records.all.first?.rawText, Self.phrase)
        XCTAssertEqual(pipeline.records.all.first?.commitSucceeded, false)
        XCTAssertEqual(pipeline.viewModel.statusText, DictationSessionController.DestinationStatus.paneLeftFront)
    }

    /// A dictation joined to a Claude Code session in a terminal tab, with
    /// no pane picked, no relay and no mod: the user switched to another tab
    /// of the same terminal while the polish ran. The joined pane is read
    /// back before the keys, so the other tab's prompt gets nothing, and the
    /// text is saved not inserted and copied (#1668).
    func testATabSwitchWhileAJoinedDictationPolishesTypesNothing() async throws {
        let (pipeline, polish, focuser) = try await joinedTerminalPipelineWithHeldPolish()
        let copied = pipeline.viewModel.recordPasteboardWrites()

        await startAndSpeak(pipeline)
        await stopWithHeldPolish(pipeline, polish)
        // Same Ghostty, another tab, while the polish runs.
        focuser.paneStillShowsSession = false
        await polish.releaseHeldRequest()
        let recorded = await pipeline.records.waitForCount(1)
        XCTAssertTrue(recorded)

        XCTAssertEqual(focuser.readBackSessionIDs, ["s1"], "read back before the keys")
        XCTAssertEqual(pipeline.overlay.commitCallCount, 0, "the other tab's session never gets the words")
        XCTAssertEqual(pipeline.records.all.count, 1)
        XCTAssertEqual(pipeline.records.all.first?.rawText, Self.phrase)
        XCTAssertEqual(pipeline.records.all.first?.commitSucceeded, false)
        XCTAssertEqual(copied.values.count, 1)
        XCTAssertEqual(pipeline.viewModel.statusText, DictationViewModel.StatusStrings.overlayCopiedToClipboard)
    }

    /// The same joined dictation whose pane is still in front after the
    /// polish is typed as before.
    func testAJoinedDictationWhosePaneStaysInFrontIsTypedAfterThePolish() async throws {
        let (pipeline, polish, focuser) = try await joinedTerminalPipelineWithHeldPolish()

        await startAndSpeak(pipeline)
        await stopWithHeldPolish(pipeline, polish)
        await polish.releaseHeldRequest()
        let recorded = await pipeline.records.waitForCount(1)
        XCTAssertTrue(recorded)

        XCTAssertEqual(focuser.readBackSessionIDs, ["s1"])
        XCTAssertEqual(pipeline.overlay.commitCallCount, 1)
        XCTAssertEqual(pipeline.records.all.first?.commitSucceeded, true)
    }

    /// An Overlay Buffer dictation joined to Claude Code session `s1` in a
    /// Ghostty tab by its tty, with a navigator that reads the pane back
    /// through the returned focuser and a polish that holds its request.
    private func joinedTerminalPipelineWithHeldPolish(
    ) async throws -> (Pipeline, FakePolishingService, FakeSessionPaneFocuser) {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer, earlyPolish: false)
        pipeline.viewModel.sessionStore = try XCTUnwrap(DictationSessionStore.inMemory())
        let registry = joinClaudeCodeTerminal(pipeline)
        let polish = FakePolishingService { "<\($0.inputText)>" }
        pipeline.viewModel.llmPolishingService = polish
        pipeline.overlay.commitTargetAppPID = 4343
        let focuser = FakeSessionPaneFocuser()
        pipeline.viewModel.session.sessionNavigator = SessionNavigator(
            liveSessions: { registry.liveSessions() },
            repositoryRoot: { _ in .unknown },
            focuser: focuser,
            sleep: ManualSessionClock().sleep,
            ttyForegroundPIDs: { _ in [9001] }
        )
        await polish.holdNextRequest()
        return (pipeline, polish, focuser)
    }

    /// Stops the dictation and returns once its polish request is held.
    private func stopWithHeldPolish(
        _ pipeline: Pipeline, _ polish: FakePolishingService, file: StaticString = #filePath, line: UInt = #line
    ) async {
        pipeline.viewModel.stopDictation(reason: "test")
        await pipeline.server.awaitFrame("the final commit") { $0.isFinalCommit }
        pipeline.server.send(["type": "transcription.done", "text": Self.phrase])
        let polishing = await waitForPolishRequests(polish, 1)
        XCTAssertTrue(polishing, "the polish never started", file: file, line: line)
    }

    /// Focus moved to another app between the pick and the stop: the words
    /// must not follow it. They stay in History as not inserted, and the
    /// popover says why.
    func testAPickedSessionWhoseAppLeftTheFrontKeepsTheWordsInHistory() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.sessionStore = try XCTUnwrap(DictationSessionStore.inMemory())
        _ = installWaitingSessions(pipeline, ["pay": "/r/payments"])
        let otherAppPID: pid_t = 6262
        pipeline.viewModel.dependencies.bundleIdentifier = {
            $0 == otherAppPID ? "com.apple.Safari" : TerminalScreenAllowlist.ghosttyBundleID
        }

        await startAndSpeak(pipeline)
        pipeline.viewModel.session.moveDestination(forward: false)
        await pipeline.viewModel.session.destinationFocusTask?.value
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .session)

        // The user clicked into Safari before stopping.
        pipeline.overlay.commitTargetAppPID = otherAppPID
        sendPartials(pipeline)
        await stopAndFinalize(pipeline, finalStatus: DictationSessionController.DestinationStatus.paneLeftFront)

        XCTAssertEqual(pipeline.overlay.commitCallCount, 0, "nothing reaches the app that took the focus")
        let record = try XCTUnwrap(pipeline.records.all.first)
        XCTAssertFalse(record.commitSucceeded)
        XCTAssertEqual(record.rawText, Self.phrase)
    }

    /// With History off, the words the picked destination did not get go
    /// on the clipboard: the next dictation would replace the only copy
    /// (#1546).
    func testAPickedSessionWhoseAppLeftTheFrontWithHistoryOffCopiesTheWords() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.settings.dictationHistoryRetention = .off
        let copied = pipeline.viewModel.recordPasteboardWrites()
        _ = installWaitingSessions(pipeline, ["pay": "/r/payments"])
        let otherAppPID: pid_t = 6262
        pipeline.viewModel.dependencies.bundleIdentifier = {
            $0 == otherAppPID ? "com.apple.Safari" : TerminalScreenAllowlist.ghosttyBundleID
        }

        await startAndSpeak(pipeline)
        pipeline.viewModel.session.moveDestination(forward: false)
        await pipeline.viewModel.session.destinationFocusTask?.value
        pipeline.overlay.commitTargetAppPID = otherAppPID
        sendPartials(pipeline)
        await stopAndFinalize(pipeline, finalStatus: DictationViewModel.StatusStrings.overlayCopiedToClipboard)

        XCTAssertEqual(pipeline.overlay.commitCallCount, 0, "nothing reaches the app that took the focus")
        XCTAssertEqual(copied.values, [Self.phrase])
    }

    /// The tab switch while the polish runs, with History off: the words go
    /// on the clipboard (#1546).
    func testATabSwitchWhileThePolishRunsWithHistoryOffCopiesTheWords() async throws {
        let polish = FakePolishingService { "<\($0.inputText)>" }
        let pipeline = try await makePipeline(outputMode: .overlayBuffer, polish: polish, earlyPolish: false)
        pipeline.viewModel.settings.dictationHistoryRetention = .off
        let copied = pipeline.viewModel.recordPasteboardWrites()
        let waiting = installWaitingSessions(pipeline, ["pay": "/r/payments"])
        let terminalPID: pid_t = 5151
        pipeline.viewModel.dependencies.bundleIdentifier = {
            $0 == terminalPID ? TerminalScreenAllowlist.ghosttyBundleID : nil
        }
        await polish.holdNextRequest()

        await startAndSpeak(pipeline)
        pipeline.viewModel.session.moveDestination(forward: false)
        await pipeline.viewModel.session.destinationFocusTask?.value
        pipeline.overlay.commitTargetAppPID = terminalPID
        pipeline.viewModel.stopDictation(reason: "test")
        await pipeline.server.awaitFrame("the final commit") { $0.isFinalCommit }
        pipeline.server.send(["type": "transcription.done", "text": Self.phrase])
        let polishing = await waitForPolishRequests(polish, 1)
        XCTAssertTrue(polishing, "the polish never started")

        waiting.focuser.paneStillShowsSession = false
        await polish.releaseHeldRequest()
        let recorded = await pipeline.records.waitForCount(1)
        XCTAssertTrue(recorded)

        XCTAssertEqual(pipeline.overlay.commitCallCount, 0)
        XCTAssertEqual(copied.values, ["<\(Self.phrase)>"], "the polished text, as it would have been inserted")
        XCTAssertEqual(pipeline.viewModel.statusText, DictationViewModel.StatusStrings.overlayCopiedToClipboard)
    }

    /// A pane the terminal did not confirm never gets the words: the overlay
    /// stays on the focused app and the popover says why.
    func testAnUnconfirmedPaneLeavesTheWordsOnTheFocusedApp() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        let waiting = installWaitingSessions(
            pipeline, ["pay": "/r/payments"],
            outcome: .unverified(bundleID: TerminalScreenAllowlist.ghosttyBundleID)
        )

        await startAndSpeak(pipeline)
        pipeline.viewModel.session.moveDestination(forward: false)
        await pipeline.viewModel.session.destinationFocusTask?.value

        XCTAssertEqual(waiting.focuser.focusedSessionIDs, ["pay"])
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .focusedApp(joined: nil))
        XCTAssertEqual(pipeline.viewModel.statusText, DictationSessionController.AnswerAgentStatus.unconfirmed)
        XCTAssertFalse(waiting.tracker.queue.isEmpty, "an unreached session still needs you")
        pipeline.viewModel.session.cancelDictation()
    }

    /// ⇧Tab from the focused app wraps to the last session. Tab from there
    /// wraps back to a focused app in the same terminal, with no session to
    /// find its pane by: activating the terminal would show the session
    /// pane, so the overlay refuses and stays on the session.
    func testTabBackToTheSameTerminalWithNoSessionIsRefused() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        let terminalPID: pid_t = 4343
        pipeline.overlay.commitTargetAppPID = terminalPID
        var activated: [pid_t] = []
        pipeline.viewModel.dependencies.bundleIdentifier = { _ in TerminalScreenAllowlist.ghosttyBundleID }
        pipeline.viewModel.dependencies.activateApp = {
            activated.append($0)
            return true
        }
        _ = installWaitingSessions(pipeline, ["pay": "/r/payments"])

        await startAndSpeak(pipeline)
        pipeline.viewModel.session.moveDestination(forward: false)
        await pipeline.viewModel.session.destinationFocusTask?.value
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .session)

        pipeline.viewModel.session.moveDestination(forward: true)
        await pipeline.viewModel.session.destinationFocusTask?.value
        XCTAssertEqual(activated, [], "activating the terminal would bring the session pane, not the start")
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .session)
        XCTAssertEqual(pipeline.viewModel.statusText, DictationSessionController.DestinationStatus.cantGoBack)

        // Another app comes back by activation.
        pipeline.viewModel.dependencies.bundleIdentifier = {
            $0 == terminalPID ? "com.apple.Safari" : TerminalScreenAllowlist.ghosttyBundleID
        }
        pipeline.viewModel.session.moveDestination(forward: true)
        await pipeline.viewModel.session.destinationFocusTask?.value
        XCTAssertEqual(activated, [terminalPID])
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .focusedApp(joined: nil))
        pipeline.viewModel.session.cancelDictation()
    }

    /// A stop while a Tab is still bringing a pane forward cannot know which
    /// window will be in front when the words go in: they stay in History.
    func testAStopWhileAPaneIsComingForwardKeepsTheWordsInHistory() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.sessionStore = try XCTUnwrap(DictationSessionStore.inMemory())
        _ = installWaitingSessions(pipeline, ["pay": "/r/payments"])
        await startAndSpeak(pipeline)
        sendPartials(pipeline)

        pipeline.viewModel.session.moveDestination(forward: false)
        // The focus task has not run yet.
        await stopAndFinalize(pipeline, finalStatus: DictationSessionController.DestinationStatus.stoppedWhileSwitching)

        XCTAssertEqual(pipeline.overlay.commitCallCount, 0)
        XCTAssertEqual(pipeline.records.all.first?.commitSucceeded, false)
    }

    /// A pick still bringing a pane forward when its dictation is cancelled
    /// belongs to that dictation: once the pane comes forward during the
    /// next one, a quick capture, it picks nothing there, and the capture's
    /// words go only to the Inbox.
    func testOldQueuedPickCannotRedirectANewInboxCapture() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        let waiting = installWaitingSessions(pipeline, ["pay": "/r/payments"])
        waiting.focuser.holdsFocus = true
        let captured = QuickCaptures()
        pipeline.viewModel.session.onQuickCapture = { text, _, _ in captured.all.append((text, 0)) }
        // Were the pane picked, the words would go into it.
        let terminalPID: pid_t = 5151
        pipeline.overlay.commitTargetAppPID = terminalPID
        pipeline.viewModel.dependencies.bundleIdentifier = { _ in TerminalScreenAllowlist.ghosttyBundleID }

        await startAndSpeak(pipeline)
        pipeline.viewModel.session.moveDestination(forward: false)
        let sessionPick = try XCTUnwrap(pipeline.viewModel.session.destinationFocusTask)
        await waiting.focuser.waitUntilHeld(1)
        XCTAssertTrue(pipeline.viewModel.session.pickInboxOrStop(), "the Inbox pick queues behind the session's")
        pipeline.viewModel.cancelDictation()

        pipeline.server.forgetFrames()
        await startAndSpeak(pipeline, start: { $0.session.toggleQuickCapture() })
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .inbox)
        waiting.focuser.releaseHeldFocuses()
        await sessionPick.value

        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .inbox)
        XCTAssertTrue(pipeline.viewModel.session.sessionIsQuickCapture)
        sendPartials(pipeline)
        await stopAndFinalize(pipeline, finalStatus: DictationViewModel.StatusStrings.quickCaptureSaved)
        XCTAssertEqual(pipeline.overlay.commitCallCount, 0, "nothing reaches the pane")
        XCTAssertEqual(waiting.focuser.readBackSessionIDs, [])
        XCTAssertEqual(captured.all.map(\.text), [Self.phrase])
    }

    /// An unconfirmed pane may still have come forward. Staying on the
    /// focused app, the words go in only if the focused app is still the
    /// commit target; here the pane's terminal is, so they stay in History.
    func testAnUnconfirmedPaneInFrontAtStopKeepsTheWordsInHistory() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.sessionStore = try XCTUnwrap(DictationSessionStore.inMemory())
        _ = installWaitingSessions(
            pipeline, ["pay": "/r/payments"],
            outcome: .unverified(bundleID: TerminalScreenAllowlist.ghosttyBundleID)
        )
        let originPID: pid_t = 7070
        let terminalPID: pid_t = 7171
        pipeline.overlay.commitTargetAppPID = originPID
        pipeline.viewModel.dependencies.bundleIdentifier = {
            $0 == originPID ? "com.apple.Safari" : TerminalScreenAllowlist.ghosttyBundleID
        }
        await startAndSpeak(pipeline)
        pipeline.viewModel.session.moveDestination(forward: false)
        await pipeline.viewModel.session.destinationFocusTask?.value
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .focusedApp(joined: nil))

        pipeline.overlay.commitTargetAppPID = terminalPID
        sendPartials(pipeline)
        await stopAndFinalize(pipeline, finalStatus: DictationSessionController.DestinationStatus.originLeftFront)
        XCTAssertEqual(pipeline.overlay.commitCallCount, 0, "the unconfirmed pane never gets the words")
    }

    /// ← and → move as ⇧Tab and Tab do (#880), each through the key
    /// handler the overlay registers: forward to the Inbox at once, forward
    /// again to the waiting session once its pane is confirmed, then back to
    /// the Inbox and on to the focused app, brought back over the pane.
    func testTheArrowsMoveBetweenDestinationsAsTabDoes() async throws {
        let expected: [OverlayDestinationStrip.Kind?] = [.inbox, .session, .inbox, .focusedApp(joined: nil)]
        for (back, forward) in [(DestinationKeyHandler.Key.shiftTab, DestinationKeyHandler.Key.tab), (.leftArrow, .rightArrow)] {
            let pipeline = try await makePipeline(outputMode: .overlayBuffer)
            let waiting = installWaitingSessions(pipeline, ["pay": "/r/payments"])
            let originPID: pid_t = 8080
            pipeline.overlay.commitTargetAppPID = originPID
            pipeline.viewModel.dependencies.bundleIdentifier = {
                $0 == originPID ? "com.apple.Safari" : TerminalScreenAllowlist.ghosttyBundleID
            }
            var activated: [pid_t] = []
            pipeline.viewModel.dependencies.activateApp = {
                activated.append($0)
                return true
            }
            await startAndSpeak(pipeline)

            var picked: [OverlayDestinationStrip.Kind?] = []
            for key in [forward, forward, back, back] {
                pipeline.viewModel.session.destinationKeyHandler.handle(key)
                await pipeline.viewModel.session.destinationFocusTask?.value
                picked.append(pipeline.overlay.shownDestinations.last??.selectedKind)
            }
            XCTAssertEqual(picked, expected, "\(back) and \(forward)")
            XCTAssertEqual(waiting.focuser.focusedSessionIDs, ["pay"], "\(back) and \(forward)")
            XCTAssertEqual(activated, [originPID], "\(back) and \(forward)")
            pipeline.viewModel.session.cancelDictation()
        }
    }

    /// A click on a waiting session (#880) picks it through the path Tab
    /// takes: its pane comes forward, the overlay moves only once the
    /// terminal confirmed it, and the stop reads back that the pane still
    /// shows the session before the words go in.
    func testAClickOnAWaitingSessionBringsItsPaneForwardAndCommitsThere() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        let waiting = installWaitingSessions(pipeline, ["pay": "/r/payments"])
        let terminalPID: pid_t = 5151
        pipeline.viewModel.dependencies.bundleIdentifier = {
            $0 == terminalPID ? TerminalScreenAllowlist.ghosttyBundleID : nil
        }
        await startAndSpeak(pipeline)

        pipeline.viewModel.session.clickDestination(.session(id: "pay"))
        XCTAssertEqual(
            pipeline.overlay.shownDestinations.last??.selectedKind, .focusedApp(joined: nil),
            "the overlay waits for the pane"
        )
        await pipeline.viewModel.session.destinationFocusTask?.value
        XCTAssertEqual(waiting.focuser.focusedSessionIDs, ["pay"])
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .session)

        pipeline.viewModel.session.clickDestination(.session(id: "pay"))
        await pipeline.viewModel.session.destinationFocusTask?.value
        XCTAssertEqual(waiting.focuser.focusedSessionIDs, ["pay"], "a click on the picked session does nothing")

        pipeline.overlay.commitTargetAppPID = terminalPID
        sendPartials(pipeline)
        await stopAndFinalize(pipeline)
        XCTAssertEqual(pipeline.overlay.committedTexts, [Self.phrase])
        XCTAssertEqual(waiting.focuser.readBackSessionIDs, ["pay"], "the stop asked which session the pane shows")
    }

    /// A click on a session the terminal does not confirm leaves the overlay
    /// on the focused app, as Tab does.
    func testAClickOnAnUnconfirmedPaneLeavesTheWordsOnTheFocusedApp() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        let waiting = installWaitingSessions(
            pipeline, ["pay": "/r/payments"],
            outcome: .unverified(bundleID: TerminalScreenAllowlist.ghosttyBundleID)
        )
        await startAndSpeak(pipeline)

        pipeline.viewModel.session.clickDestination(.session(id: "pay"))
        await pipeline.viewModel.session.destinationFocusTask?.value

        XCTAssertEqual(waiting.focuser.focusedSessionIDs, ["pay"])
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .focusedApp(joined: nil))
        XCTAssertEqual(pipeline.viewModel.statusText, DictationSessionController.AnswerAgentStatus.unconfirmed)
        pipeline.viewModel.session.cancelDictation()
    }

    /// A stop while a clicked session's pane is still coming forward keeps
    /// the words in History, as after a Tab.
    func testAStopWhileAClickedPaneIsComingForwardKeepsTheWordsInHistory() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.sessionStore = try XCTUnwrap(DictationSessionStore.inMemory())
        _ = installWaitingSessions(pipeline, ["pay": "/r/payments"])
        await startAndSpeak(pipeline)
        sendPartials(pipeline)

        pipeline.viewModel.session.clickDestination(.session(id: "pay"))
        await stopAndFinalize(pipeline, finalStatus: DictationSessionController.DestinationStatus.stoppedWhileSwitching)

        XCTAssertEqual(pipeline.overlay.commitCallCount, 0)
        XCTAssertEqual(pipeline.records.all.first?.commitSucceeded, false)
    }

    /// A click on the Inbox picks it at once: the stop saves a quick capture
    /// and nothing reaches the focused app. A click on a session that is not
    /// listed does nothing.
    func testAClickOnTheInboxSavesTheDictationThere() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        let captured = QuickCaptures()
        pipeline.viewModel.session.onQuickCapture = { text, _, _ in captured.all.append((text, 0)) }
        await startAndSpeak(pipeline)

        pipeline.viewModel.session.clickDestination(.session(id: "gone"))
        XCTAssertNil(pipeline.viewModel.session.destinationFocusTask)
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .focusedApp(joined: nil))

        pipeline.viewModel.session.clickDestination(.inbox)
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .inbox)

        sendPartials(pipeline)
        await stopAndFinalize(pipeline, finalStatus: DictationViewModel.StatusStrings.quickCaptureSaved)
        XCTAssertEqual(pipeline.overlay.commitCallCount, 0, "nothing reaches the focused app")
        XCTAssertEqual(captured.all.map(\.text), [Self.phrase])
    }

    /// The answer shortcut during a dictation picks the oldest session that
    /// needs you, as Tab would; pressed on it, it stops.
    func testTheAnswerKeyDuringADictationPicksTheWaitingSessionThenStops() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        let waiting = installWaitingSessions(pipeline, ["pay": "/r/payments"])
        await startAndSpeak(pipeline)

        pipeline.viewModel.session.answerAgentThatNeedsYou()
        await pipeline.viewModel.session.destinationFocusTask?.value
        XCTAssertTrue(pipeline.viewModel.isDictating)
        XCTAssertEqual(waiting.focuser.focusedSessionIDs, ["pay"])
        XCTAssertEqual(pipeline.overlay.shownDestinations.last??.selectedKind, .session)

        pipeline.viewModel.session.answerAgentThatNeedsYou()
        XCTAssertFalse(pipeline.viewModel.isDictating, "pressed on the picked session, it stops")
        pipeline.server.send(["type": "transcription.done", "text": Self.phrase])
        _ = await pipeline.records.waitForCount(1)
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

    /// The relay refused an Overlay Buffer commit and Secure Keyboard Entry
    /// sent the words to the clipboard: the joined session's prompt is still
    /// empty, so the next dictation into it, a slash command, starts with no
    /// space (#1426).
    func testARelayCommitThatEndedOnTheClipboardLeavesNoLeadingSpaceForTheNext() async throws {
        // The first append's answer waits for the test, so the refusal
        // arrives after the stop has settled.
        let answerFirst = DispatchSemaphore(value: 0)
        let relay = try FakeOpencodePromptRelay { call in
            guard call.text == "/compact" else {
                _ = answerFirst.wait(timeout: .now() + 10)
                return 500
            }
            return 200
        }
        addTeardownBlock { relay.stop() }
        addTeardownBlock { answerFirst.signal() }
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.overlay.insertsThroughCommitter = true
        pipeline.overlay.commitTargetAppPID = 4343
        pipeline.overlay.passesTargetPIDToCommitter = false
        joinOpencodePane(pipeline, relay: relay.relay(sessionID: "ses_a").address)
        // Polishing on: the context join is what lets a commit continue the
        // prompt.
        pipeline.viewModel.settings.llmPolishingEnabled = true
        pipeline.viewModel.settings.llmPolishingEndpointURL = "http://127.0.0.1:8080/v1/chat/completions"
        pipeline.viewModel.settings.terminalScreenContextEnabled = true
        pipeline.viewModel.llmPolishingService = FakePolishingService()
        let typed = recordTypedText(pipeline)

        var sink: AgentPromptSink?
        await dictate(pipeline, "that's what I was doing.") {
            XCTAssertEqual(pipeline.viewModel.context.claudeSessionJoin?.snapshot.sessionID, "opencode:ses_a")
            sink = pipeline.viewModel.textInsertion.promptRelaySink
        }
        TerminalTargetDetector.debugSecureEventInputOverride = { true }
        answerFirst.signal()
        await sink?.waitUntilIdle()
        XCTAssertEqual(pipeline.viewModel.lastError, DictationViewModel.StatusStrings.overlayCopiedToClipboard)
        TerminalTargetDetector.debugSecureEventInputOverride = { false }

        await dictate(pipeline, "/compact")
        let appended = await relay.waitForCalls(2)
        XCTAssertTrue(appended, "calls: \(relay.calls)")
        XCTAssertEqual(relay.calls.map(\.text), ["that's what I was doing.", "/compact"])
        XCTAssertEqual(typed.text, "", "no key went to the terminal")
    }

    /// The relay answers 409, the pane shows another session now: the words
    /// stay in History, nothing is typed, and the record says not inserted.
    func testLiveAutoPasteTextTheRelayKeptInHistoryIsSavedAsNotInserted() async throws {
        let relay = try FakeOpencodePromptRelay { _ in 409 }
        addTeardownBlock { relay.stop() }
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        pipeline.viewModel.sessionStore = try XCTUnwrap(DictationSessionStore.inMemory())
        joinOpencodePane(pipeline, relay: relay.relay(sessionID: "ses_a").address)
        let typed = recordTypedText(pipeline)

        await startAndSpeak(pipeline)
        let sink = try XCTUnwrap(pipeline.viewModel.textInsertion.promptRelaySink)
        sendPartials(pipeline)
        let refused = await relay.waitForCalls(1)
        XCTAssertTrue(refused)
        await sink.waitUntilIdle()
        XCTAssertFalse(sink.isHealthy, "precondition: the refusal arrived before the stop")

        await stopAndFinalize(
            pipeline, expectedError: DictationViewModel.StatusStrings.agentPromptTextKeptInHistory
        )

        XCTAssertEqual(typed.text, "", "nothing is typed")
        XCTAssertEqual(pipeline.records.all.map(\.rawText), [Self.phrase])
        XCTAssertEqual(pipeline.records.all.first?.commitSucceeded, false)
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
    /// Dictation 1's append is still open when dictation 2 appends to the
    /// same prompt; then dictation 1's route refuses it, with keys allowed.
    /// The late text stays in History and never rides dictation 2's route
    /// or keys (#1466).
    func testLateRelayRefusalCannotEnterTheNextDictation() async throws {
        let firstArrived = BoundedWait()
        let releaseFirst = BoundedWait()
        let firstRoute = ScriptedPromptRoute { _ in
            firstArrived.resolve()
            _ = await releaseFirst.value(failAfter: 10)
            return .typeInstead
        }
        let secondArrived = BoundedWait()
        let secondRoute = ScriptedPromptRoute { _ in
            secondArrived.resolve()
            return .delivered
        }
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        pipeline.viewModel.sessionStore = try XCTUnwrap(DictationSessionStore.inMemory())
        let typed = recordTypedText(pipeline)

        await dictate(pipeline, "First.") { armPromptRoute(pipeline, firstRoute) }
        let firstSink = pipeline.viewModel.textInsertion.promptRelaySink
        let firstInFlight = await firstArrived.value(failAfter: 10)
        XCTAssertTrue(firstInFlight, "precondition: dictation 1's append is still open")

        pipeline.server.forgetFrames()
        await startAndSpeak(pipeline)
        armPromptRoute(pipeline, secondRoute)
        let secondSink = try XCTUnwrap(pipeline.viewModel.textInsertion.promptRelaySink)
        pipeline.server.send(["type": "transcription.delta", "delta": "Second."])
        let secondDelivered = await secondArrived.value(failAfter: 10)
        XCTAssertTrue(secondDelivered)

        releaseFirst.resolve()
        await firstSink?.waitUntilIdle()
        await secondSink.waitUntilIdle()

        await stopAndFinalize(
            pipeline, finalText: "Second.",
            expectedError: DictationViewModel.StatusStrings.agentPromptTextKeptInHistory
        )
        XCTAssertEqual(firstRoute.calls, [.append("First.")])
        XCTAssertEqual(secondRoute.calls, [.append("Second.")], "dictation 2's route carries only its own text")
        XCTAssertEqual(typed.text, "", "the late text is typed nowhere")
    }

    /// An Overlay Buffer commit's own relay fallback: dictation 1's append
    /// is refused after dictation 2 started. The text is kept (on the
    /// clipboard, History being off) and typed nowhere (#1657).
    func testLateOverlayRelayRefusalIsKeptNotTypedIntoTheNextDictation() async throws {
        let firstArrived = BoundedWait()
        let releaseFirst = BoundedWait()
        let firstRoute = ScriptedPromptRoute { _ in
            firstArrived.resolve()
            _ = await releaseFirst.value(failAfter: 10)
            return .typeInstead
        }
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.overlay.insertsThroughCommitter = true
        pipeline.viewModel.settings.dictationHistoryRetention = .off
        pipeline.viewModel.settings.autoCopyEnabled = false
        let copiedOnce = BoundedWait()
        let copied = pipeline.viewModel.recordPasteboardWrites { copiedOnce.resolve() }
        let typed = recordTypedText(pipeline)

        await dictate(pipeline, "First.") { armPromptRoute(pipeline, firstRoute) }
        let firstInFlight = await firstArrived.value(failAfter: 10)
        XCTAssertTrue(firstInFlight, "precondition: dictation 1's append is still open")

        pipeline.viewModel.context.agentPromptRoute = nil
        pipeline.server.forgetFrames()
        await startAndSpeak(pipeline)
        releaseFirst.resolve()
        let kept = await copiedOnce.value(failAfter: 10)
        pipeline.server.send(["type": "transcription.delta", "delta": "Second."])
        await stopAndFinalize(pipeline, finalText: "Second.")

        XCTAssertTrue(kept, "the late text is kept")
        XCTAssertEqual(copied.values, ["First."])
        XCTAssertEqual(firstRoute.calls, [.append("First.")])
        XCTAssertEqual(typed.text, "Second.", "the late text is typed nowhere")
    }

    /// Dictation 1's relay refuses after dictation 2 committed to the same
    /// prompt. The refusal forgets dictation 1's landing, not dictation 2's:
    /// dictation 3 still continues dictation 2's text with a space.
    func testALateOverlayRelayRefusalKeepsTheNextCommitsLanding() async throws {
        let relay = try FakeOpencodePromptRelay()
        addTeardownBlock { relay.stop() }
        let firstArrived = BoundedWait()
        let releaseFirst = BoundedWait()
        let route = ScriptedPromptRoute { call in
            guard call == .append("that's what I was doing.") else { return .delivered }
            firstArrived.resolve()
            _ = await releaseFirst.value(failAfter: 10)
            return .typeInstead
        }
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.overlay.insertsThroughCommitter = true
        pipeline.overlay.commitTargetAppPID = 4343
        pipeline.overlay.passesTargetPIDToCommitter = false
        joinOpencodePane(pipeline, relay: relay.relay(sessionID: "ses_a").address)
        // Polishing on: the context join is what lets a commit continue the
        // prompt.
        pipeline.viewModel.settings.llmPolishingEnabled = true
        pipeline.viewModel.settings.llmPolishingEndpointURL = "http://127.0.0.1:8080/v1/chat/completions"
        pipeline.viewModel.settings.terminalScreenContextEnabled = true
        pipeline.viewModel.llmPolishingService = FakePolishingService()
        pipeline.viewModel.settings.dictationHistoryRetention = .off
        pipeline.viewModel.settings.autoCopyEnabled = false
        let copiedOnce = BoundedWait()
        let copied = pipeline.viewModel.recordPasteboardWrites { copiedOnce.resolve() }
        let typed = recordTypedText(pipeline)

        await dictate(pipeline, "that's what I was doing.") { armPromptRoute(pipeline, route) }
        let firstInFlight = await firstArrived.value(failAfter: 10)
        XCTAssertTrue(firstInFlight, "precondition: dictation 1's append is still open")
        await dictate(pipeline, "Usually") { armPromptRoute(pipeline, route) }
        XCTAssertNotNil(pipeline.viewModel.session.lastOverlayCommitLanding, "precondition: dictation 2 landed")

        releaseFirst.resolve()
        let kept = await copiedOnce.value(failAfter: 10)
        var sink: AgentPromptSink?
        await dictate(pipeline, "it works.") {
            armPromptRoute(pipeline, route)
            sink = pipeline.viewModel.textInsertion.promptRelaySink
        }
        await sink?.waitUntilIdle()

        XCTAssertTrue(kept, "dictation 1's refused text is kept")
        XCTAssertEqual(copied.values, ["that's what I was doing."])
        XCTAssertEqual(route.calls.last, .append(" it works."), "calls: \(route.calls)")
        XCTAssertEqual(typed.text, "")
        XCTAssertEqual(relay.calls, [], "every call took the scripted route")
    }

    /// The same for a fill the session's mod refuses after the next
    /// dictation started, with the session's pane still in front (#1657).
    func testAModFillRefusedAfterTheNextDictationStartedIsKeptNotTyped() async throws {
        let answered = BoundedWait()
        let (pipeline, typed, fills) = try await modChannelPipeline(answers: [.refuse], answerGate: answered)
        pipeline.viewModel.settings.dictationHistoryRetention = .off
        pipeline.viewModel.settings.autoCopyEnabled = false
        let copied = pipeline.viewModel.recordPasteboardWrites()
        let settled = FillSettled()
        ModChannelOverlayCommitter.debugFillSettled = { settled.note($0) }
        addTeardownBlock { @MainActor in ModChannelOverlayCommitter.debugFillSettled = nil }

        await dictate(pipeline, "run the tests.")
        pipeline.server.forgetFrames()
        await startAndSpeak(pipeline)
        answered.resolve()
        let done = await settled.wait(for: 1)
        pipeline.viewModel.context.claudeModChannels = nil
        pipeline.server.send(["type": "transcription.delta", "delta": "/compact"])
        await stopAndFinalize(pipeline, finalText: "/compact")

        XCTAssertTrue(done)
        XCTAssertEqual(fills.texts, ["run the tests."])
        XCTAssertEqual(copied.values, ["run the tests."])
        XCTAssertEqual(typed.text, "/compact", "the refused fill is typed nowhere")
    }

    /// Arms `route` for the dictation running now, as its start would.
    private func armPromptRoute(_ pipeline: Pipeline, _ route: any AgentPromptRoute) {
        pipeline.viewModel.context.agentPromptRoute = route
        pipeline.viewModel.session.armPromptRelayForSession()
    }

    // MARK: - A realtime error during the stop (#1482)

    /// The backend answers the stop's final commit with an error and sends
    /// nothing more: the stop says its end may be missing instead of Ready,
    /// and the icon stays red.
    func testBackendErrorDuringStopIsReported() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)

        await startAndSpeak(pipeline)
        await stopWithBackendError(pipeline)

        let reported = await waitUntilObserved {
            pipeline.viewModel.statusText == DictationViewModel.StatusStrings.dictationEndMayBeMissing
        }
        XCTAssertTrue(reported, "status: \(pipeline.viewModel.statusText)")
        XCTAssertFalse(pipeline.viewModel.isFinalizingStop)
        XCTAssertEqual(pipeline.viewModel.lastError, DictationViewModel.StatusStrings.dictationEndMayBeMissing)
        XCTAssertEqual(pipeline.viewModel.session.realtimeSessionIndicatorState, .recentFailure)
    }

    /// The same error after words arrived: they are inserted and saved once,
    /// and the stop still reports the failure.
    func testBackendErrorDuringStopKeepsTheTextBeforeIt() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.overlay.insertsThroughCommitter = true
        let typed = recordTypedText(pipeline)
        let prefix = "the words before the error."

        await startAndSpeak(pipeline)
        pipeline.server.send(["type": "transcription.delta", "delta": prefix])
        await stopWithBackendError(pipeline)

        let recorded = await pipeline.records.waitForCount(1)
        XCTAssertTrue(recorded, "the session never wrote its record")
        XCTAssertEqual(pipeline.records.all.map(\.rawText), [prefix])
        XCTAssertEqual(pipeline.overlay.commitCallCount, 1)
        XCTAssertEqual(typed.text, prefix)
        XCTAssertEqual(pipeline.viewModel.statusText, DictationViewModel.StatusStrings.dictationEndMayBeMissing)
        XCTAssertEqual(pipeline.viewModel.lastError, DictationViewModel.StatusStrings.dictationEndMayBeMissing)
    }

    /// The backend sent a final earlier, so it answers a final commit. When
    /// the stop's answer does not come before the idle rule closes the
    /// socket, the stop says its end may be missing instead of Ready (#1659).
    func testAStopThatGoesIdleWithoutTheFinalOfABackendThatSendsThemSaysTheEndMayBeMissing() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        let first = "the first part."

        await startAndSpeak(pipeline)
        pipeline.server.send(["type": "transcription.done", "text": first])
        let heard = await waitUntilObserved { pipeline.viewModel.transcript.currentDictationEventText == first }
        XCTAssertTrue(heard, "the earlier final never arrived")
        await stopOnTheIdleRule(pipeline)

        let recorded = await pipeline.records.waitForCount(1)
        XCTAssertTrue(recorded)
        XCTAssertEqual(pipeline.records.all.map(\.rawText), [first])
        let reported = await waitUntilObserved {
            pipeline.viewModel.statusText == DictationViewModel.StatusStrings.dictationEndMayBeMissing
        }
        XCTAssertTrue(reported, "status: \(pipeline.viewModel.statusText)")
        XCTAssertEqual(pipeline.viewModel.lastError, DictationViewModel.StatusStrings.dictationEndMayBeMissing)
    }

    /// speechd sends no final before the stop. Once a stop on this endpoint
    /// was answered, the next one that goes idle without its answer says its
    /// end may be missing (#1659).
    func testAStopThatGoesIdleOnAnEndpointThatAnsweredAnEarlierStopSaysTheEndMayBeMissing() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        await startAndSpeak(pipeline)
        await stopAndFinalize(pipeline)
        pipeline.server.forgetFrames()

        await startAndSpeak(pipeline)
        sendPartials(pipeline)
        await stopOnTheIdleRule(pipeline)

        let reported = await waitUntilObserved {
            pipeline.viewModel.statusText == DictationViewModel.StatusStrings.dictationEndMayBeMissing
        }
        XCTAssertTrue(reported, "status: \(pipeline.viewModel.statusText)")
    }

    /// Stops and lets the stop close on its idle rule, the final commit
    /// unanswered.
    private func stopOnTheIdleRule(_ pipeline: Pipeline, file: StaticString = #filePath, line: UInt = #line) async {
        pipeline.viewModel.stopDictation(reason: "test")
        await pipeline.server.awaitFrame("the final commit", file: file, line: line) { $0.isFinalCommit }
        // The stop's two polls: the finalization and its watchdog.
        await pipeline.clock.waitForSleepers(2, file: file, line: line)
        pipeline.clock.advance(by: TimingConstants.finalizationMinimumOpen + TimingConstants.finalizationPollInterval)
        await pipeline.server.awaitClose(file: file, line: line)
    }

    /// Stops, answers the final commit with an error frame, and lets the
    /// stop close on its idle rule.
    private func stopWithBackendError(_ pipeline: Pipeline, file: StaticString = #filePath, line: UInt = #line) async {
        pipeline.viewModel.stopDictation(reason: "test")
        await pipeline.server.awaitFrame("the final commit", file: file, line: line) { $0.isFinalCommit }
        pipeline.server.send(["type": "error", "message": "final commit failed"])
        let errored = await waitUntilObserved { pipeline.viewModel.session.lastSocketErrorMessage != nil }
        XCTAssertTrue(errored, "the error frame never arrived", file: file, line: line)
        // The stop's two polls: the finalization and its watchdog.
        await pipeline.clock.waitForSleepers(2, file: file, line: line)
        pipeline.clock.advance(by: TimingConstants.finalizationMinimumOpen + TimingConstants.finalizationPollInterval)
        await pipeline.server.awaitClose(file: file, line: line)
    }

    // MARK: - Copy on stop and a code-fence paste (#1467)

    /// Claude Desktop reads the clipboard for a fenced segment's Cmd+V after
    /// the final handler returned. Copy on stop must not have replaced it
    /// with the dictation so far by then, or the earlier segment lands twice.
    func testAutoCopyDoesNotReplaceAnInFlightFencePaste() async throws {
        let firstSegment = "first segment."
        let fenced = "see:\n```\nline one\n```"
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        pipeline.viewModel.settings.autoCopyEnabled = true
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { ClaudeDesktopAllowlist.bundleID }
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .noFocusedElement }
        TerminalTargetDetector.debugSecureEventInputOverride = { false }
        addTeardownBlock { @MainActor in
            TerminalTargetDetector.debugFrontmostBundleIDOverride = nil
            TerminalTargetDetector.debugFocusedElementProbeOverride = nil
            TerminalTargetDetector.debugSecureEventInputOverride = nil
        }
        let clipboard = FakeClipboard()
        pipeline.viewModel.dependencies.pasteboardWriter = { clipboard.write($0) }
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
                clipboard.write(text)
                // The target handles Cmd+V once the main thread is free.
                Task { @MainActor in pasted.append(clipboard.text) }
                return true
            }
        )

        await startAndSpeak(pipeline)
        pipeline.server.send(["type": "transcription.done", "text": firstSegment])
        let typedFirst = await typed.waitFor(firstSegment)
        XCTAssertTrue(typedFirst, "typed: \(typed.text.debugDescription)")
        await stopAndFinalize(pipeline, finalText: fenced)

        XCTAssertEqual(pasted.map { $0.trimmingCharacters(in: .whitespaces) }, [fenced])
        // Once the paste's restore window passed, the clipboard holds the
        // whole dictation.
        await pipeline.clock.waitForSleepers(1)
        pipeline.clock.advance(by: 1)
        let copied = await clipboard.waitFor { $0.contains(firstSegment) && $0.contains(fenced) }
        XCTAssertTrue(copied, "clipboard: \(clipboard.text.debugDescription)")
    }

    /// Two fenced finals delivered back to back: the second paste waits
    /// until the target read the first one's clipboard (#1664).
    func testTwoFencePastesInARowPasteEachPayloadOnce() async throws {
        let first = "first:\n```\nline one\n```"
        let second = "second:\n```\nline two\n```"
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { ClaudeDesktopAllowlist.bundleID }
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .noFocusedElement }
        TerminalTargetDetector.debugSecureEventInputOverride = { false }
        addTeardownBlock { @MainActor in
            TerminalTargetDetector.debugFrontmostBundleIDOverride = nil
            TerminalTargetDetector.debugFocusedElementProbeOverride = nil
            TerminalTargetDetector.debugSecureEventInputOverride = nil
        }
        let clipboard = FakeClipboard()
        pipeline.viewModel.dependencies.pasteboardWriter = { clipboard.write($0) }
        var pasted: [String] = []
        pipeline.viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        pipeline.viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { _ in true },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false },
            shiftReturnPoster: { true },
            commandVPaster: { text in
                clipboard.write(text)
                // The target handles Cmd+V once the main thread is free.
                Task { @MainActor in pasted.append(clipboard.text) }
                return true
            }
        )

        await startAndSpeak(pipeline)
        pipeline.viewModel.session.handle(event: .finalTranscript(first))
        pipeline.viewModel.session.handle(event: .finalTranscript(second))
        // The first paste's restore window passes, then the second's.
        await pipeline.clock.waitForSleepers(pipeline.listeningTimers + 1)
        pipeline.clock.advance(by: 0.15)
        await pipeline.clock.waitForSleepers(pipeline.listeningTimers + 1)
        pipeline.clock.advance(by: 0.15)
        await stopAndFinalize(pipeline)

        XCTAssertEqual(pasted.map { $0.trimmingCharacters(in: .whitespaces) }, [first, second])
    }

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

    /// Polishing off, so no context join (#759): the route finds the local
    /// herdr's focused pane itself, and the words still go through the socket.
    func testLiveAutoPasteIntoAHerdrPaneWithPolishingOffSendsThroughItsSocket() async throws {
        let herdr = try FakeHerdrSocket(answer: FakeHerdrSocket.focusedPane("w1:p2") { [(9001, "claude")] })
        addTeardownBlock { herdr.stop() }
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        joinHerdrPane(pipeline, herdr: herdr)
        pipeline.viewModel.settings.llmPolishingEnabled = false
        let typed = recordTypedText(pipeline)

        await startAndSpeak(pipeline)
        XCTAssertNil(pipeline.viewModel.context.claudeSessionJoin, "precondition: no context join")
        sendPartials(pipeline)
        await stopAndFinalize(pipeline)
        let phrase = Self.phrase
        let sentAll = await herdr.waitUntil { requests in
            requests.filter { $0.method == "pane.send_text" }.compactMap(\.text).joined() == phrase
        }
        XCTAssertTrue(sentAll, "sent: \(herdr.sentText.debugDescription)")
        XCTAssertFalse(herdr.requests.contains { $0.method == "pane.read" }, "nothing is read without the join")
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

    // MARK: - Commits into one unsent prompt (#802)

    /// Two Overlay Buffer dictations into the same unsent prompt of a joined
    /// Claude Code session are one sentence after another, not
    /// `doing.Usually`. Once the session submits, the next commit starts a
    /// fresh prompt with no space, so a slash command stays a command.
    func testOverlayBufferSpacesACommitThatContinuesTheUnsentPrompt() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.overlay.insertsThroughCommitter = true
        pipeline.overlay.commitTargetAppPID = 4343
        pipeline.overlay.passesTargetPIDToCommitter = false
        let registry = joinClaudeCodeTerminal(pipeline)
        let typed = recordTypedText(pipeline)

        await dictate(pipeline, "that's what I was doing.")
        await dictate(pipeline, "Usually it works.")
        XCTAssertEqual(typed.text, "that's what I was doing. Usually it works.")

        XCTAssertNotNil(registry.ingest(
            ClaudeHookRecord(
                event: .userPromptSubmit, sessionID: "s1", timestamp: 0, rawCwd: "/repo",
                prompt: typed.text, files: []
            ),
            origin: .localAuthenticated(peerUID: 501)
        ))
        await dictate(pipeline, "/compact")
        XCTAssertEqual(typed.text, "that's what I was doing. Usually it works./compact")
    }

    /// A submit while the next dictation runs is seen at its commit, not
    /// only at its start (Vibe review of #806).
    func testOverlayBufferAddsNoSpaceAfterASubmitDuringTheDictation() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.overlay.insertsThroughCommitter = true
        pipeline.overlay.commitTargetAppPID = 4343
        pipeline.overlay.passesTargetPIDToCommitter = false
        let registry = joinClaudeCodeTerminal(pipeline)
        let typed = recordTypedText(pipeline)

        await dictate(pipeline, "run the tests.")
        await dictate(pipeline, "/compact") {
            XCTAssertNotNil(registry.ingest(
                ClaudeHookRecord(
                    event: .userPromptSubmit, sessionID: "s1", timestamp: 0, rawCwd: "/repo",
                    prompt: nil, files: []
                ),
                origin: .localAuthenticated(peerUID: 501)
            ))
        }
        XCTAssertEqual(typed.text, "run the tests./compact")
    }

    /// Without a joined session nothing proves the prompt is unsent, so the
    /// commits stay as they are.
    func testOverlayBufferAddsNoSpaceWithoutAJoin() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.overlay.insertsThroughCommitter = true
        pipeline.overlay.commitTargetAppPID = 4343
        pipeline.overlay.passesTargetPIDToCommitter = false
        let typed = recordTypedText(pipeline)

        await dictate(pipeline, "that's what I was doing.")
        await dictate(pipeline, "Usually it works.")
        XCTAssertEqual(typed.text, "that's what I was doing.Usually it works.")
    }

    /// One whole Overlay Buffer dictation of `text`; `whileDictating` runs
    /// between its start and its stop.
    private func dictate(
        _ pipeline: Pipeline, _ text: String, file: StaticString = #filePath, line: UInt = #line,
        whileDictating: () -> Void = {}
    ) async {
        pipeline.server.forgetFrames()
        await startAndSpeak(pipeline, file: file, line: line)
        whileDictating()
        pipeline.server.send(["type": "transcription.delta", "delta": text])
        await stopAndFinalize(pipeline, finalText: text, file: file, line: line)
    }

    /// Joins the dictation to Claude Code session `s1` in a Ghostty surface
    /// by its tty, with polishing on (a fake polisher, so nothing leaves the
    /// process). Returns the registry, for the session's later hooks.
    private func joinClaudeCodeTerminal(
        _ pipeline: Pipeline, focusedTTY: (@Sendable () -> String)? = nil
    ) -> ClaudeSessionRegistry {
        let settings = pipeline.viewModel.settings
        settings.llmPolishingEnabled = true
        settings.llmPolishingEndpointURL = "http://127.0.0.1:8080/v1/chat/completions"
        settings.terminalScreenContextEnabled = true
        pipeline.viewModel.llmPolishingService = FakePolishingService()
        let tty = "/dev/ttys042"
        let epoch = Date(timeIntervalSince1970: 3_000_000)
        let registry = ClaudeSessionRegistry(now: { epoch }, isProcessAlive: { _ in true })
        XCTAssertNotNil(registry.ingest(
            ClaudeHookRecord(
                event: .sessionStart, sessionID: "s1", timestamp: 0, rawCwd: "/repo", prompt: nil, files: [],
                process: ClaudeHookProcessInfo(hookPID: 777, claudePID: 9001, tty: tty)
            ),
            origin: .localAuthenticated(peerUID: 501)
        ))
        pipeline.viewModel.context.claudeSessionJoinResolver = ClaudeSessionJoinResolver(
            registry: registry,
            focusedTerminalTTY: { _ in focusedTTY?() ?? tty }
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
        return registry
    }

    /// Joins the dictation to a Claude Code session in herdr pane `w1:p2`
    /// the way the app does: polishing on (a fake polisher, so nothing leaves
    /// the process) with screen context, a Ghostty surface bound to a herdr
    /// client, and a real `HerdrSocketClient` reading and writing `herdr`.
    /// `ttyRead` runs at each read of the terminal's focused tty.
    private func joinHerdrPane(
        _ pipeline: Pipeline, herdr: FakeHerdrSocket, ttyRead: @escaping @Sendable () -> Void = {}
    ) {
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
            focusedTerminalTTY: { _ in
                ttyRead()
                return "/dev/ttys-outer"
            },
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

    // MARK: - cmux surface route (#727)

    /// Live Auto-Paste into a joined cmux surface: the words go through
    /// cmux's socket to that surface while the dictation runs, and not one
    /// key is typed.
    func testLiveAutoPasteIntoACmuxSurfaceSendsThroughItsSocket() async throws {
        let cmux = try FakeCmuxSocket()
        addTeardownBlock { cmux.stop() }
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        joinCmuxSurface(pipeline, cmux: cmux)
        let typed = recordTypedText(pipeline)

        await startAndSpeak(pipeline)
        sendPartials(pipeline)
        let sentWhileDictating = await cmux.waitUntil { !$0.isEmpty }
        XCTAssertTrue(sentWhileDictating)
        XCTAssertTrue(pipeline.viewModel.isDictating, "sent before the stop, not by it")

        await stopAndFinalize(pipeline)
        let phrase = Self.phrase
        let sentAll = await cmux.waitUntil { writes in writes.compactMap(\.text).joined() == phrase }
        XCTAssertTrue(sentAll, "sent: \(cmux.sentText.debugDescription)")
        XCTAssertEqual(Set(cmux.writes.map(\.method)), ["surface.send_text"])
        XCTAssertEqual(Set(cmux.writes.map(\.surfaceID)), [cmux.surfaceID])
        XCTAssertEqual(typed.text, "", "nothing is typed")
    }

    /// Overlay Buffer with the spoken send trigger: the committed text goes
    /// to the surface once, then `enter` through the socket, and no Return
    /// key is pressed anywhere, though focus moved to another app.
    func testOverlayBufferSendsOnceThroughCmuxAndSubmitsWithItsEnterKey() async throws {
        let cmux = try FakeCmuxSocket(answer: { _ in .accepted(queued: true) })
        addTeardownBlock { cmux.stop() }
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.settings.overlaySpokenSendEnabled = true
        pipeline.overlay.insertsThroughCommitter = true
        joinCmuxSurface(pipeline, cmux: cmux)
        var returns: [pid_t] = []
        let typed = recordTypedText(pipeline, returnKeyPoster: { pid in
            returns.append(pid)
            return true
        })

        await startAndSpeak(pipeline)
        cmux.setSurfaceFocused(false)
        TerminalScreenContextSource.debugFrontmostTargetOverride = {
            TerminalScreenTarget(pid: 4343, bundleID: "com.apple.Safari")
        }
        pipeline.server.send(["type": "transcription.delta", "delta": "run the tests, send it."])
        await stopAndFinalize(pipeline, finalText: "run the tests, send it.")

        let submitted = await cmux.waitUntil { $0.last?.method == "surface.send_key" }
        XCTAssertTrue(submitted, "writes: \(cmux.writes)")
        XCTAssertEqual(cmux.writes, [
            .init(method: "surface.send_text", surfaceID: cmux.surfaceID, text: "run the tests"),
            .init(method: "surface.send_key", surfaceID: cmux.surfaceID, key: "enter"),
        ])
        XCTAssertEqual(pipeline.overlay.commitCallCount, 1)
        XCTAssertEqual(returns, [], "no Return key")
        XCTAssertEqual(typed.text, "")
    }

    /// cmux refuses the write while the surface is frontmost and focused:
    /// the dictation types, as it would with no route, and nothing is lost
    /// or doubled.
    func testLiveAutoPasteFallsBackToKeystrokesWhenCmuxRefuses() async throws {
        let cmux = try FakeCmuxSocket(answer: { _ in .error(code: "surface_unavailable") })
        addTeardownBlock { cmux.stop() }
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        joinCmuxSurface(pipeline, cmux: cmux)
        let typed = recordTypedText(pipeline)

        await startAndSpeak(pipeline)
        sendPartials(pipeline)
        await stopAndFinalize(pipeline)

        let typedAll = await typed.waitFor(Self.phrase)
        XCTAssertTrue(typedAll, "typed: \(typed.text.debugDescription)")
        XCTAssertFalse(pipeline.viewModel.textInsertion.promptRelayTakesText)
        XCTAssertEqual(cmux.writes.count, 1, "nothing is sent after a refusal")
    }

    /// An older cmux that does not report delivery, and a surface whose tab
    /// is not focused (manaflow-ai/cmux#3129 drops such text): the text is
    /// typed nowhere, it is in History, and the popover says so.
    func testAnUnconfirmedDeliveryToAnUnfocusedSurfaceIsKeptInHistory() async throws {
        let cmux = try FakeCmuxSocket(answer: { _ in .accepted(queued: nil) })
        addTeardownBlock { cmux.stop() }
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        pipeline.viewModel.sessionStore = try XCTUnwrap(DictationSessionStore.inMemory())
        joinCmuxSurface(pipeline, cmux: cmux)
        let typed = recordTypedText(pipeline)

        await startAndSpeak(pipeline)
        cmux.setSurfaceFocused(false)
        sendPartials(pipeline)
        let sent = await cmux.waitUntil { !$0.isEmpty }
        XCTAssertTrue(sent)
        await pipeline.viewModel.textInsertion.promptRelaySink?.waitUntilIdle()
        await stopAndFinalize(
            pipeline, expectedError: DictationViewModel.StatusStrings.agentPromptTextKeptInHistory
        )

        XCTAssertEqual(cmux.writes.count, 1, "nothing is sent after an unconfirmed write")
        XCTAssertEqual(typed.text, "", "nothing is typed into another surface or app")
        XCTAssertEqual(pipeline.records.all.map(\.rawText), [Self.phrase], "the text is in History")
    }

    /// The same with History off, where Copy last dictation is all that
    /// holds the text until the next dictation replaces it: the whole text
    /// goes on the clipboard, the popover says so, and the next dictation
    /// leaves it there (#1499).
    func testAnUnconfirmedDeliveryWithHistoryOffIsCopiedAndOutlivesTheNextDictation() async throws {
        let cmux = try FakeCmuxSocket(answer: { _ in .accepted(queued: nil) })
        addTeardownBlock { cmux.stop() }
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        pipeline.viewModel.sessionStore = try XCTUnwrap(DictationSessionStore.inMemory())
        pipeline.viewModel.settings.dictationHistoryRetention = .off
        pipeline.viewModel.settings.autoCopyEnabled = false
        let copied = pipeline.viewModel.recordPasteboardWrites()
        joinCmuxSurface(pipeline, cmux: cmux)
        let typed = recordTypedText(pipeline)

        await startAndSpeak(pipeline)
        cmux.setSurfaceFocused(false)
        sendPartials(pipeline)
        let sent = await cmux.waitUntil { !$0.isEmpty }
        XCTAssertTrue(sent)
        await pipeline.viewModel.textInsertion.promptRelaySink?.waitUntilIdle()
        await stopAndFinalize(pipeline, expectedError: DictationViewModel.StatusStrings.overlayCopiedToClipboard)
        XCTAssertEqual(copied.values.last, Self.phrase, "both appends, not the last one alone")
        let copiesAfterFirst = copied.values.count

        // The next dictation goes to a plain terminal, by keys.
        pipeline.viewModel.context.claudeSessionJoinResolver = nil
        pipeline.server.forgetFrames()
        await startAndSpeak(pipeline)
        sendPartials(pipeline)
        await stopAndFinalize(pipeline)

        XCTAssertEqual(typed.text, Self.phrase, "precondition: the second dictation committed")
        XCTAssertEqual(copied.values.count, copiesAfterFirst, "the next dictation leaves the clipboard alone")
        XCTAssertEqual(copied.values.last, Self.phrase)
    }

    /// Kept text copied with History off waits, like Copy on stop, until no
    /// Cmd+V paste may still read the clipboard: Claude Desktop reads a
    /// fenced segment's paste after the post returned (#1467, #1499).
    func testKeptTextWithHistoryOffDoesNotReplaceAnInFlightFencePaste() async throws {
        let fenced = "see:\n```\nline one\n```"
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        pipeline.viewModel.settings.dictationHistoryRetention = .off
        pipeline.viewModel.settings.autoCopyEnabled = false
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { ClaudeDesktopAllowlist.bundleID }
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .noFocusedElement }
        TerminalTargetDetector.debugSecureEventInputOverride = { false }
        addTeardownBlock { @MainActor in
            TerminalTargetDetector.debugFrontmostBundleIDOverride = nil
            TerminalTargetDetector.debugFocusedElementProbeOverride = nil
            TerminalTargetDetector.debugSecureEventInputOverride = nil
        }
        let clipboard = FakeClipboard()
        pipeline.viewModel.dependencies.pasteboardWriter = { clipboard.write($0) }
        pipeline.viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        pipeline.viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { _ in true },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false },
            shiftReturnPoster: { true },
            commandVPaster: { text in
                clipboard.write(text)
                return true
            }
        )

        await startAndSpeak(pipeline)
        await stopAndFinalize(pipeline, finalText: fenced)
        XCTAssertEqual(clipboard.text.trimmingCharacters(in: .whitespaces), fenced, "precondition: pasted")

        let status = pipeline.viewModel.session.keepUndeliveredAgentText("kept text")

        XCTAssertEqual(status, DictationViewModel.StatusStrings.overlayCopiedToClipboard)
        XCTAssertEqual(clipboard.text.trimmingCharacters(in: .whitespaces), fenced, "the paste still owns the clipboard")
        await pipeline.clock.waitForSleepers(1)
        pipeline.clock.advance(by: 1)
        let copied = await clipboard.waitFor { $0 == "kept text" }
        XCTAssertTrue(copied, "clipboard: \(clipboard.text.debugDescription)")
    }

    // MARK: - Stopping by voice (#839)

    /// A trailing "send it" and three seconds without new words, the
    /// default wait, stop the dictation as the key would: the stop's commit
    /// inserts the text without the phrase, once, then presses Return once.
    func testATrailingSendPhraseAndSilenceStopsCommitsAndSendsOnce() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        var returns: [pid_t] = []
        targetClaudeDesktop(pipeline, returns: { returns.append($0) })

        await startAndSpeak(pipeline)
        await sendDelta(pipeline, "run the tests, send it.")
        let armed = try XCTUnwrap(pipeline.viewModel.session.spokenStopTask, "armed by the trailing phrase")
        await pipeline.clock.waitForSleepers(pipeline.listeningTimers + 1)
        pipeline.clock.advance(by: 3 - 0.01)
        XCTAssertTrue(pipeline.viewModel.isDictating, "one hundredth short, still dictating")

        pipeline.clock.advance(by: 0.01)
        await armed.value
        XCTAssertFalse(pipeline.viewModel.isDictating)
        XCTAssertTrue(pipeline.viewModel.isFinalizingStop, "the stop finalizes like a pressed stop")
        await finishStoppedSession(pipeline, finalText: "run the tests, send it.")

        XCTAssertEqual(pipeline.overlay.committedTexts, ["run the tests"])
        XCTAssertEqual(returns, [Self.desktopPID], "Return once, after the commit")
        XCTAssertEqual(pipeline.records.all.map(\.rawText), ["run the tests"])
    }

    /// A generation that ends mid-word (#536): "sen" then "d it." reads as
    /// "send it." and stops like the phrase said in one piece.
    func testASendPhraseSplitAcrossSegmentsStops() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        var returns: [pid_t] = []
        targetClaudeDesktop(pipeline, returns: { returns.append($0) })

        await startAndSpeak(pipeline)
        // Words arrive space-prefixed, as vLLM streams them; that is what
        // tells a segment without a leading space from a new word.
        await sendDelta(pipeline, "run the tests,")
        await sendDelta(pipeline, " sen")
        pipeline.server.send(["type": "transcription.done", "text": "run the tests, sen"])
        await sendDelta(pipeline, "d")
        await sendDelta(pipeline, " it.")
        let armed = try XCTUnwrap(pipeline.viewModel.session.spokenStopTask, "overlay: \(pipeline.overlay.refreshCalls.last?.displayText.debugDescription ?? "")")
        await pipeline.clock.waitForSleepers(pipeline.listeningTimers + 1)
        pipeline.clock.advance(by: 3)
        await armed.value
        await finishStoppedSession(pipeline, finalText: "d it.")

        XCTAssertEqual(pipeline.overlay.committedTexts, ["run the tests"])
        XCTAssertEqual(returns, [Self.desktopPID])
    }

    /// "send it" in the middle of a sentence never arms the stop.
    func testASendPhraseMidSentenceNeverStops() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        var returns: [pid_t] = []
        targetClaudeDesktop(pipeline, returns: { returns.append($0) })

        await startAndSpeak(pipeline)
        await sendDelta(pipeline, "saying send it in the overlay")
        XCTAssertNil(pipeline.viewModel.session.spokenStopTask)
        pipeline.clock.advance(by: 10)
        XCTAssertTrue(pipeline.viewModel.isDictating)

        await stopAndFinalize(pipeline, finalText: "saying send it in the overlay")
        XCTAssertEqual(pipeline.overlay.committedTexts, ["saying send it in the overlay"])
        XCTAssertEqual(returns, [])
    }

    /// Speaking again within the window keeps the dictation going, and the
    /// words after the phrase make it ordinary text.
    func testSpeechWithinTheWindowKeepsTheDictationGoing() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        var returns: [pid_t] = []
        targetClaudeDesktop(pipeline, returns: { returns.append($0) })

        await startAndSpeak(pipeline)
        await sendDelta(pipeline, "run the tests, send it.")
        let armed = try XCTUnwrap(pipeline.viewModel.session.spokenStopTask)
        await pipeline.clock.waitForSleepers(pipeline.listeningTimers + 1)
        pipeline.clock.advance(by: 2.9)
        await sendDelta(pipeline, " and then report.")
        await armed.value
        XCTAssertNil(pipeline.viewModel.session.spokenStopTask, "new words cancelled the stop")
        pipeline.clock.advance(by: 10)
        XCTAssertTrue(pipeline.viewModel.isDictating)

        let said = "run the tests, send it. and then report."
        await stopAndFinalize(pipeline, finalText: said)
        XCTAssertEqual(pipeline.overlay.committedTexts, [said])
        XCTAssertEqual(returns, [])
    }

    /// The wait is the user's (#1009): at 1 s the stop fires one second
    /// after the phrase, not a hundredth sooner, and sends as the 3 s
    /// default does.
    func testAConfiguredWaitStopsAtThatWait() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.settings.spokenStopWait = .oneSecond
        var returns: [pid_t] = []
        targetClaudeDesktop(pipeline, returns: { returns.append($0) })

        await startAndSpeak(pipeline)
        // The session's other timers sleep on this clock too: the stop's
        // sleep is the one the phrase added.
        let sessionSleeps = pipeline.clock.pendingDeadlines
        let saidAt = pipeline.clock.now
        await sendDelta(pipeline, "run the tests, send it.")
        let armed = try XCTUnwrap(pipeline.viewModel.session.spokenStopTask, "armed by the trailing phrase")
        await pipeline.clock.waitForSleepers(pipeline.listeningTimers + 1)
        var stopSleeps = pipeline.clock.pendingDeadlines
        for deadline in sessionSleeps {
            if let index = stopSleeps.firstIndex(of: deadline) { stopSleeps.remove(at: index) }
        }
        let waits = stopSleeps.map { $0.timeIntervalSince(saidAt) }
        XCTAssertEqual(waits, [1], "the stop's sleep")
        let stopsAtOneSecond = waits == [1]
        pipeline.clock.advance(by: 1 - 0.01)
        XCTAssertTrue(pipeline.viewModel.isDictating, "one hundredth short, still dictating")

        pipeline.clock.advance(by: 0.01)
        // A longer wait must still end, or the session outlives the test.
        if !stopsAtOneSecond { pipeline.clock.advance(by: 2) }
        await armed.value
        XCTAssertFalse(pipeline.viewModel.isDictating)
        await finishStoppedSession(pipeline, finalText: "run the tests, send it.")

        XCTAssertEqual(pipeline.overlay.committedTexts, ["run the tests"])
        XCTAssertEqual(returns, [Self.desktopPID])
    }

    /// New words inside a configured 1.5 s wait cancel the stop, as they do
    /// inside the default 3 s.
    func testSpeechWithinAConfiguredWaitKeepsTheDictationGoing() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.settings.spokenStopWait = .oneAndAHalfSeconds
        var returns: [pid_t] = []
        targetClaudeDesktop(pipeline, returns: { returns.append($0) })

        await startAndSpeak(pipeline)
        await sendDelta(pipeline, "run the tests, send it.")
        let armed = try XCTUnwrap(pipeline.viewModel.session.spokenStopTask)
        await pipeline.clock.waitForSleepers(pipeline.listeningTimers + 1)
        pipeline.clock.advance(by: 1.4)
        await sendDelta(pipeline, " and then report.")
        await armed.value
        XCTAssertNil(pipeline.viewModel.session.spokenStopTask, "new words cancelled the stop")
        pipeline.clock.advance(by: 10)
        XCTAssertTrue(pipeline.viewModel.isDictating)

        let said = "run the tests, send it. and then report."
        await stopAndFinalize(pipeline, finalText: said)
        XCTAssertEqual(pipeline.overlay.committedTexts, [said])
        XCTAssertEqual(returns, [])
    }

    /// A held (push to talk) dictation waits for its release: nothing arms,
    /// and the release right after "send it" commits and sends at once.
    func testAHeldDictationStopsOnlyOnRelease() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        var returns: [pid_t] = []
        targetClaudeDesktop(pipeline, returns: { returns.append($0) })

        await startAndSpeak(pipeline)
        pipeline.viewModel.shortcuts.hasActivePushToTalkShortcutSession = true
        await sendDelta(pipeline, "run the tests, send it.")
        XCTAssertNil(pipeline.viewModel.session.spokenStopTask)
        pipeline.clock.advance(by: 10)
        XCTAssertTrue(pipeline.viewModel.isDictating)

        await stopAndFinalize(pipeline, finalText: "run the tests, send it.")
        XCTAssertEqual(pipeline.overlay.committedTexts, ["run the tests"])
        XCTAssertEqual(returns, [Self.desktopPID])
    }

    /// The user's phrase stops and sends; the default no longer does.
    func testACustomPhraseStopsAndTheDefaultNoLongerDoes() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.settings.spokenSendTriggerPhrases = ["ship it"]
        var returns: [pid_t] = []
        targetClaudeDesktop(pipeline, returns: { returns.append($0) })

        await startAndSpeak(pipeline)
        await sendDelta(pipeline, "run the tests, send it.")
        XCTAssertNil(pipeline.viewModel.session.spokenStopTask, "send it is ordinary text now")
        await sendDelta(pipeline, " Ship it.")
        let armed = try XCTUnwrap(pipeline.viewModel.session.spokenStopTask)
        await pipeline.clock.waitForSleepers(pipeline.listeningTimers + 1)
        pipeline.clock.advance(by: 3)
        await armed.value
        await finishStoppedSession(pipeline, finalText: "run the tests, send it. Ship it.")

        XCTAssertEqual(pipeline.overlay.committedTexts, ["run the tests, send it"])
        XCTAssertEqual(returns, [Self.desktopPID])
    }

    /// A quick capture stops the same way and goes to the Inbox without the
    /// phrase; the Inbox never presses Return.
    func testAQuickCaptureStopsOnItsSendPhraseAndSavesWithoutIt() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        var returns: [pid_t] = []
        targetClaudeDesktop(pipeline, returns: { returns.append($0) })
        let captured = QuickCaptures()
        pipeline.viewModel.session.onQuickCapture = { text, _, _ in
            captured.all.append((text, pipeline.records.all.count))
        }

        await startAndSpeak(pipeline, start: { $0.session.toggleQuickCapture() })
        await sendDelta(pipeline, "buy milk, send it.")
        let armed = try XCTUnwrap(pipeline.viewModel.session.spokenStopTask)
        await pipeline.clock.waitForSleepers(pipeline.listeningTimers + 1)
        pipeline.clock.advance(by: 3)
        await armed.value
        await finishStoppedSession(
            pipeline, finalText: "buy milk, send it.",
            finalStatus: DictationViewModel.StatusStrings.quickCaptureSaved
        )

        XCTAssertEqual(captured.all.map(\.text), ["buy milk"])
        XCTAssertEqual(pipeline.overlay.commitCallCount, 0)
        XCTAssertEqual(returns, [])
    }

    /// The send phrase was said into an app where it sends nothing, so the
    /// voice stop stayed off. Tab to the Inbox (#840) re-decides on the
    /// words already said: the capture stops on its phrase, saves without
    /// it, and presses no Return.
    func testTabToTheInboxAfterTheSendPhraseStopsAndSavesWithoutReturn() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.settings.overlaySpokenSendEnabled = true
        var returns: [pid_t] = []
        _ = recordTypedText(pipeline, returnKeyPoster: { pid in
            returns.append(pid)
            return true
        })
        let captured = QuickCaptures()
        pipeline.viewModel.session.onQuickCapture = { text, _, _ in
            captured.all.append((text, pipeline.records.all.count))
        }

        await startAndSpeak(pipeline)
        await sendDelta(pipeline, "buy milk, send it.")
        XCTAssertNil(pipeline.viewModel.session.spokenStopTask, "no app here where the phrase would send")

        pipeline.viewModel.session.moveDestination(forward: true)
        let armed = try XCTUnwrap(pipeline.viewModel.session.spokenStopTask, "the Inbox stops on its phrase")
        // Tab also opened the destination list, whose close timer sleeps on
        // the same clock. Waiting for one new sleeper could return on that
        // timer alone, and an advance before the stop's own sleep registers
        // never reaches its deadline (#1378).
        await pipeline.clock.waitForSleepers(pipeline.listeningTimers + 2)
        pipeline.clock.advance(by: 3)
        await armed.value
        await finishStoppedSession(
            pipeline, finalText: "buy milk, send it.",
            finalStatus: DictationViewModel.StatusStrings.quickCaptureSaved
        )

        XCTAssertEqual(captured.all.map(\.text), ["buy milk"])
        XCTAssertEqual(pipeline.overlay.commitCallCount, 0)
        XCTAssertEqual(returns, [])
    }

    private static let desktopPID: pid_t = 4343

    /// Claude Desktop is the commit target, where Return submits, with
    /// Secure Keyboard Entry off and the spoken send on.
    private func targetClaudeDesktop(_ pipeline: Pipeline, returns: @escaping (pid_t) -> Void) {
        pipeline.viewModel.settings.overlaySpokenSendEnabled = true
        pipeline.overlay.commitTargetAppPID = Self.desktopPID
        pipeline.viewModel.dependencies.bundleIdentifier = {
            $0 == Self.desktopPID ? ClaudeDesktopAllowlist.bundleID : nil
        }
        TerminalTargetDetector.debugSecureEventInputOverride = { false }
        addTeardownBlock { @MainActor in TerminalTargetDetector.debugSecureEventInputOverride = nil }
        _ = recordTypedText(pipeline, returnKeyPoster: { pid in
            returns(pid)
            return true
        })
    }

    /// Sends one delta and returns once the overlay shows it.
    private func sendDelta(_ pipeline: Pipeline, _ delta: String, file: StaticString = #filePath, line: UInt = #line) async {
        let shown = BoundedWait()
        let expected = delta.trimmingCharacters(in: .whitespaces)
        pipeline.overlay.onRefresh = { call in
            if call.displayText.hasSuffix(expected) { shown.resolve() }
        }
        pipeline.server.send(["type": "transcription.delta", "delta": delta])
        let seen = await shown.value(failAfter: 10)
        pipeline.overlay.onRefresh = nil
        XCTAssertTrue(
            seen, "overlay shows: \(pipeline.overlay.refreshCalls.last?.displayText.debugDescription ?? "nothing")",
            file: file, line: line
        )
    }

    /// The server's side of a stop the session made itself: the final
    /// commit is answered, the client closes, and the session records.
    private func finishStoppedSession(
        _ pipeline: Pipeline, finalText: String,
        finalStatus: String = DictationViewModel.StatusStrings.ready,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        await pipeline.server.awaitFrame("the final commit", file: file, line: line) { $0.isFinalCommit }
        pipeline.server.send(["type": "transcription.done", "text": finalText])
        let recorded = await pipeline.records.waitForCount(1)
        XCTAssertTrue(recorded, "the session never finished and wrote its record", file: file, line: line)
        await pipeline.server.awaitClose(file: file, line: line)
        XCTAssertFalse(pipeline.viewModel.isFinalizingStop, file: file, line: line)
        XCTAssertEqual(pipeline.viewModel.statusText, finalStatus, file: file, line: line)
    }

    /// Joins the dictation to a cmux surface: the frontmost app is cmux, the
    /// fake socket reports the surface focused, and a local session
    /// published its id and tty.
    private func joinCmuxSurface(_ pipeline: Pipeline, cmux: FakeCmuxSocket) {
        let epoch = Date(timeIntervalSince1970: 3_000_000)
        let registry = ClaudeSessionRegistry(now: { epoch }, isProcessAlive: { _ in true })
        XCTAssertNotNil(registry.ingest(
            ClaudeHookRecord(
                event: .sessionStart, sessionID: "cmux-session", timestamp: 0, rawCwd: "/repo",
                prompt: nil, files: [],
                process: ClaudeHookProcessInfo(hookPID: 777, claudePID: 9001, tty: cmux.tty,
                                               cmuxSurfaceID: cmux.surfaceID)
            ),
            origin: .localAuthenticated(peerUID: 501)
        ))
        pipeline.viewModel.context.claudeSessionJoinResolver = ClaudeSessionJoinResolver(
            registry: registry, cmuxSurfaces: cmux.client(), cmuxJoinEnabled: { true },
            ttyForegroundPIDs: { _ in [9001] }
        )
        let target = TerminalScreenTarget(pid: FakeCmuxSocket.pid, bundleID: TerminalScreenAllowlist.cmuxBundleID)
        TerminalScreenContextSource.debugFrontmostTargetOverride = { target }
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { TerminalScreenAllowlist.cmuxBundleID }
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

    // MARK: - The first words (#527)

    /// People speak as they press. The microphone runs while the socket is
    /// still opening, and what it heard then reaches the backend first.
    func testWordsSpokenWhileTheSocketOpensReachTheBackendFirst() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.server.holdConnections()

        pipeline.viewModel.startDictation()
        await pipeline.server.awaitHeldConnection()
        XCTAssertTrue(pipeline.viewModel.isConnectingRealtimeSession)
        let firstWord = Self.speech(seed: 4)
        XCTAssertTrue(
            pipeline.microphone.deliver(firstWord),
            "the microphone runs before the socket opens"
        )

        pipeline.server.releaseHeldConnections()
        await pipeline.server.awaitFrame("session.update") { $0.type == "session.update" }
        let rest = Self.speech(seed: 5)
        XCTAssertTrue(pipeline.microphone.deliver(rest))
        await pipeline.clock.waitForSleepers(pipeline.listeningTimers)
        pipeline.clock.advance(by: TimingConstants.audioSendInterval)
        let sent = await pipeline.server.awaitFrame("the captured audio") { $0.audio != nil }
        XCTAssertEqual(sent?.audio, firstWord + rest, "the first word leads the audio, whole")

        await stopAndFinalize(pipeline)
    }

    // MARK: - Picking a microphone mid-session

    private static let builtInMic = MicrophoneInputDevice(
        id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", channelCount: 1)
    private static let usbMic = MicrophoneInputDevice(
        id: "AppleUSBAudioEngine:Rode:NT-USB:1", name: "NT-USB", channelCount: 1)

    /// #1628: a microphone picked while the socket opens is the one the
    /// dictation captures, not just the one the menu checks.
    func testAMicrophonePickedWhileConnectingIsTheOneCaptured() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.microphone.configureDevices([Self.builtInMic, Self.usbMic], defaultInputDeviceID: Self.builtInMic.id)
        pipeline.server.holdConnections()

        pipeline.viewModel.startDictation()
        await pipeline.server.awaitHeldConnection()
        await pipeline.microphone.waitUntilCapturing()
        XCTAssertEqual(pipeline.microphone.capturingDeviceID, Self.builtInMic.id)

        pipeline.viewModel.selectMicrophoneInput(id: Self.usbMic.id)
        XCTAssertTrue(pipeline.viewModel.isConnectingRealtimeSession, "the pick does not restart the connect")
        XCTAssertEqual(pipeline.microphone.capturingDeviceID, Self.usbMic.id)

        pipeline.server.releaseHeldConnections()
        await pipeline.server.awaitFrame("session.update") { $0.type == "session.update" }
        await pipeline.clock.waitForSleepers(pipeline.listeningTimers)
        let words = Self.speech(seed: 6)
        XCTAssertTrue(pipeline.microphone.deliver(words, from: Self.usbMic.id))
        pipeline.clock.advance(by: TimingConstants.audioSendInterval)
        let sent = await pipeline.server.awaitFrame("the captured audio") { $0.audio != nil }
        XCTAssertEqual(sent?.audio, words)

        await stopAndFinalize(pipeline)
    }

    /// #1629: a saved microphone plugged back in mid-dictation is not shown
    /// selected while capture stays on the fallback, and picking it moves
    /// the capture onto it.
    func testAPluggedBackSavedMicrophoneIsCapturedOnceItIsPicked() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.settings.selectedInputDeviceUID = Self.usbMic.id
        pipeline.microphone.configureDevices([Self.builtInMic], defaultInputDeviceID: Self.builtInMic.id)

        await startAndSpeak(pipeline)
        XCTAssertEqual(pipeline.microphone.capturingDeviceID, Self.builtInMic.id, "the fallback stands in")

        pipeline.microphone.configureDevices([Self.builtInMic, Self.usbMic], defaultInputDeviceID: Self.builtInMic.id)
        pipeline.viewModel.audio.handleMicrophoneInputDevicesChanged()
        pipeline.viewModel.audio.healthMonitor.debugEvaluateAudioChangeNow()
        XCTAssertEqual(
            pipeline.viewModel.selectedInputDeviceID, Self.builtInMic.id,
            "the menu shows the device the capture runs on"
        )
        XCTAssertEqual(pipeline.viewModel.settings.selectedInputDeviceUID, Self.usbMic.id, "and keeps the saved one")

        pipeline.server.forgetFrames()
        await startAndSpeak(pipeline, start: { $0.selectMicrophoneInput(id: Self.usbMic.id) })
        XCTAssertEqual(pipeline.microphone.capturingDeviceID, Self.usbMic.id)
        let words = Self.speech(seed: 7)
        XCTAssertTrue(pipeline.microphone.deliver(words, from: Self.usbMic.id))
        pipeline.clock.advance(by: TimingConstants.audioSendInterval)
        await pipeline.server.awaitFrame("the plugged-back mic's audio") { $0.audio == words }
        await pipeline.clock.waitForSleepers(pipeline.listeningTimers)

        await stopAndFinalize(pipeline)
    }

    // MARK: - Reviewing a ready draft (#927)

    /// A finished draft waits for a break: nothing shows while the user is
    /// mid-task, and the stop of the next dictation lights the mark and the
    /// popover line.
    func testAStoppedDictationIsTheBreakThatShowsAReadyDraft() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        _ = try await installInboxWithDraft(pipeline)
        XCTAssertNil(pipeline.viewModel.agentAttentionLine, "held until a break")
        XCTAssertEqual(pipeline.viewModel.menuBarIndicatorState, .idle)

        await startAndSpeak(pipeline)
        sendPartials(pipeline)
        await stopAndFinalize(pipeline)

        XCTAssertEqual(pipeline.viewModel.agentAttentionLine, "Draft ready: Inbox for reach")
        XCTAssertEqual(pipeline.viewModel.menuBarIndicatorState, .agentNeedsYou)
    }

    /// With nobody waiting, the answer key opens the draft: the overlay shows
    /// that one draft and no other destination. "file it" files it as shown
    /// and nothing reaches the focused app.
    func testTheAnswerKeyOpensTheDraftAndFileItFilesIt() async throws {
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste)
        let inbox = try await installInboxWithDraft(pipeline, shown: true)
        XCTAssertEqual(pipeline.viewModel.agentAttentionLine, "Draft ready: Inbox for reach")

        await startAndSpeak(pipeline, start: { $0.session.answerAgentThatNeedsYou() })
        XCTAssertEqual(pipeline.overlay.startSessionAnchors.count, 1, "a review opens the overlay whatever the menu bar mode")
        XCTAssertEqual(pipeline.overlay.shownDraftReviews.last??.title, "Dark mode")
        XCTAssertTrue(pipeline.overlay.shownDestinations.isEmpty, "a review offers no other destination")

        await sendDelta(pipeline, "File it.")
        await stopAndFinalize(pipeline, finalText: "File it.", finalStatus: QuickCaptureReviewStatus.filing)
        await pipeline.viewModel.session.draftReviewTask?.value

        XCTAssertEqual(inbox.github.created.withLock { $0.map(\.[1]) }, ["Dark mode"])
        XCTAssertEqual(inbox.model.items.first?.state, .filed)
        XCTAssertEqual(pipeline.overlay.commitCallCount, 0, "nothing reaches the focused app")
        XCTAssertEqual(pipeline.records.all.map(\.rawText), ["File it."], "the words are in History")
        XCTAssertNil(pipeline.viewModel.session.sessionDraftReview, "the next dictation is an ordinary one")
        XCTAssertNil(pipeline.viewModel.agentAttentionLine, "filed, it left the cue")
    }

    /// A review that files, drops and changes nothing keeps its draft in the
    /// cue, as does a start the app refused: the next press opens it again.
    func testAReviewThatSaysNothingKeepsTheDraftInTheCue() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        _ = try await installInboxWithDraft(pipeline, shown: true)

        await startAndSpeak(pipeline, start: { $0.session.answerAgentThatNeedsYou() })
        // Only the send phrase: nothing left to act on.
        await stopAndFinalize(pipeline, finalText: "send it", finalStatus: QuickCaptureReviewStatus.kept)

        XCTAssertEqual(pipeline.viewModel.agentAttentionLine, "Draft ready: Inbox for reach")
    }

    /// "drop it" alone, then three seconds of silence, stops the review by
    /// voice and discards the draft.
    func testDropItAndSilenceStopTheReviewAndDiscardTheDraft() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.settings.overlaySpokenSendEnabled = true
        let inbox = try await installInboxWithDraft(pipeline, shown: true)

        await startAndSpeak(pipeline, start: { $0.session.answerAgentThatNeedsYou() })
        await sendDelta(pipeline, "Drop it.")
        let armed = try XCTUnwrap(pipeline.viewModel.session.spokenStopTask, "armed by the whole phrase")
        await pipeline.clock.waitForSleepers(pipeline.listeningTimers + 1)
        pipeline.clock.advance(by: 3)
        await armed.value
        XCTAssertFalse(pipeline.viewModel.isDictating)
        await finishStoppedSession(pipeline, finalText: "Drop it.", finalStatus: QuickCaptureReviewStatus.dropped)

        XCTAssertTrue(inbox.model.items.isEmpty)
        XCTAssertTrue(inbox.github.created.withLock { $0.isEmpty })
        XCTAssertEqual(pipeline.overlay.commitCallCount, 0)
    }

    /// Anything else is a change: the drafter reruns with the dictated
    /// words, the draft and the change, and a trailing send phrase is not
    /// part of it. The redraft is a new draft, held for the next break.
    func testAChangeRedraftsTheDraft() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        pipeline.viewModel.settings.overlaySpokenSendEnabled = true
        let inbox = try await installInboxWithDraft(pipeline, shown: true)
        inbox.runner.nextTitles.withLock { $0 = ["Popover dark mode"] }

        await startAndSpeak(pipeline, start: { $0.session.answerAgentThatNeedsYou() })
        await sendDelta(pipeline, "Make it only the popover part, send it.")
        let armed = try XCTUnwrap(pipeline.viewModel.session.spokenStopTask, "armed by the send phrase")
        await pipeline.clock.waitForSleepers(pipeline.listeningTimers + 1)
        pipeline.clock.advance(by: 3)
        await armed.value
        await finishStoppedSession(
            pipeline, finalText: "Make it only the popover part, send it.", finalStatus: QuickCaptureReviewStatus.redrafting
        )
        await pipeline.viewModel.session.draftReviewTask?.value

        XCTAssertEqual(inbox.model.items.first?.title, "Popover dark mode")
        XCTAssertEqual(inbox.model.items.first?.changes, ["Make it only the popover part"])
        let prompt = inbox.runner.arguments.withLock { $0.last?.joined(separator: " ") ?? "" }
        XCTAssertTrue(prompt.contains("Make it only the popover part"))
        XCTAssertFalse(prompt.contains("send it"))
        XCTAssertTrue(inbox.github.created.withLock { $0.isEmpty })
        XCTAssertNil(pipeline.viewModel.agentAttentionLine, "the redraft waits for the next break")
    }

    /// An agent that needs you comes before a draft.
    func testTheAnswerKeyGoesToAWaitingAgentBeforeADraft() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        // An unconfirmed focus starts no dictation, so the press is all
        // there is to observe.
        let waiting = installWaitingSessions(
            pipeline, ["pay": "/r/payments"], outcome: .unverified(bundleID: TerminalScreenAllowlist.ghosttyBundleID)
        )
        _ = try await installInboxWithDraft(pipeline, shown: true, attention: pipeline.viewModel.agentAttention)
        XCTAssertEqual(pipeline.viewModel.agentAttentionLine, "payments needs you (+1)")

        pipeline.viewModel.session.answerAgentThatNeedsYou()
        await pipeline.viewModel.session.answerAgentTask?.value
        XCTAssertEqual(waiting.focuser.focusedSessionIDs, ["pay"])
        XCTAssertEqual(pipeline.viewModel.agentAttentionLine, "Draft ready: Inbox for reach", "the draft waits its turn")
        XCTAssertTrue(pipeline.overlay.shownDraftReviews.isEmpty)
    }

    // MARK: - A take past the server's context limit (#1139)

    /// Two tokens of context: 6.4 KB of audio (two chunks) passes the
    /// margin, one chunk does not.
    private static let tinyContext = RealtimeContextBudget(maxModelLen: 2)

    /// Live Auto-Paste: the session rolls over mid-take, and what each server
    /// session wrote is typed once, with a space at the seam.
    func testLiveAutoPasteTypesBothSidesOfARolloverOnce() async throws {
        let pipeline = try await makePipeline(outputMode: .liveAutoPaste, contextBudget: Self.tinyContext)
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
        await rollOver(pipeline, retiringText: "Hello from the first session.")
        let typedFirst = await typed.waitFor("Hello from the first session.")
        XCTAssertTrue(typedFirst, "typed so far: \(typed.text.debugDescription)")

        // A fresh server session writes its first word with no space.
        pipeline.server.send(["type": "transcription.delta", "delta": "And the second."])
        let typedSecond = await typed.waitFor("Hello from the first session. And the second.")
        XCTAssertTrue(typedSecond, "typed so far: \(typed.text.debugDescription)")

        await stopAndFinalize(pipeline, finalText: "And the second.")

        XCTAssertEqual(typed.text, "Hello from the first session. And the second.")
        XCTAssertEqual(
            pipeline.records.all.map(\.rawText), ["Hello from the first session. And the second."])
    }

    /// Overlay Buffer: the overlay holds both sides of the rollover, and the
    /// stop commits them once, as one dictation.
    func testOverlayBufferCommitsBothSidesOfARolloverOnce() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer, contextBudget: Self.tinyContext)

        await startAndSpeak(pipeline)
        await rollOver(pipeline, retiringText: "Hello from the first session.")
        let shown = BoundedWait()
        pipeline.overlay.onRefresh = { call in
            if call.displayText == "Hello from the first session. And the second." { shown.resolve() }
        }
        pipeline.server.send(["type": "transcription.delta", "delta": "And the second."])
        let shownBoth = await shown.value(failAfter: 10)
        XCTAssertTrue(
            shownBoth,
            "overlay shows: \(pipeline.overlay.refreshCalls.last?.displayText.debugDescription ?? "nothing")"
        )
        pipeline.overlay.onRefresh = nil
        XCTAssertEqual(pipeline.overlay.commitCallCount, 0, "a rollover commits nothing")

        await stopAndFinalize(pipeline, finalText: "And the second.")

        XCTAssertEqual(pipeline.overlay.committedTexts, ["Hello from the first session. And the second."])
        XCTAssertEqual(
            pipeline.records.all.map(\.rawText), ["Hello from the first session. And the second."])
    }

    /// The second chunk passes the margin: the client ends the server session
    /// with a final commit, the server answers it with `retiringText`, and
    /// the client dials a fresh session on the same server, which starts its
    /// run at once. Returns once that session asked for the model.
    private func rollOver(
        _ pipeline: Pipeline, retiringText: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        XCTAssertEqual(
            pipeline.viewModel.session.realtimeAPIClient.debugStateSnapshot().contextBudget, Self.tinyContext,
            "the server's limit reached the client", file: file, line: line
        )
        pipeline.server.send(["type": "transcription.delta", "delta": retiringText])
        XCTAssertTrue(pipeline.microphone.deliver(Self.speech(seed: 4)), file: file, line: line)
        pipeline.clock.advance(by: TimingConstants.audioSendInterval)
        await pipeline.server.awaitFrame("the rollover's final commit", file: file, line: line) {
            $0.isFinalCommit
        }
        XCTAssertTrue(pipeline.viewModel.isDictating, "a rollover is not a stop", file: file, line: line)
        pipeline.server.forgetFrames()

        pipeline.server.send(["type": "transcription.done", "text": retiringText])
        let update = await pipeline.server.awaitFrame("the next session's session.update", file: file, line: line) {
            $0.type == "session.update"
        }
        XCTAssertEqual(update?.json["model"] as? String, Self.model, file: file, line: line)
        await pipeline.server.awaitFrame("the commit that starts the next run", file: file, line: line) {
            $0.type == "input_audio_buffer.commit" && !$0.isFinalCommit
        }
        XCTAssertTrue(pipeline.viewModel.isDictating, file: file, line: line)
        XCTAssertNil(pipeline.viewModel.lastError, file: file, line: line)
    }

    // MARK: - A stop before the session is ready

    /// A stop before the handshake, on a server that never sends
    /// `session.created`, waits for the compatibility fallback to send the
    /// audio and the final commit instead of closing the socket on the idle
    /// rule while both still wait in the client (#1456).
    func testAStopBeforeTheHandshakeFallbackKeepsTheDictation() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        let events = observeSocketEvents(pipeline)
        pipeline.server.setWithholdsSessionCreated(true)
        let viewModel = pipeline.viewModel

        viewModel.startDictation()
        await pipeline.microphone.waitUntilCapturing()
        await events.waitForConnected(1)
        let spoken = Self.speech(seed: 1)
        XCTAssertTrue(pipeline.microphone.deliver(spoken))
        viewModel.stopDictation(reason: "test")
        XCTAssertTrue(viewModel.isFinalizingStop)

        // Past the idle rule (1.5 s open, 0.7 s quiet), short of the 3 s
        // fallback. The finalization loop, its watchdog, and the client's
        // keepalive and fallback timers are armed; once the woken ones sleep
        // again, the loop has judged the quiet.
        await pipeline.clock.waitForSleepers(4)
        let armed = pipeline.clock.pendingSleepers
        pipeline.clock.advance(by: 2)
        await pipeline.clock.waitForSleepers(armed)
        XCTAssertTrue(viewModel.isFinalizingStop, "the stop still waits for the handshake")
        XCTAssertTrue(pipeline.server.frames.isEmpty, "nothing leaves before the send gate opens")

        pipeline.clock.advance(by: 1)
        await pipeline.server.awaitFrame("the final commit") { $0.isFinalCommit }
        let frames = pipeline.server.frames
        let audio = frames.firstIndex { $0.audio == spoken }
        let finalCommit = frames.firstIndex { $0.isFinalCommit }
        XCTAssertNotNil(audio, "the audio goes out")
        if let audio, let finalCommit {
            XCTAssertLessThan(audio, finalCommit, "ahead of the final commit")
        }

        pipeline.server.send(["type": "transcription.done", "text": Self.phrase])
        let recorded = await pipeline.records.waitForCount(1)
        XCTAssertTrue(recorded, "the session never finished and wrote its record")
        XCTAssertEqual(pipeline.overlay.committedTexts, [Self.phrase])
        XCTAssertEqual(pipeline.records.all.map(\.rawText), [Self.phrase])
    }

    // MARK: - Reconnect onto a session that is not ready yet

    /// A reconnect counts once the new server session is ready, not on the
    /// WebSocket upgrade (#1457). Three replacement sockets are upgraded and
    /// closed before their `session.created`: each fails an attempt of the
    /// same run, and the gap audio waits in the chunk buffer for the fourth,
    /// which is ready, instead of dying in a closed socket's queue.
    func testUnreadyUpgradeDoesNotResetRetryBudgetOrConsumeGapAudio() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        let events = observeSocketEvents(pipeline)
        await startAndSpeak(pipeline)
        let gap = Self.speech(seed: 4)

        let run = await dropAndReconnect(
            pipeline, events, attempts: [.closedUnready, .closedUnready, .closedUnready, .handshake], gap: gap
        )
        await run?.value

        await assertReconnected(pipeline, events, dials: 4, gap: gap)
    }

    /// Four replacement sockets upgraded and closed before their handshake
    /// use up the run's four attempts, and the dictation ends as after any
    /// failed reconnect (#1457).
    func testUnreadyUpgradesExhaustTheReconnectRun() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        let events = observeSocketEvents(pipeline)
        await startAndSpeak(pipeline)

        let run = await dropAndReconnect(
            pipeline, events, attempts: Array(repeating: .closedUnready, count: 4), gap: Self.speech(seed: 4)
        )
        await run?.value

        XCTAssertEqual(events.connected, 5, "the first socket, then four attempts of one run")
        XCTAssertFalse(pipeline.viewModel.isDictating)
        XCTAssertEqual(pipeline.viewModel.lastError, DictationViewModel.connectionLostMessage)
    }

    /// A reconnect to a server that never sends `session.created` is ready
    /// when the compatibility fallback opens the send gate, 3 s after the
    /// upgrade: the attempt waits that long rather than abandoning a healthy
    /// socket (GLM review of #1457).
    func testAReconnectToAServerWithoutAHandshakeIsReadyAtTheFallback() async throws {
        let pipeline = try await makePipeline(outputMode: .overlayBuffer)
        let events = observeSocketEvents(pipeline)
        await startAndSpeak(pipeline)
        let gap = Self.speech(seed: 4)

        let run = await dropAndReconnect(pipeline, events, attempts: [.fallback], gap: gap)
        await run?.value

        await assertReconnected(pipeline, events, dials: 1, gap: gap)
    }

    /// How a reconnect attempt's socket ends up in `dropAndReconnect`.
    private enum ReconnectAttempt {
        /// The server closes it after the upgrade, before any handshake.
        case closedUnready
        /// The server sends `session.created`.
        case handshake
        /// The server sends nothing; each poll moves the session clock by
        /// its interval, so the compatibility fallback fires on schedule.
        case fallback
    }

    /// Closes the session's socket from the server, puts `gap` in the chunk
    /// buffer while the session is down, and returns the reconnect run. The
    /// sockets drive the run's sleeps: an attempt's first poll returns once
    /// the session handled that attempt's socket opening, and the later ones
    /// play `attempts` (an attempt past its end is `.closedUnready`).
    private func dropAndReconnect(
        _ pipeline: Pipeline, _ events: HandledSocketEvents, attempts: [ReconnectAttempt], gap: Data,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> Task<Void, Never>? {
        let server = pipeline.server
        let clock = pipeline.clock
        let pollInterval = RealtimeReconnectPolicy.default.pollInterval
        let fallbackDelay = TimeInterval(RealtimeAPIWebSocketClient.sessionCreatedFallbackDelay.components.seconds)
        var attempt = 0
        var polls = 0
        var sinceOpen: TimeInterval = 0
        var end = ReconnectAttempt.closedUnready
        pipeline.viewModel.dependencies.reconnectSleep = { duration in
            guard duration == pollInterval else {
                // The backoff before an attempt: it dials at once.
                attempt += 1
                polls = 0
                sinceOpen = 0
                end = attempts.indices.contains(attempt - 1) ? attempts[attempt - 1] : .closedUnready
                server.setWithholdsSessionCreated(end != .handshake)
                return
            }
            polls += 1
            if polls == 1 {
                await events.waitForConnected(1 + attempt, file: file, line: line)
                if end == .fallback {
                    // The health poll, and the socket's keepalive and
                    // fallback timers, armed when it opened.
                    await clock.waitForSleepers(3, file: file, line: line)
                }
                return
            }
            switch end {
            case .handshake:
                await server.awaitFrame("the handshake's session.update", file: file, line: line) {
                    $0.type == "session.update"
                }
            case .closedUnready where polls == 2:
                server.closeConnection()
                await events.waitForDisconnected(1 + attempt, file: file, line: line)
            case .closedUnready:
                await Task.yield()
            case .fallback:
                let before = sinceOpen
                sinceOpen += duration
                clock.advance(by: duration)
                if before < fallbackDelay - 1e-6, sinceOpen >= fallbackDelay - 1e-6 {
                    await server.awaitFrame("the fallback's session.update", file: file, line: line) {
                        $0.type == "session.update"
                    }
                }
            }
        }

        // The session can still be dictating when the test ends, and the
        // server's teardown then drops its socket: the run that starts must
        // not wait on this test's sockets, or its failure lands in a later
        // test.
        let viewModel = pipeline.viewModel
        addTeardownBlock { @MainActor in viewModel.dependencies.reconnectSleep = { _ in } }

        server.forgetFrames()
        server.closeConnection()
        await events.waitForDisconnected(1, file: file, line: line)
        let run = pipeline.viewModel.session.reconnectTask
        XCTAssertNotNil(run, "the drop starts a reconnect run", file: file, line: line)
        XCTAssertTrue(pipeline.microphone.deliver(gap), file: file, line: line)
        return run
    }

    /// The run ended on its `dials`-th attempt with the session listening,
    /// and the restarted send loop replays `gap` once, on the ready session.
    private func assertReconnected(
        _ pipeline: Pipeline, _ events: HandledSocketEvents, dials: Int, gap: Data,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        XCTAssertEqual(events.connected, 1 + dials, "the first socket, then the run's attempts", file: file, line: line)
        XCTAssertTrue(pipeline.viewModel.isDictating, file: file, line: line)
        XCTAssertFalse(pipeline.viewModel.session.isReconnectingRealtimeSession, file: file, line: line)
        // Past a wrong count the gap went to a socket that is gone, and the
        // wait below could only time out.
        guard events.connected == 1 + dials, pipeline.viewModel.isDictating else { return }

        // The restarted send loop drains the gap one interval after it arms.
        await pipeline.clock.waitForSleepers(pipeline.listeningTimers, file: file, line: line)
        pipeline.clock.advance(by: TimingConstants.audioSendInterval)
        await pipeline.server.awaitFrame("the gap audio", file: file, line: line) { $0.audio == gap }
        let frames = pipeline.server.frames
        XCTAssertEqual(frames.filter { $0.audio == gap }.count, 1, "the gap goes out once", file: file, line: line)
        XCTAssertEqual(
            frames.first?.type, "session.update", "on the ready session, behind its handshake", file: file, line: line
        )
    }

    /// Hands the realtime client's events to the session as the app does,
    /// and counts each one the session has handled.
    private func observeSocketEvents(_ pipeline: Pipeline) -> HandledSocketEvents {
        let events = HandledSocketEvents()
        let session = pipeline.viewModel.session
        session.realtimeAPIClient.setEventHandler { [weak session] event, generation in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    session?.handle(event: event, from: generation)
                    events.record(event)
                }
            }
        }
        return events
    }

    // MARK: - The two halves every scenario shares

    /// Start, open the microphone, connect, and get one captured chunk to the
    /// server through the chunk buffer and the send loop.
    private func startAndSpeak(
        _ pipeline: Pipeline,
        start: ((DictationViewModel) -> Void)? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        if let start { start(pipeline.viewModel) } else { pipeline.viewModel.startDictation() }
        await pipeline.microphone.waitUntilCapturing(file: file, line: line)

        let update = await pipeline.server.awaitFrame("session.update", file: file, line: line) {
            $0.type == "session.update"
        }
        XCTAssertEqual(update?.json["model"] as? String, Self.model, file: file, line: line)
        // The session's timers start at connect and sleep on the clock:
        // armed, they say the session is listening.
        await pipeline.clock.waitForSleepers(pipeline.listeningTimers, file: file, line: line)
        XCTAssertTrue(pipeline.viewModel.isDictating, file: file, line: line)
        XCTAssertEqual(pipeline.viewModel.statusText, "Listening...", file: file, line: line)

        let spoken = Self.speech(seed: 1)
        XCTAssertTrue(pipeline.microphone.deliver(spoken), file: file, line: line)
        // One send interval later the loop drains what the capture buffered.
        pipeline.clock.advance(by: TimingConstants.audioSendInterval)
        await pipeline.server.awaitFrame("the captured audio", file: file, line: line) {
            $0.audio == spoken
        }
        // The send loop runs off the main actor and can reach the server
        // before it sleeps again. Once it does, every timer the session armed
        // is asleep, and a test that counts or reads the clock's deadlines
        // from here sees only the timers it starts itself (#1231).
        await pipeline.clock.waitForSleepers(pipeline.listeningTimers, file: file, line: line)
    }

    /// Sends a segment's final and returns once the overlay shows it. A
    /// stop sent before the client read it would take it for the answer to
    /// the final commit, and finish without the text that follows.
    private func sendSettledFinal(
        _ pipeline: Pipeline, _ text: String, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let shown = BoundedWait()
        pipeline.overlay.onRefresh = { call in
            if call.displayText.contains(text) { shown.resolve() }
        }
        pipeline.server.send(["type": "transcription.done", "text": text])
        let arrived = await shown.value(failAfter: 10)
        XCTAssertTrue(arrived, "the overlay never showed the final", file: file, line: line)
        pipeline.overlay.onRefresh = nil
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
        expectedError: String? = nil,
        finalStatus: String = DictationViewModel.StatusStrings.ready,
        alerts: [String] = [],
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let viewModel = pipeline.viewModel
        let recordsBefore = pipeline.records.all.count
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
        let recorded = await pipeline.records.waitForCount(recordsBefore + 1)
        XCTAssertTrue(recorded, "the session never finished and wrote its record", file: file, line: line)
        await pipeline.server.awaitClose(file: file, line: line)

        XCTAssertFalse(viewModel.isFinalizingStop, file: file, line: line)
        XCTAssertFalse(viewModel.isDictating, file: file, line: line)
        XCTAssertEqual(viewModel.statusText, finalStatus, file: file, line: line)
        XCTAssertEqual(viewModel.lastError, expectedError, file: file, line: line)
        XCTAssertEqual(pipeline.presenter.presented.map(\.title), alerts, file: file, line: line)
    }

    /// True once `condition` holds, re-read whenever an observed property it
    /// read changes; false after `failAfter` seconds of wall time.
    private func waitUntilObserved(
        failAfter: TimeInterval = 10, _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let observed = ObservedCondition(condition)
        observed.check()
        return await observed.wait.value(failAfter: failAfter)
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

        /// The timers a listening session keeps armed: the send loop, the
        /// periodic commit, the microphone health poll and the socket's
        /// keepalive ping, plus the insertion retry in Live Auto-Paste.
        @MainActor var listeningTimers: Int {
            viewModel.session.isLiveAutoPasteModeEnabled ? 5 : 4
        }
    }

    /// True once `count` polish requests arrived, false after 10 s of wall time.
    private func waitForPolishRequests(_ polish: FakePolishingService, _ count: Int) async -> Bool {
        let arrived = BoundedWait()
        Task {
            await polish.waitForRequests(count)
            arrived.resolve()
        }
        return await arrived.value(failAfter: 10)
    }

    private func makePipeline(
        outputMode: DictationOutputMode,
        polish: (any LLMPolishingServicing)? = nil,
        polishEndpoint: String = "http://127.0.0.1:8080/v1/chat/completions",
        earlyPolish: Bool = true,
        contextBudget: RealtimeContextBudget? = nil,
        overlayCoordinator: (any OverlayBufferSessionCoordinating)? = nil,
        workspaceCenter: NotificationCenter? = nil
    ) async throws -> Pipeline {
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
            overlayBufferCoordinator: overlayCoordinator ?? overlay,
            startRuntimeServices: false,
            dependencies: DictationViewModel.Dependencies(
                microphone: { microphone },
                workspaceNotificationCenter: workspaceCenter,
                connectionFailurePresenter: presenter,
                onSessionRecord: { records.append($0) },
                clock: clock.clock,
                realtimeContextLimit: { _ in contextBudget }
            )
        )
        viewModel.appConfigStore = MockAppConfigStore()
        if let polish {
            settings.llmPolishingEnabled = true
            settings.llmPolishingEndpointURL = polishEndpoint
            settings.earlyPolishEnabled = earlyPolish
            settings.polishClipboardContextEnabled = false
            settings.terminalScreenContextEnabled = false
            settings.repoVocabularyEnabled = false
            settings.claudeRepoContextEnabled = false
            viewModel.llmPolishingService = polish
        }
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

    /// Sessions that need you, in the order given, with the cue on and a
    /// focuser that answers `outcome`.
    private func installWaitingSessions(
        _ pipeline: Pipeline,
        _ cwdByID: KeyValuePairs<String, String>,
        outcome: SessionPaneFocusOutcome = .focused(bundleID: TerminalScreenAllowlist.ghosttyBundleID)
    ) -> (tracker: AgentAttentionTracker, focuser: FakeSessionPaneFocuser) {
        let settings = pipeline.viewModel.settings
        settings.agentAttentionEnabled = true
        let origin = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
        var sessions: [ClaudeSessionSnapshot] = []
        for (id, cwd) in cwdByID {
            var snapshot = ClaudeSessionSnapshot(sessionID: id, origin: origin, firstSeen: Date(timeIntervalSince1970: 0))
            snapshot.workspace = ClaudeWorkspaceReference.make(rawCwd: cwd, origin: origin)
            snapshot.process = ClaudeHookProcessInfo(hookPID: 1, claudePID: 2, tty: "/dev/ttys00\(sessions.count)")
            sessions.append(snapshot)
        }
        let live = sessions
        let focuser = FakeSessionPaneFocuser(outcome: outcome)
        pipeline.viewModel.session.sessionNavigator = SessionNavigator(
            liveSessions: { live },
            repositoryRoot: { _ in .unknown },
            focuser: focuser,
            sleep: ManualSessionClock().sleep,
            ttyForegroundPIDs: { _ in [2] }
        )
        var tick = 0.0
        let tracker = AgentAttentionTracker(
            isEnabled: { settings.agentAttentionEnabled },
            isWatching: { _ in false },
            liveSessionIDs: { Set(live.map(\.sessionID)) },
            now: {
                tick += 1
                return Date(timeIntervalSince1970: tick)
            }
        )
        pipeline.viewModel.agentAttention = AgentAttentionModel(tracker: tracker, announcer: nil)
        for session in sessions {
            tracker.receive(.notification, session: session)
        }
        return (tracker, focuser)
    }

    /// An Inbox with one draft for "reach", ready and held for a break
    /// (shown, when `shown`), with the cue on and nobody waiting unless
    /// `attention` is already installed.
    private func installInboxWithDraft(
        _ pipeline: Pipeline, shown: Bool = false, attention: AgentAttentionModel? = nil
    ) async throws -> (model: QuickCaptureInboxModel, github: FakeQuickCaptureGitHub, runner: FakeQuickCaptureDraftRunner) {
        let settings = pipeline.viewModel.settings
        settings.agentAttentionEnabled = true
        if attention == nil {
            let tracker = AgentAttentionTracker(
                isEnabled: { settings.agentAttentionEnabled },
                isWatching: { _ in false },
                liveSessionIDs: { [] },
                now: { Date(timeIntervalSince1970: 0) }
            )
            pipeline.viewModel.agentAttention = AgentAttentionModel(tracker: tracker, announcer: nil)
        }
        let github = FakeQuickCaptureGitHub()
        let runner = FakeQuickCaptureDraftRunner()
        let model = QuickCaptureFixture.model(fileURL: nil, answer: ["reach": 0.9], github: github, runner: runner)
        pipeline.viewModel.installDraftCue(for: model)
        await model.capture(text: "Add a dark mode", historyRecordID: nil).value
        XCTAssertEqual(model.items.first?.isReadyDraft, true)
        if shown { pipeline.viewModel.agentAttention?.reachedBreak() }
        return (model, github, runner)
    }

    /// 100 ms of 16 kHz mono PCM16, different for each seed, so a frame on
    /// the wire names the chunk it carried.
    private static func speech(seed: UInt8) -> Data {
        Data((0..<3_200).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) })
    }
}

/// How the mod's fills settled, in order.
@MainActor
private final class FillSettled {
    private(set) var outcomes: [Bool] = []
    private var watches: [(count: Int, wait: BoundedWait)] = []

    func note(_ filled: Bool) {
        outcomes.append(filled)
        for watch in watches where watch.count == outcomes.count {
            watch.wait.resolve()
        }
    }

    /// True once `count` fills settled; false if not within `failAfter`
    /// seconds of wall time.
    func wait(for count: Int, failAfter: TimeInterval = 10) async -> Bool {
        if outcomes.count >= count { return true }
        let wait = BoundedWait()
        watches.append((count, wait))
        return await wait.value(failAfter: failAfter)
    }
}

/// A fake herdr's focused pane, which the user can be made to leave during
/// a given read the app makes.
private final class HerdrFocus: @unchecked Sendable {
    enum Read { case tty, foreground }

    private let lock = NSLock()
    private var current: String
    private var pending: (pane: String, read: Read, remaining: Int)?

    init(_ pane: String) { current = pane }

    var pane: String { lock.withLock { current } }

    /// The `count`th `read` from now moves the focus to `pane`.
    func switchTo(_ pane: String, during read: Read, count: Int = 1) {
        lock.withLock { pending = (pane, read, count) }
    }

    func read(_ read: Read) {
        lock.withLock {
            guard var next = pending, next.read == read else { return }
            next.remaining -= 1
            if next.remaining == 0 {
                current = next.pane
                pending = nil
            } else {
                pending = next
            }
        }
    }
}

/// The tty a fake terminal's focused pane shows, from any thread.
private final class FocusedPane: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String

    init(_ tty: String) { current = tty }

    var tty: String {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// The texts a fake mod was asked to fill, and the band states it was
/// sent, from any thread.
private final class FillRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var recordedStates: [(phase: ClaudeModChannelWire.Phase?, text: String?)] = []

    private var recordedKinds: [ClaudeModChannelWire.Kind] = []

    func append(_ text: String, kind: ClaudeModChannelWire.Kind = .fill) {
        lock.withLock {
            recorded.append(text)
            recordedKinds.append(kind)
        }
    }

    var texts: [String] { lock.withLock { recorded } }
    var kinds: [ClaudeModChannelWire.Kind] { lock.withLock { recordedKinds } }

    private var draftsRead = 0

    /// How many drafts the mod gave before this one.
    func takeDraftIndex() -> Int {
        lock.withLock {
            defer { draftsRead += 1 }
            return draftsRead
        }
    }

    private var stateObserver: (@Sendable () -> Void)?

    /// Runs after each band state arrives.
    var onState: (@Sendable () -> Void)? {
        get { lock.withLock { stateObserver } }
        set { lock.withLock { stateObserver = newValue } }
    }

    func appendState(_ phase: ClaudeModChannelWire.Phase?, _ text: String?) {
        lock.withLock { recordedStates.append((phase, text)) }
        onState?()
    }

    var states: [(phase: ClaudeModChannelWire.Phase?, text: String?)] { lock.withLock { recordedStates } }
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

/// A condition re-read each time an observed property it read changes.
@MainActor
private final class ObservedCondition {
    let wait = BoundedWait()
    private let condition: @MainActor () -> Bool

    init(_ condition: @escaping @MainActor () -> Bool) {
        self.condition = condition
    }

    func check() {
        let holds = withObservationTracking(condition) { [weak self] in
            Task { @MainActor in self?.check() }
        }
        if holds { wait.resolve() }
    }
}

/// The clipboard a test's paste hook and copy actions share.
@MainActor
private final class FakeClipboard {
    private(set) var text = ""
    private var watches: [(reached: (String) -> Bool, wait: BoundedWait)] = []

    func write(_ value: String) {
        text = value
        for watch in watches where watch.reached(value) {
            watch.wait.resolve()
        }
    }

    /// True once the clipboard satisfies `reached`; false if it does not
    /// within `failAfter` seconds of wall time.
    func waitFor(failAfter: TimeInterval = 10, _ reached: @escaping (String) -> Bool) async -> Bool {
        if reached(text) { return true }
        let wait = BoundedWait()
        watches.append((reached, wait))
        return await wait.value(failAfter: failAfter)
    }
}

/// Numbers the reads of the focused Claude Desktop address, from 1.
private actor DesktopReadCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}

/// What the quick capture sink received, with the records written by then.
private final class QuickCaptures {
    var all: [(text: String, recordsWritten: Int)] = []
}

private final class QuickCaptureHistoryIDs {
    var all: [UUID?] = []
}

private final class QuickCaptureGroups {
    var all: [ProjectGroup?] = []
}

/// The socket openings and closes the session has handled, counted once
/// its handler returned.
@MainActor
private final class HandledSocketEvents {
    private(set) var connected = 0
    private(set) var disconnected = 0
    private var waits: [(isMet: () -> Bool, wait: BoundedWait)] = []

    func record(_ event: RealtimeEvent) {
        switch event {
        case .connected: connected += 1
        case .disconnected: disconnected += 1
        default: return
        }
        for watch in waits where watch.isMet() {
            watch.wait.resolve()
        }
        waits.removeAll { $0.isMet() }
    }

    func waitForConnected(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("\(count) socket openings", file: file, line: line) { self.connected >= count }
    }

    func waitForDisconnected(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("\(count) socket closes", file: file, line: line) { self.disconnected >= count }
    }

    /// Fails the test if `isMet` does not hold within 10 s of wall time.
    private func waitUntil(
        _ description: String, file: StaticString, line: UInt, _ isMet: @escaping () -> Bool
    ) async {
        if isMet() { return }
        let wait = BoundedWait()
        waits.append((isMet, wait))
        if await wait.value(failAfter: 10) { return }
        XCTFail("the session never handled \(description)", file: file, line: line)
    }
}

/// Every record the sessions wrote, in order.
@MainActor
private final class SessionRecords {
    private(set) var all: [DictationSessionRecord] = []
    private var waits: [(count: Int, wait: BoundedWait)] = []

    func append(_ record: DictationSessionRecord) {
        all.append(record)
        for watch in waits where watch.count <= all.count {
            watch.wait.resolve()
        }
        waits.removeAll { $0.count <= all.count }
    }

    /// True once `count` records were written; false if they are not within
    /// `failAfter` seconds of wall time.
    func waitForCount(_ count: Int, failAfter: TimeInterval = 10) async -> Bool {
        if all.count >= count { return true }
        let wait = BoundedWait()
        waits.append((count, wait))
        return await wait.value(failAfter: failAfter)
    }
}
#endif
