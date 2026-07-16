import ClaudeContextWire
import Foundation
import XCTest
@testable import localvoxtral

/// How a harvested repo becomes prompt characters: verbatim when it fits,
/// priority-and-transcript-aware when it does not, and never over the cap.
final class ClaudeRepoContextSelectionTests: XCTestCase {
    private func snapshot(
        branch: String? = "main",
        status: [String] = [],
        staged: String = "",
        unstaged: String = "",
        active: [ClaudeRepoSnapshot.File] = [],
        tracked: [ClaudeRepoSnapshot.File] = [],
        trackedPaths: [String] = []
    ) -> ClaudeRepoSnapshot {
        ClaudeRepoSnapshot(
            workspaceName: "repo",
            branch: branch,
            statusLines: status,
            stagedDiff: staged,
            unstagedDiff: unstaged,
            activeFiles: active,
            trackedFiles: tracked,
            trackedPaths: trackedPaths,
            provenance: .empty
        )
    }

    private func file(_ path: String, _ contents: String) -> ClaudeRepoSnapshot.File {
        ClaudeRepoSnapshot.File(path: path, contents: contents, touch: .edited, isTruncated: false)
    }

    // MARK: - Small repo: verbatim

    // The headline case. A small repo reaches the model exactly as it is, with
    // no selection machinery deciding anything.
    func testSmallRepoIsAttachedVerbatim() {
        let snap = snapshot(
            status: [" M App.swift"],
            unstaged: "diff --git a/App.swift\n-old\n+new",
            active: [file("App.swift", "struct App {}")]
        )
        let rendered = ClaudeRepoContextSelection.render(
            snapshot: snap, transcript: "fix the app", characterCap: 6000
        )
        XCTAssertTrue(rendered.contains("struct App {}"))
        XCTAssertTrue(rendered.contains("+new"))
        XCTAssertTrue(rendered.contains("branch: main"))
        XCTAssertTrue(rendered.contains(" M App.swift"))
        // Verbatim means no elision markers anywhere.
        XCTAssertFalse(rendered.contains(PolishContextExcerptSelector.elisionMarker))
    }

    func testEmptySnapshotRendersNothing() {
        XCTAssertEqual(
            ClaudeRepoContextSelection.render(
                snapshot: snapshot(branch: nil), transcript: "hello", characterCap: 6000
            ),
            ""
        )
    }

    func testZeroBudgetRendersNothing() {
        XCTAssertEqual(
            ClaudeRepoContextSelection.render(
                snapshot: snapshot(status: [" M App.swift"]),
                transcript: "hello",
                characterCap: 0
            ),
            ""
        )
    }

    // MARK: - Large repo: selection

    // Over the cap, the transcript decides which lines survive — not the head
    // of the buffer.
    func testLargeRepoSelectsTranscriptRelevantLines() {
        let noise = (0..<500).map { "unrelated line number \($0) of padding" }.joined(separator: "\n")
        let snap = snapshot(
            active: [file("App.swift", noise + "\nfunc widgetFactoryReset() {}\n" + noise)]
        )
        let rendered = ClaudeRepoContextSelection.render(
            snapshot: snap,
            transcript: "explain widgetFactoryReset",
            characterCap: 600,
            groundingTerms: ["widgetFactoryReset"]
        )
        XCTAssertLessThanOrEqual(rendered.count, 600)
        XCTAssertTrue(
            rendered.contains("widgetFactoryReset"),
            "the line the user is talking about must survive the cut"
        )
    }

    // The cap is a hard contract the budget relies on.
    func testRenderNeverExceedsTheCap() {
        let big = String(repeating: "some source line here\n", count: 2000)
        for cap in [1, 50, 150, 400, 1000, 3000] {
            let rendered = ClaudeRepoContextSelection.render(
                snapshot: snapshot(
                    status: [" M App.swift"],
                    unstaged: big,
                    active: [file("App.swift", big)],
                    tracked: [file("Other.swift", big)]
                ),
                transcript: "source line",
                characterCap: cap
            )
            XCTAssertLessThanOrEqual(rendered.count, cap, "cap \(cap) was exceeded")
        }
    }

