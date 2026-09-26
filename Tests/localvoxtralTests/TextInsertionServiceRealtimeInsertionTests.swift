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

    // MARK: - Newlines in Claude Desktop (#660)

    /// Claude Desktop dropped a newline that opened a unicode event and
    /// reordered multi-line text sent as consecutive events; Shift+Return
    /// gave a line break (measured 2026-09-26).
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
