import ClaudeContextWire
import Foundation
import XCTest
@testable import localvoxtral

// MARK: - Event reduction

final class ClaudeSessionReducerTests: XCTestCase {
    private let localOrigin = ClaudeTransportOrigin.localAuthenticated(peerUID: 501)
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func newSnapshot(origin: ClaudeTransportOrigin? = nil) -> ClaudeSessionSnapshot {
        ClaudeSessionSnapshot(
            sessionID: "s1",
            origin: origin ?? localOrigin,
            marker: ClaudeSessionMarker(value: "lvx-test"),
            firstSeen: epoch
        )
    }

    private func record(
        _ event: ClaudeHookEvent,
        cwd: String? = nil,
        prompt: String? = nil,
        toolName: String? = nil,
        files: [ClaudeFileTouch] = [],
        process: ClaudeHookProcessInfo? = nil
    ) -> ClaudeHookRecord {
        ClaudeHookRecord(
            event: event,
            sessionID: "s1",
            timestamp: 0,
            rawCwd: cwd,
            prompt: prompt,
            toolName: toolName,
            files: files,
            process: process
        )
    }

    private func reduce(
        _ snapshot: inout ClaudeSessionSnapshot,
        _ record: ClaudeHookRecord,
        at offset: TimeInterval = 0,
        origin: ClaudeTransportOrigin? = nil
    ) {
        ClaudeSessionReducer.reduce(
            &snapshot,
            record: record,
            origin: origin ?? localOrigin,
            now: epoch.addingTimeInterval(offset)
        )
    }

    // MARK: Lifecycle

    func testSessionStartIsIdle() {
        var snapshot = newSnapshot()
        reduce(&snapshot, record(.sessionStart, cwd: "/repo"))
        XCTAssertEqual(snapshot.activity, .idle)
        XCTAssertEqual(snapshot.workspace?.localPath?.path, "/repo")
    }

    func testUserPromptSubmitStoresPromptAndGoesWorking() {
        var snapshot = newSnapshot()
        reduce(&snapshot, record(.userPromptSubmit, prompt: "rename the broker"), at: 5)
        XCTAssertEqual(snapshot.latestPriorUserPrompt, "rename the broker")
        XCTAssertEqual(snapshot.latestPriorUserPromptAt, epoch.addingTimeInterval(5))
        XCTAssertEqual(snapshot.activity, .working)
    }

    func testLaterPromptReplacesEarlierOne() {
        var snapshot = newSnapshot()
        reduce(&snapshot, record(.userPromptSubmit, prompt: "first"), at: 1)
        reduce(&snapshot, record(.userPromptSubmit, prompt: "second"), at: 2)
        XCTAssertEqual(snapshot.latestPriorUserPrompt, "second")
        XCTAssertEqual(snapshot.latestPriorUserPromptAt, epoch.addingTimeInterval(2))
    }

    func testEmptyPromptDoesNotClobberStoredPrompt() {
        var snapshot = newSnapshot()
        reduce(&snapshot, record(.userPromptSubmit, prompt: "kept"), at: 1)
        reduce(&snapshot, record(.userPromptSubmit, prompt: ""), at: 2)
        XCTAssertEqual(snapshot.latestPriorUserPrompt, "kept")
    }

    func testStopReturnsToIdle() {
        var snapshot = newSnapshot()
        reduce(&snapshot, record(.userPromptSubmit, prompt: "go"), at: 1)
        reduce(&snapshot, record(.stop), at: 2)
        XCTAssertEqual(snapshot.activity, .idle)
        XCTAssertEqual(snapshot.latestPriorUserPrompt, "go", "the prompt outlives the turn")
    }

    func testSessionEndMarksEnded() {
        var snapshot = newSnapshot()
        reduce(&snapshot, record(.sessionEnd), at: 3)
        XCTAssertEqual(snapshot.activity, .ended)
    }

    func testEveryEventAdvancesLastActivity() {
        var snapshot = newSnapshot()
        reduce(&snapshot, record(.stop), at: 99)
        XCTAssertEqual(snapshot.lastActivity, epoch.addingTimeInterval(99))
        XCTAssertEqual(snapshot.firstSeen, epoch, "firstSeen is immutable")
    }

    // MARK: Workspace

    func testCwdChangedUpdatesWorkspaceWithoutChangingTurnState() {
        var snapshot = newSnapshot()
        reduce(&snapshot, record(.userPromptSubmit, cwd: "/repo/a", prompt: "go"), at: 1)
        reduce(&snapshot, record(.cwdChanged, cwd: "/repo/b"), at: 2)
        XCTAssertEqual(snapshot.workspace?.localPath?.path, "/repo/b")
        XCTAssertEqual(snapshot.activity, .working, "moving cwd does not end the turn")
    }

