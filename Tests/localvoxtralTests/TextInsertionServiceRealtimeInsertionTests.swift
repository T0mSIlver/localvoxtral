import localvoxtralTestSupport
import XCTest
@testable import localvoxtral

#if DEBUG
@MainActor
final class TextInsertionServiceRealtimeInsertionTests: XCTestCase {
    func testRealtimeFlush_activeModifiersAndKeyboardSuccess_clearsPendingText() {
        let service = TextInsertionService()
        service.debugConfigureInsertionHooks(
            unicodePoster: { _ in true },
            modifierStateReader: { true },
            accessibilityInserter: { _, _ in false }
        )

        service.enqueueRealtimeInsertion("hello")

        XCTAssertFalse(service.hasPendingInsertionText)
        let snapshot = service.debugInsertionSnapshot()
        XCTAssertEqual(snapshot.pendingRealtimeInsertionText, "")
        XCTAssertEqual(snapshot.keyboardFallbackSuccessCount, 1)
        XCTAssertEqual(snapshot.activeModifierFallbackCount, 1)
        XCTAssertEqual(snapshot.axInsertionSuccessCount, 0)
    }

    func testRealtimeFlush_activeModifiersAndInsertionFailure_keepsPendingTextForRetry() {
        let service = TextInsertionService()
        service.debugConfigureInsertionHooks(
            unicodePoster: { _ in false },
            modifierStateReader: { true },
            accessibilityInserter: { _, _ in false }
        )

        service.enqueueRealtimeInsertion("hello")

        XCTAssertTrue(service.hasPendingInsertionText)
        let snapshot = service.debugInsertionSnapshot()
        XCTAssertEqual(snapshot.pendingRealtimeInsertionText, "hello")
        XCTAssertEqual(snapshot.keyboardFallbackSuccessCount, 0)
        XCTAssertEqual(snapshot.activeModifierFallbackCount, 1)
        XCTAssertEqual(snapshot.axInsertionSuccessCount, 0)
    }

    // MARK: - Retry on the session clock (#1060)

    func testFailedLiveInsertionIsRetriedOnTheSessionClockAndNotAfterStop() async {
        let clock = ManualSessionClock()
        let posted = PostedKeys()
        var fieldAccepts = false
        let service = TextInsertionService()
        service.debugConfigureInsertionHooks(
            unicodePoster: { text in
                guard fieldAccepts else { return false }
                posted.value.append(text)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false }
        )
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { "com.example.editor" }
        defer { TerminalTargetDetector.debugFrontmostBundleIDOverride = nil }
        addTeardownBlock { @MainActor in service.stopInsertionRetryTask() }

        service.enqueueRealtimeInsertion("hello")
        service.restartInsertionRetryTask(sleep: clock.clock.sleep) { true }
        await clock.waitForSleepers(1)
        fieldAccepts = true
        clock.advance(by: 0.12)
        await clock.waitForSleepers(1)

        XCTAssertEqual(posted.value, ["hello"])
        XCTAssertFalse(service.hasPendingInsertionText)

        fieldAccepts = false
        service.enqueueRealtimeInsertion(" world")
        service.stopInsertionRetryTask()
        XCTAssertEqual(clock.pendingSleepers, 0, "no retry left to wake")
        fieldAccepts = true
        clock.advance(by: 60)

        XCTAssertEqual(posted.value, ["hello"])
        XCTAssertTrue(service.hasPendingInsertionText)
    }

    // MARK: - Newlines in Claude Desktop (#660)

    /// Claude Desktop dropped a newline that opened a unicode event and
    /// reordered multi-line text sent as consecutive events; Shift+Return
    /// gave a line break (measured 2026-09-26).
    /// A go-to moves the keys mid-dictation; text the route then keeps in
    /// History still belongs to this dictation, so it blocks a keyboard
    /// Return and marks the record not inserted. Once the next dictation
    /// starts, it no longer marks that one (#1466).
    func testTextKeptAfterAGoToStillMarksItsOwnDictation() async {
        for endingDictation in [false, true] {
            let release = BoundedWait()
            let route = ScriptedPromptRoute { _ in
                _ = await release.value(failAfter: 10)
                return .keepInHistory
            }
            let service = TextInsertionService()
            var kept: [String] = []
            service.beginPromptRelay(route, kept: { kept.append($0) })
            let sink = service.promptRelaySink
            service.enqueueRealtimeInsertion("hello")

            service.retirePromptRelay(endingDictation: endingDictation)
            release.resolve()
            await sink?.waitUntilIdle()

            XCTAssertEqual(kept, ["hello"])
            XCTAssertEqual(service.promptRelayKeptText, !endingDictation, "ending: \(endingDictation)")
            XCTAssertEqual(service.liveInsertionTargetPIDs, endingDictation ? [] : [nil], "ending: \(endingDictation)")
        }
    }