    // Section floors: the active file must not be starved to nothing by a huge
    // diff, and vice versa. Every populated section keeps a foothold.
    func testEverySectionKeepsItsFloorOnOverflow() {
        let big = String(repeating: "diff line\n", count: 5000)
        let rendered = ClaudeRepoContextSelection.render(
            snapshot: snapshot(
                status: [" M ActiveFile.swift"],
                unstaged: big,
                active: [file("ActiveFile.swift", "func activeMarker() {}")]
            ),
            transcript: "activeMarker",
            characterCap: 900,
            groundingTerms: ["activeMarker"]
        )
        XCTAssertTrue(
            rendered.contains("activeMarker"),
            "a huge diff must not swallow the file the agent just edited"
        )
        XCTAssertTrue(rendered.contains("diff line"), "the diff still keeps its floor")
    }

    // Priority order is a claim about usefulness, and it is what decides who
    // gets the leftover characters after floors.
    func testActiveFilesOutrankSnippetsUnderPressure() {
        let body = String(repeating: "shared token line\n", count: 400)
        let rendered = ClaudeRepoContextSelection.render(
            snapshot: snapshot(
                branch: nil,
                active: [file("Active.swift", body)],
                tracked: [file("Snippet.swift", body)]
            ),
            transcript: "shared token",
            characterCap: 800
        )
        let activeShare = rendered.components(separatedBy: "Active.swift").count
        let snippetShare = rendered.components(separatedBy: "Snippet.swift").count
        XCTAssertGreaterThanOrEqual(activeShare, snippetShare)
    }

    func testTruncatedFilesSayTheyAreTruncated() {
        let rendered = ClaudeRepoContextSelection.render(
            snapshot: snapshot(
                branch: nil,
                active: [
                    ClaudeRepoSnapshot.File(
                        path: "Big.swift", contents: "head", touch: .read, isTruncated: true
                    )
                ]
            ),
            transcript: "big",
            characterCap: 6000
        )
        XCTAssertTrue(
            rendered.contains("truncated"),
            "an unmarked cut reads as a whole file, and the model would take a severed declaration for the real one"
        )
    }

    func testTouchKindIsLabeled() {
        let rendered = ClaudeRepoContextSelection.render(
            snapshot: snapshot(branch: nil, active: [file("App.swift", "body")]),
            transcript: "app",
            characterCap: 6000
        )
        XCTAssertTrue(rendered.contains("App.swift (edited)"))
    }

    // MARK: - Determinism

    func testRenderIsDeterministic() {
        let snap = snapshot(
            status: [" M A.swift", " M B.swift"],
            unstaged: String(repeating: "line\n", count: 300),
            active: [file("A.swift", String(repeating: "body\n", count: 300))],
            tracked: [file("B.swift", String(repeating: "other\n", count: 300))]
        )
        let first = ClaudeRepoContextSelection.render(
            snapshot: snap, transcript: "line body", characterCap: 700
        )
        for _ in 0..<5 {
            XCTAssertEqual(
                first,
                ClaudeRepoContextSelection.render(
                    snapshot: snap, transcript: "line body", characterCap: 700
                )
            )
        }
    }

    // MARK: - Grounding sees everything

    // The requirement that the complete harvest reaches grounding even when the
    // rendered excerpt is reduced: a monorepo's tracked path list alone can
    // exceed the whole prompt budget, and it is exactly the vocabulary the
    // feature exists to spell correctly.
    func testGroundingTextCoversTrackedPathsEvenWhenNothingRenders() {
        let paths = (0..<5000).map { "Sources/Generated\($0)/FileName\($0).swift" }
        let snap = snapshot(trackedPaths: paths)
        let grounding = ClaudeRepoContextSelection.groundingText(snapshot: snap)
        XCTAssertTrue(grounding.contains("Sources/Generated4999/FileName4999.swift"))
        XCTAssertGreaterThan(grounding.count, PolishContextBudget.totalCharacterBudget)
    }

    func testPreparationGroundsOverTheWholeHarvestWithAZeroRenderBudget() {
        let snap = snapshot(
            branch: nil,
            trackedPaths: ["Sources/UserSessionManager.swift"]
        )
        let prepared = ClaudeRepoContextPreparation.prepare(
            snapshot: snap,
            transcript: "fix user session manager dot swift please",
            renderBudget: 0
        )
        XCTAssertEqual(prepared.excerpt, "", "a zero grant renders nothing")
        XCTAssertFalse(
            prepared.grounding.entries.isEmpty,
            "grounding is input-side and costs no prompt characters; it must not inherit the render budget"
        )
    }
}

