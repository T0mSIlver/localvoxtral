import Foundation
import XCTest
@testable import localvoxtral

/// What must hold when the terminal screen and the clipboard both feed ONE
/// polish request.
///
/// These are the invariants the two features can only break together, so
/// neither source's own suite can catch them: a shared budget that is actually
/// shared, a merge that both sources vote in, one attachment that keeps the
/// prompt cache intact, and a fixed order.
final class PolishContextMultiSourceTests: XCTestCase {
    // MARK: - One budget across sources

    // The regression this file exists for: two sources each allocating from
    // `totalCharacterBudget` would each believe they had all of it and together
    // spend double. One allocation, one total.
    func testCombinedGrantsNeverExceedTheTotalBudget() {
        let allocation = PolishContextBudget.allocate(demands: [
            .terminal: 20_000,
            .clipboard: 500_000,
        ])
        let granted = allocation.values.reduce(0, +)
        XCTAssertLessThanOrEqual(granted, PolishContextBudget.totalCharacterBudget)
        XCTAssertGreaterThan(allocation[.terminal] ?? 0, 0, "an overflowing source still gets its floor")
        XCTAssertGreaterThan(allocation[.clipboard] ?? 0, 0)
    }

    // Everything fits ⇒ everyone renders in full. This is the common case: a
    // short clipboard and one screen of terminal both attach verbatim, and
    // neither is trimmed just because the other exists.
    func testBothSourcesRenderCompletelyWhenTheCombinedContentFits() {
        let allocation = PolishContextBudget.allocate(demands: [
            .terminal: 1_200,
            .clipboard: 800,
        ])
        XCTAssertEqual(allocation[.terminal], 1_200, "a terminal viewport that fits attaches whole")
        XCTAssertEqual(allocation[.clipboard], 800)
    }

    // A source that renders nothing must not reserve budget it cannot spend —
    // an unjoined pane declares no demand, so the clipboard gets everything.
    func testAnUnpopulatedTerminalLeavesTheWholeBudgetToTheClipboard() {
        let withTerminal = PolishContextBudget.allocate(demands: [
            .terminal: 0,
            .clipboard: 500_000,
        ])
        let alone = PolishContextBudget.allocate(demands: [.clipboard: 500_000])
        XCTAssertNil(withTerminal[.terminal], "a zero demand is never granted a floor")
        XCTAssertEqual(withTerminal[.clipboard], alone[.clipboard])
    }

    // MARK: - Ordering

    // Blocks render in the caller's array order, and the transcript stays last.
    // Two sequential prepends would silently reverse this.
    func testBlocksRenderInAllocationRankOrderWithTranscriptLast() {
        let terminal = PolishContextBlock(
            instruction: "TERMINAL", excerpt: "screen text", summary: "screen:11ch"
        )
        let clipboard = PolishContextBlock(
            instruction: "CLIPBOARD", excerpt: "copied text", summary: "clipboard:11ch"
        )
        let prompts = PolishContextBlock.attaching(
            [terminal, clipboard],
            to: ["cached prefix", "transcript goes here"]
        )
        let last = try? XCTUnwrap(prompts.last)
        let terminalIndex = try? XCTUnwrap(last?.range(of: "TERMINAL")?.lowerBound)
        let clipboardIndex = try? XCTUnwrap(last?.range(of: "CLIPBOARD")?.lowerBound)
        XCTAssertNotNil(terminalIndex)
        XCTAssertNotNil(clipboardIndex)
        if let last, let terminalIndex, let clipboardIndex {
            XCTAssertLessThan(
                terminalIndex, clipboardIndex,
                "terminal precedes clipboard, matching PolishContextSource.allocationRank"
            )
            XCTAssertTrue(last.hasSuffix("transcript goes here"), "the transcript must stay last")
        }
    }

    // `allocationRank` is the contract the attach order follows. If these cases
    // are ever reordered, the rendered prompt changes — this is the test that
    // says so out loud.
    func testTerminalOutranksClipboardForAllocationAndOrder() {
        XCTAssertLessThan(
            PolishContextSource.terminal.allocationRank,
            PolishContextSource.clipboard.allocationRank
        )
        XCTAssertLessThan(
            PolishContextSource.repository.allocationRank,
            PolishContextSource.terminal.allocationRank
        )
    }

    // MARK: - Prompt-cache invariance

    // The field bug this whole shape exists to prevent (2026-07-11): context in
    // its own message, or in any earlier message, invalidates polishd's
    // single-slot prefix checkpoint on EVERY request; the cold 4B re-prefill
    // then blew the polish client timeout. Every message before the last must
    // come out byte-identical no matter how many sources attached.
    func testAttachingAnyNumberOfBlocksLeavesTheCachedPrefixByteIdentical() {
        let prefix = ["system-ish cached instructions", "a second cached message"]
        let transcript = "transcript goes here"
        let terminal = PolishContextBlock(instruction: "T", excerpt: "screen", summary: "s")
        let clipboard = PolishContextBlock(instruction: "C", excerpt: "copied", summary: "c")

        for blocks in [[terminal], [clipboard], [terminal, clipboard]] {
            let prompts = PolishContextBlock.attaching(blocks, to: prefix + [transcript])
            XCTAssertEqual(prompts.count, 3, "context must never add a message")
            XCTAssertEqual(Array(prompts.dropLast()), prefix, "the cacheable prefix must be untouched")
            XCTAssertTrue(prompts[2].hasSuffix(transcript), "the transcript must stay last")
        }
    }

