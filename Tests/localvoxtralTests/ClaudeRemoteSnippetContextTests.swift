import ClaudeContextWire
import Foundation
import XCTest

@testable import localvoxtral

/// Remote tool excerpts, from the wire to the prompt.
///
/// `recentSnippets` was retained, capped, deduplicated, and then read by
/// nothing: the parser filled it, the reducer maintained it, and
/// `ClaudeSessionContextText` never looked. For a remote session those excerpts
/// are the ONLY thing we will ever know about that tree — there is no remote
/// collector and there will not be one — so a dead field there is not a tidy
/// abstention, it is the feature missing.
///
/// These run the real chain rather than hand-built snapshots: parse a payload
/// shaped like what a remote Claude Code POSTs, reduce it, render the context
/// text, prepare it, build the block. The seam that would break silently is
/// between the reducer and the text, which is exactly the seam a unit test on
/// either side alone would keep green.
final class ClaudeRemoteSnippetContextTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)
    private let remoteOrigin = ClaudeTransportOrigin.remote(channel: "ssh")
    private let localOrigin = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)

    /// A `PostToolUse` payload carrying an `Edit`, as the remote plugin sends it.
    private func editPayload(newString: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PostToolUse",
            "session_id": "abc-123",
            "cwd": "/srv/checkout/service",
            "tool_name": "Edit",
            "tool_input": [
                "file_path": "/srv/checkout/service/Sources/RetryBudget.swift",
                "new_string": newString,
            ],
        ])
    }

    private func reduced(
        _ data: Data,
        origin: ClaudeTransportOrigin
    ) -> ClaudeSessionSnapshot {
        let payload = ClaudeRemoteHookPayloadParser.parse(
            data: data,
            fallbackEvent: nil,
            timestamp: 1_700_000_000
        )!
        var snapshot = ClaudeSessionSnapshot(
            sessionID: "abc-123",
            origin: origin,
            marker: ClaudeSessionMarker(value: "lvx-abcd"),
            firstSeen: epoch
        )
        ClaudeSessionReducer.reduce(
            &snapshot,
            record: payload.record,
            origin: origin,
            snippets: payload.snippets,
            now: epoch
        )
        return snapshot
    }

    // MARK: - The chain

    func testRemoteSnippetsReachTheContextTextAndTheBlock() async {
        let snapshot = reduced(
            editPayload(newString: "struct RetryBudget { let maxAttempts: Int }"),
            origin: remoteOrigin
        )
        XCTAssertFalse(snapshot.recentSnippets.isEmpty, "precondition: the parser extracted one")

        let text = ClaudeSessionContextText.text(for: snapshot)
        XCTAssertTrue(
            text.contains("struct RetryBudget { let maxAttempts: Int }"),
            "the excerpt itself must reach the prompt text"
        )
        XCTAssertTrue(
            text.contains("remote host"),
            "and be labelled as foreign — unlabelled quoted text reads as the user's own"
        )

        let preparation = await PolishContextPreparation.prepared(
            text: text,
            transcript: "bump the retry budget max attempts",
            renderBudget: 4_000
        )
        let block = snapshot.claudeContextBlock(excerpt: preparation.excerpt, renderBudget: 4_000)
        XCTAssertNotNil(block)
        XCTAssertTrue(block?.excerpt.contains("RetryBudget") ?? false)
    }

    // The point of attaching them at all: they are grounding material. And
    // grounding runs over the COMPLETE retained text, so a snippet the render
    // budget cut still spells the transcript correctly.
    func testRemoteSnippetsGroundEvenWhenTheRenderBudgetCutsThem() async {
        let snapshot = reduced(
            editPayload(newString: "struct RetryBudget { let maxAttempts: Int }"),
            origin: remoteOrigin
        )
        let text = ClaudeSessionContextText.text(for: snapshot)

        let starved = await PolishContextPreparation.prepared(
            text: text,
            transcript: "bump the retry budget max attempts",
            renderBudget: 0
        )
        XCTAssertEqual(starved.excerpt, "", "precondition: nothing rendered")
        XCTAssertTrue(
            starved.grounding.entries.contains { $0.replaceWith.contains("RetryBudget") },
            "a snippet that never renders must still ground the transcript"
        )
    }

    // MARK: - The origin gate

    // A local session must never attach hook snippets, and the gate is the
    // ORIGIN, not the array being empty. The local NDJSON wire has no snippet
    // field so the array is empty in practice — but "in practice" is not an
    // invariant, and a local session's files are on this machine where the repo
    // collector reads them properly, under caps and exclusions a hook's quoted
    // fragment would skip entirely.
    func testLocalSnapshotNeverAttachesSnippetsEvenIfSomeWereRetained() {
        var snapshot = reduced(
            editPayload(newString: "struct RetryBudget { let maxAttempts: Int }"),
            origin: localOrigin
        )
        // Force the state the wire cannot produce, which is the whole point: if
        // snippets ever arrive on a local session, they must still not attach.
        ClaudeSessionReducer.attach(
            &snapshot,
            snippet: ClaudeContentSnippet(
                label: "Edit new_string",
                kind: .toolInput,
                text: "struct RetryBudget { let maxAttempts: Int }"
            )
        )
        XCTAssertFalse(snapshot.recentSnippets.isEmpty, "precondition: retained")

        let text = ClaudeSessionContextText.text(for: snapshot)
        // Asserted on the snippet BODY, not the file name: the local session's
        // recent-file list legitimately names `RetryBudget.swift` (that is the
        // path list, which is not a snippet). What must not appear is the
        // contents the hook quoted.
        XCTAssertFalse(
            text.contains("maxAttempts"),
            "a local session's hook snippets must never reach the prompt"
        )
        XCTAssertFalse(text.contains("remote host"))
        XCTAssertTrue(
            text.contains("RetryBudget.swift"),
            "precondition: the file list still attaches — this gate is about snippets only"
        )
    }

    // The remote session's own facts still ride alongside the snippets, and its
    // cwd stays a label: `displayName`, never a path.
    func testRemoteSessionTextCarriesTheLabelNotThePath() {
        let snapshot = reduced(editPayload(newString: "let x = 1"), origin: remoteOrigin)
        let text = ClaudeSessionContextText.text(for: snapshot)
        XCTAssertFalse(
            text.contains("/srv/checkout"),
            "a remote path is a description of someone else's filesystem, not context"
        )
        XCTAssertTrue(text.contains("workspace: service"))
    }
}