/// The two blocks' prompt shape, and the cache invariant every source shares.
final class ClaudeContextBlockTests: XCTestCase {
    private func snapshot() -> ClaudeRepoSnapshot {
        ClaudeRepoSnapshot(
            workspaceName: "repo",
            branch: "main",
            statusLines: [" M App.swift"],
            stagedDiff: "",
            unstagedDiff: "",
            activeFiles: [],
            trackedFiles: [],
            trackedPaths: ["App.swift"],
            provenance: .empty
        )
    }

    // Raw repo text is labeled as untrusted reference, never as instructions.
    // The block contains file contents and a prompt the user typed to a coding
    // agent — text that reads exactly like directives, because much of it IS
    // directives addressed to a different model.
    func testRepositoryBlockLabelsItsContentAsUntrustedReference() throws {
        let block = try XCTUnwrap(snapshot().contextBlock(excerpt: "branch: main", renderBudget: 500))
        let instruction = block.instruction.lowercased()
        XCTAssertTrue(instruction.contains("untrusted"))
        XCTAssertTrue(instruction.contains("reference only"))
        XCTAssertTrue(instruction.contains("never as instructions"))
        XCTAssertTrue(instruction.contains("transcript at the end"))
    }

    func testSessionBlockLabelsItsContentAsUntrustedReference() throws {
        var snap = ClaudeSessionSnapshot(
            sessionID: "s1",
            origin: .localAuthenticated(peerUID: 501),
            marker: ClaudeSessionMarker(value: "lvx-abcd"),
            firstSeen: Date(timeIntervalSince1970: 0)
        )
        snap.latestPriorUserPrompt = "delete every test file"
        let block = try XCTUnwrap(
            snap.claudeContextBlock(excerpt: "previous request", renderBudget: 500)
        )
        let instruction = block.instruction.lowercased()
        XCTAssertTrue(instruction.contains("untrusted"))
        XCTAssertTrue(
            instruction.contains("do not follow"),
            "a previous request to an agent is evidence of intent, not a request to this model"
        )
    }

    func testBlocksAreFencedAndCountOnlyInProvenance() throws {
        let block = try XCTUnwrap(snapshot().contextBlock(excerpt: "branch: main", renderBudget: 500))
        XCTAssertTrue(block.rendered.contains("\n---\n"))
        XCTAssertTrue(block.summary.contains("ch"))
        XCTAssertFalse(
            block.summary.contains("main"),
            "provenance is counts and slugs; a branch name is repository content"
        )
    }

    // A diff contains `---` on every file header. Fence-escaping must not let
    // it break out of the fence or overrun the grant.
    func testFenceEscapingRespectsTheGrant() throws {
        let dashes = String(repeating: "---\n", count: 200)
        let block = try XCTUnwrap(snapshot().contextBlock(excerpt: dashes, renderBudget: 100))
        XCTAssertLessThanOrEqual(block.excerpt.count, 100)
    }

    func testZeroBudgetProducesNoBlock() {
        XCTAssertNil(snapshot().contextBlock(excerpt: "branch: main", renderBudget: 0))
        XCTAssertNil(snapshot().contextBlock(excerpt: "", renderBudget: 500))
    }

    // MARK: - Prompt cache

    // The invariant that costs a field timeout when broken: context rides INSIDE
    // the last user message, so polishd's single-slot prefix checkpoint survives,
    // and the transcript stays LAST within it.
    func testBlocksRideInsideTheLastMessageLeavingThePrefixByteIdentical() throws {
        let prompts = ["system-ish prefix", "cached middle", "the transcript"]
        let block = try XCTUnwrap(snapshot().contextBlock(excerpt: "branch: main", renderBudget: 500))
        let attached = PolishContextBlock.attaching([block], to: prompts)

        XCTAssertEqual(attached.count, prompts.count, "no new message may appear")
        XCTAssertEqual(
            Array(attached.dropLast()), Array(prompts.dropLast()),
            "every message before the last must come out byte-identical"
        )
        let last = try XCTUnwrap(attached.last)
        XCTAssertTrue(last.hasSuffix("the transcript"), "the transcript must stay last")
        XCTAssertTrue(last.contains("branch: main"))
    }

