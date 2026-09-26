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

        service.enqueueRealtimeInsertion("see:\n```\nline one\n```\n\nthanks")

        XCTAssertEqual(posted.value, ["see:", "⇧⏎", "```", "⇧⏎", "line one", "⇧⏎", "```", "⇧⏎", "⇧⏎", "thanks"])
        XCTAssertFalse(service.hasPendingInsertionText)
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

    private func makeRecordingService(frontmostBundleID: String) -> (TextInsertionService, PostedKeys) {
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