    /// The Claude Code mod takes newlines as text, so the session arms no
    /// newline guard. Once a spoken send's ack reports a shortfall, the
    /// keys take over, and a newline in a later delta must not reach them:
    /// it would submit the prompt (#1645).
    func testDeltasTypedAfterTheModRouteFailedHaveTheirNewlinesCollapsed() async throws {
        let (service, posted) = makeRecordingService(frontmostBundleID: TerminalScreenAllowlist.ghosttyBundleID)
        defer { TerminalTargetDetector.debugFrontmostBundleIDOverride = nil }
        let mod = FakeClaudeMod(refuses: "run the tests")
        let hub = ClaudeModChannelHub(sleep: ManualSessionClock().clock.sleep)
        mod.attach(to: hub)
        let opened = await ClaudeModPromptRoute.opened(hub: hub, sessionID: "s1", keysReachThePrompt: { true })
        service.beginPromptRelay(try XCTUnwrap(opened))
        let sink = try XCTUnwrap(service.promptRelaySink)

        service.enqueueRealtimeInsertion("run the tests")
        sink.submit()
        await sink.waitUntilIdle()
        XCTAssertFalse(sink.isHealthy, "the shortfall failed the route over to the keys")
        service.enqueueRealtimeInsertion(" first line\nsecond line")

        XCTAssertEqual(posted.value, ["run the tests", " first line second line"])
        XCTAssertEqual(mod.submitted, [], "the submit is dropped, never a key")
    }

    /// Once the mod route failed over, the keys get the stop's
    /// trailing-space policy a terminal session without the mod gets: a
    /// lone slash command ends without the space that would close Claude
    /// Code's autocomplete, and a space with words after it is typed (#1734).
    func testAfterTheModRouteFailedTheKeysWithholdALoneCommandsTrailingSpaceAtTheStop() async throws {
        for (deltas, expected) in [
            (["/compact "], ["/compact"]),
            (["/compact ", "now "], ["/compact", " now", " "]),
        ] {
            let (service, posted) = makeRecordingService(frontmostBundleID: TerminalScreenAllowlist.ghosttyBundleID)
            defer { TerminalTargetDetector.debugFrontmostBundleIDOverride = nil }
            let mod = FakeClaudeMod(refuses: deltas[0])
            let hub = ClaudeModChannelHub(sleep: ManualSessionClock().clock.sleep)
            mod.attach(to: hub)
            let opened = await ClaudeModPromptRoute.opened(hub: hub, sessionID: "s1", keysReachThePrompt: { true })
            service.beginPromptRelay(try XCTUnwrap(opened))
            let sink = try XCTUnwrap(service.promptRelaySink)

            service.enqueueRealtimeInsertion(deltas[0])
            sink.submit()
            await sink.waitUntilIdle()
            XCTAssertFalse(sink.isHealthy, "the shortfall failed the route over to the keys")
            for delta in deltas.dropFirst() { service.enqueueRealtimeInsertion(delta) }
            service.flushFinalLiveReplacementCorrections()

            XCTAssertEqual(posted.value, expected, "\(deltas)")
            XCTAssertFalse(service.hasPendingInsertionText, "\(deltas)")
        }
    }

    /// A go-to moves the keys to another pane: the stop judges only what
    /// they typed there, so a lone command in the new pane loses its space
    /// whatever the old pane got (#1734).
    func testAfterAGoToTheStopJudgesOnlyTheNewPanesText() async throws {
        let (service, posted) = makeRecordingService(frontmostBundleID: TerminalScreenAllowlist.ghosttyBundleID)
        defer { TerminalTargetDetector.debugFrontmostBundleIDOverride = nil }
        let mod = FakeClaudeMod(refuses: "hello ")
        let hub = ClaudeModChannelHub(sleep: ManualSessionClock().clock.sleep)
        mod.attach(to: hub)
        let opened = await ClaudeModPromptRoute.opened(hub: hub, sessionID: "s1", keysReachThePrompt: { true })
        service.beginPromptRelay(try XCTUnwrap(opened))
        let sink = try XCTUnwrap(service.promptRelaySink)

        service.enqueueRealtimeInsertion("hello ")
        sink.submit()
        await sink.waitUntilIdle()
        XCTAssertFalse(sink.isHealthy, "the shortfall failed the route over to the keys")
        // The go-to's order: flush, then retire.
        service.flushFinalLiveReplacementCorrections()
        service.retirePromptRelay()
        service.enqueueRealtimeInsertion("/compact ")
        service.flushFinalLiveReplacementCorrections()

        XCTAssertEqual(posted.value, ["hello", " ", "/compact"])
    }