    func testRemoteOriginSnapshotExposesNoLocalPath() {
        var snapshot = newSnapshot(origin: .remote(channel: "ssh"))
        reduce(&snapshot, record(.sessionStart, cwd: "/remote/repo"), origin: .remote(channel: "ssh"))
        XCTAssertEqual(snapshot.workspace, .remoteOpaque(label: "repo"))
        XCTAssertNil(snapshot.localWorkspacePath, "remote sessions never expose a local path")
    }

    func testMissingCwdLeavesPreviousWorkspaceIntact() {
        var snapshot = newSnapshot()
        reduce(&snapshot, record(.sessionStart, cwd: "/repo"), at: 1)
        reduce(&snapshot, record(.stop), at: 2)
        XCTAssertEqual(snapshot.workspace?.localPath?.path, "/repo")
    }

    // MARK: Recent files

    func testPostToolUseRecordsFilesMostRecentFirst() {
        var snapshot = newSnapshot()
        reduce(&snapshot, record(.postToolUse, files: [ClaudeFileTouch(path: "/a", kind: .read)]), at: 1)
        reduce(&snapshot, record(.postToolUse, files: [ClaudeFileTouch(path: "/b", kind: .edited)]), at: 2)
        XCTAssertEqual(snapshot.recentFiles.map(\.path), ["/b", "/a"])
        XCTAssertEqual(snapshot.activity, .working)
    }

    func testRetouchPromotesRatherThanDuplicates() {
        var snapshot = newSnapshot()
        reduce(&snapshot, record(.postToolUse, files: [ClaudeFileTouch(path: "/a", kind: .read)]), at: 1)
        reduce(&snapshot, record(.postToolUse, files: [ClaudeFileTouch(path: "/b", kind: .read)]), at: 2)
        reduce(&snapshot, record(.postToolUse, files: [ClaudeFileTouch(path: "/a", kind: .read)]), at: 3)
        XCTAssertEqual(snapshot.recentFiles.map(\.path), ["/a", "/b"])
        XCTAssertEqual(snapshot.recentFiles.first?.lastTouched, epoch.addingTimeInterval(3))
    }

    func testEditOutranksLaterReadOfSameFile() {
        // "I just changed X" is the more useful fact for grounding dictation,
        // so a subsequent read must not downgrade it.
        var snapshot = newSnapshot()
        reduce(&snapshot, record(.postToolUse, files: [ClaudeFileTouch(path: "/a", kind: .edited)]), at: 1)
        reduce(&snapshot, record(.postToolUse, files: [ClaudeFileTouch(path: "/a", kind: .read)]), at: 2)
        XCTAssertEqual(snapshot.recentFiles.count, 1)
        XCTAssertEqual(snapshot.recentFiles.first?.kind, .edited)
    }

    func testReadIsUpgradedByLaterEdit() {
        var snapshot = newSnapshot()
        reduce(&snapshot, record(.postToolUse, files: [ClaudeFileTouch(path: "/a", kind: .read)]), at: 1)
        reduce(&snapshot, record(.postToolUse, files: [ClaudeFileTouch(path: "/a", kind: .edited)]), at: 2)
        XCTAssertEqual(snapshot.recentFiles.first?.kind, .edited)
    }

    func testRecentFilesAreCapped() {
        var snapshot = newSnapshot()
        let cap = ClaudeSessionReducer.maxRecentFiles
        for index in 0..<(cap + 10) {
            reduce(
                &snapshot,
                record(.fileChanged, files: [ClaudeFileTouch(path: "/f\(index)", kind: .read)]),
                at: TimeInterval(index)
            )
        }
        XCTAssertEqual(snapshot.recentFiles.count, cap)
        XCTAssertEqual(snapshot.recentFiles.first?.path, "/f\(cap + 9)", "newest retained")
        XCTAssertFalse(snapshot.recentFiles.contains { $0.path == "/f0" }, "oldest evicted")
    }

    func testProcessMetadataIsRetained() {
        var snapshot = newSnapshot()
        let process = ClaudeHookProcessInfo(
            hookPID: 42, claudePID: 7, tty: "/dev/ttys003", termProgram: "ghostty"
        )
        reduce(&snapshot, record(.sessionStart, process: process))
        XCTAssertEqual(snapshot.process, process)
    }
}