    // Attaching nothing must not perturb the request at all — a session with no
    // context must produce byte-identical prompts to one where the feature is
    // off, or the cache split differs between users for no reason.
    func testNoBlocksLeavesPromptsByteIdentical() {
        let prompts = ["cached", "transcript"]
        XCTAssertEqual(PolishContextBlock.attaching([], to: prompts), prompts)
    }

    // MARK: - One composer

    // `attaching` must not re-implement the prompt-cache rule — it delegates.
    // Equal output for a single block is what proves the two paths are one.
    func testAttachingASingleBlockMatchesTheComposerDirectly() {
        let block = PolishContextBlock(instruction: "I", excerpt: "E", summary: "s")
        XCTAssertEqual(
            PolishContextBlock.attaching([block], to: ["cached", "transcript"]),
            PolishContextComposer.prepending(
                contextMessage: block.rendered,
                to: ["cached", "transcript"]
            )
        )
    }

    // Moving the clipboard onto the shared attachment path must not change a
    // single byte of the prompt, or every eval baseline moves with it.
    func testClipboardBlockRendersIdenticallyToItsLegacyContextMessage() {
        let context = PolishClipboardContext(
            retainedText: "useAuth.ts\n---\nnot a fence",
            originalCharacterCount: 27
        )
        let excerpt = "useAuth.ts\n---\nnot a fence"
        let block = context.contextBlock(excerpt: excerpt, renderBudget: 2000)
        XCTAssertEqual(
            block?.rendered,
            PolishContextClipboardReader.contextMessage(excerpt: excerpt, characterCap: 2000)
        )
    }

    // MARK: - Cross-source grounding

    // Two sources reading the same heard span DIFFERENTLY cannot both be right,
    // and pre-applying either edits words the user did not say. Abstain.
    func testTerminalAndClipboardConflictOnASpanAbstains() {
        let merged = PolishContextGrounding.merge([
            PolishContextGrounding.Candidate(
                source: .terminal,
                entries: [ReplacementEntry(replaceWith: "useAuth.ts", matches: ["use auth ts"])],
                isFallbackOnly: false
            ),
            PolishContextGrounding.Candidate(
                source: .clipboard,
                entries: [ReplacementEntry(replaceWith: "useAuthz.ts", matches: ["use auth ts"])],
                isFallbackOnly: false
            ),
        ])
        XCTAssertTrue(merged.all.isEmpty, "a contested span must not be pre-applied by either source")
        XCTAssertTrue(merged.entries(from: .terminal).isEmpty)
        XCTAssertTrue(merged.entries(from: .clipboard).isEmpty)
    }

    // Agreement is corroboration, not conflict: one entry, attributed to the
    // earlier rank, never rendered twice under two headers.
    func testTerminalAndClipboardAgreeingOnATermCollapsesToOneEntry() {
        let entry = ReplacementEntry(replaceWith: "useAuth.ts", matches: ["use auth ts"])
        let merged = PolishContextGrounding.merge([
            PolishContextGrounding.Candidate(source: .terminal, entries: [entry], isFallbackOnly: false),
            PolishContextGrounding.Candidate(source: .clipboard, entries: [entry], isFallbackOnly: false),
        ])
        XCTAssertEqual(merged.all.map(\.replaceWith), ["useAuth.ts"])
        XCTAssertEqual(
            merged.entries(from: .terminal).map(\.replaceWith), ["useAuth.ts"],
            "the earlier allocationRank keeps the term"
        )
        XCTAssertTrue(
            merged.entries(from: .clipboard).isEmpty,
            "an agreed term must not be duplicated into both sources' prompt sections"
        )
    }

    // A terminal fallback GUESS must yield to a solidly grounded repo hit on the
    // same span rather than compete with it.
    func testTerminalFallbackGuessYieldsToASolidRepoHit() {
        let merged = PolishContextGrounding.merge([
            PolishContextGrounding.Candidate(
                source: .repository,
                entries: [ReplacementEntry(replaceWith: "useAuth.ts", matches: ["use auth ts"])],
                isFallbackOnly: false
            ),
            PolishContextGrounding.Candidate(
                source: .terminal,
                entries: [ReplacementEntry(replaceWith: "UseAuthTS", matches: ["use auth ts"])],
                isFallbackOnly: true
            ),
        ])
        XCTAssertEqual(merged.all.map(\.replaceWith), ["useAuth.ts"])
        XCTAssertTrue(merged.entries(from: .terminal).isEmpty)
    }

    // MARK: - Grounding survives a reduced excerpt

    // The AGENTS invariant for this feature: grounding is input-side and costs
    // no prompt characters, so the COMPLETE sanitized text still grounds the
    // transcript even when the budget cut the rendered excerpt to nothing.
    func testFullTextGroundsEvenWhenTheRenderedExcerptIsEmpty() {
        let screen = """
        $ swift build
        error: cannot find 'useAuth' in scope
          Sources/App/useAuth.ts:12
        """
        let prepared = PolishContextPreparation.prepare(
            text: screen,
            transcript: "the use auth ts file is broken",
            renderBudget: 0
        )
        XCTAssertEqual(prepared.excerpt, "", "a zero grant renders nothing")
        XCTAssertFalse(
            prepared.grounding.entries.isEmpty,
            "matching must still see the whole screen — it is local and costs no prompt space"
        )
    }
}