    func testClaudeDesktopGetsEachNewlineAsShiftReturn() {
        let (service, posted) = makeRecordingService(frontmostBundleID: ClaudeDesktopAllowlist.bundleID)
        defer { TerminalTargetDetector.debugFrontmostBundleIDOverride = nil }

        service.enqueueRealtimeInsertion("see:\nline one\n\nthanks")

        XCTAssertEqual(posted.value, ["see:", "⇧⏎", "line one", "⇧⏎", "⇧⏎", "thanks"])
        XCTAssertFalse(service.hasPendingInsertionText)
    }

    // MARK: - Code fences in Claude Desktop (#695)

    /// Typed key by key, a fence line opened a Desktop code block that took
    /// the text after the closing fence (measured 2026-09-26), so the text is
    /// pasted whole. The overlay commit's call.
    func testClaudeDesktopGetsTextWithAFenceAsOnePaste() {
        let (service, posted) = makeRecordingService(frontmostBundleID: ClaudeDesktopAllowlist.bundleID)
        defer { TerminalTargetDetector.debugFrontmostBundleIDOverride = nil }
        let text = "see:\n```\nline one\nline two\n```\nthanks"

        let result = service.insertTextPrioritizingKeyboard(text)

        XCTAssertEqual(result, .insertedByKeyboardFallback)
        XCTAssertEqual(posted.value, ["⌘V " + text])
    }

    func testClaudeDesktopTypesTheFenceTextWhenThePasteFails() {
        let (service, posted) = makeRecordingService(
            frontmostBundleID: ClaudeDesktopAllowlist.bundleID,
            pasteSucceeds: false
        )
        defer { TerminalTargetDetector.debugFrontmostBundleIDOverride = nil }

        let result = service.insertTextPrioritizingKeyboard("see:\n```\ncode")

        XCTAssertEqual(result, .insertedByKeyboardFallback)
        XCTAssertEqual(posted.value, ["⌘V see:\n```\ncode", "see:", "⇧⏎", "```", "⇧⏎", "code"])
    }

    func testOtherAppsGetTheFenceTextTyped() {
        let (service, posted) = makeRecordingService(frontmostBundleID: "com.example.editor")
        defer { TerminalTargetDetector.debugFrontmostBundleIDOverride = nil }

        service.enqueueRealtimeInsertion("see:\n```\ncode")

        XCTAssertEqual(posted.value, ["see:\n```\ncode"])
    }

    func testClaudeDesktopTextWithoutNewlinesIsOneUnicodeInsertion() {
        let (service, posted) = makeRecordingService(frontmostBundleID: ClaudeDesktopAllowlist.bundleID)
        defer { TerminalTargetDetector.debugFrontmostBundleIDOverride = nil }

        service.enqueueRealtimeInsertion("run the tests")

        XCTAssertEqual(posted.value, ["run the tests"])
    }

    func testOtherAppsKeepTheirNewlinesInTheUnicodeText() {
        let (service, posted) = makeRecordingService(frontmostBundleID: "com.example.editor")
        defer { TerminalTargetDetector.debugFrontmostBundleIDOverride = nil }

        service.enqueueRealtimeInsertion("one\ntwo")

        XCTAssertEqual(posted.value, ["one\ntwo"])
    }

    private func makeRecordingService(
        frontmostBundleID: String,
        pasteSucceeds: Bool = true
    ) -> (TextInsertionService, PostedKeys) {
        let posted = PostedKeys()
        let service = TextInsertionService()
        service.debugConfigureInsertionHooks(
            unicodePoster: { text in
                posted.value.append(text)
                return true
            },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false },
            shiftReturnPoster: {
                posted.value.append("⇧⏎")
                return true
            },
            commandVPaster: { text in
                posted.value.append("⌘V " + text)
                return pasteSucceeds
            }
        )
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { frontmostBundleID }
        return (service, posted)
    }
}

private final class PostedKeys {
    var value: [String] = []
}
#endif