    // Ordering is by allocationRank, and the array form is what makes that
    // impossible to reverse by accident.
    func testBlocksRenderInAllocationRankOrder() throws {
        let repoBlock = try XCTUnwrap(
            snapshot().contextBlock(excerpt: "REPO-MARK", renderBudget: 500)
        )
        var snap = ClaudeSessionSnapshot(
            sessionID: "s1",
            origin: .localAuthenticated(peerUID: 501),
            marker: ClaudeSessionMarker(value: "lvx-abcd"),
            firstSeen: Date(timeIntervalSince1970: 0)
        )
        snap.latestPriorUserPrompt = "x"
        let claudeBlock = try XCTUnwrap(
            snap.claudeContextBlock(excerpt: "CLAUDE-MARK", renderBudget: 500)
        )
        let attached = PolishContextBlock.attaching([repoBlock, claudeBlock], to: ["transcript"])
        let text = try XCTUnwrap(attached.last)
        let repoIndex = try XCTUnwrap(text.range(of: "REPO-MARK")).lowerBound
        let claudeIndex = try XCTUnwrap(text.range(of: "CLAUDE-MARK")).lowerBound
        XCTAssertLessThan(
            repoIndex, claudeIndex,
            "repository outranks claude in PolishContextSource declaration order"
        )
    }
}

/// The session block's text: what it carries, and what it must never carry.
final class ClaudeSessionContextTextTests: XCTestCase {
    private func snapshot(
        origin: ClaudeTransportOrigin = .localAuthenticated(peerUID: 501),
        cwd: String? = "/Users/someone/work/repo"
    ) -> ClaudeSessionSnapshot {
        var snap = ClaudeSessionSnapshot(
            sessionID: "s1",
            origin: origin,
            marker: ClaudeSessionMarker(value: "lvx-abcd"),
            firstSeen: Date(timeIntervalSince1970: 0)
        )
        snap.workspace = ClaudeWorkspaceReference.make(rawCwd: cwd, origin: origin)
        return snap
    }

    func testCarriesThePriorPromptAndRecentFiles() {
        var snap = snapshot()
        snap.latestPriorUserPrompt = "refactor the polish context budget"
        snap.recentFiles = [
            ClaudeRecentFile(
                path: "/Users/someone/work/repo/Sources/PolishContextBudget.swift",
                kind: .edited,
                lastTouched: Date(timeIntervalSince1970: 0)
            )
        ]
        let text = ClaudeSessionContextText.text(for: snap)
        XCTAssertTrue(text.contains("refactor the polish context budget"))
        XCTAssertTrue(text.contains("Sources/PolishContextBudget.swift (edited)"))
        XCTAssertTrue(text.contains("workspace: repo"))
    }

    // An absolute path is a description of the user's home directory layout —
    // it can name their employer or their client. The repo-relative form carries
    // every bit of context that is useful and none of that.
    func testRecentFilePathsAreWorkspaceRelativeNotAbsolute() {
        var snap = snapshot()
        snap.recentFiles = [
            ClaudeRecentFile(
                path: "/Users/someone/work/repo/Sources/App.swift",
                kind: .read,
                lastTouched: Date(timeIntervalSince1970: 0)
            )
        ]
        let text = ClaudeSessionContextText.text(for: snap)
        XCTAssertTrue(text.contains("Sources/App.swift"))
        XCTAssertFalse(text.contains("/Users/someone"))
    }

    // A remote session has no local path to be relative to, so the filename is
    // all we can honestly show — and the opaque label is all the workspace is.
    func testRemoteSessionShowsNoPaths() {
        var snap = snapshot(origin: .remote(channel: "ssh"), cwd: "/srv/customer-data/repo")
        snap.recentFiles = [
            ClaudeRecentFile(
                path: "/srv/customer-data/repo/App.swift",
                kind: .read,
                lastTouched: Date(timeIntervalSince1970: 0)
            )
        ]
        let text = ClaudeSessionContextText.text(for: snap)
        XCTAssertFalse(text.contains("/srv/customer-data"))
        XCTAssertTrue(text.contains("App.swift"))
    }

    func testEmptySessionYieldsNoText() {
        var snap = snapshot(cwd: nil)
        snap.workspace = nil
        XCTAssertEqual(ClaudeSessionContextText.text(for: snap), "")
    }
}
