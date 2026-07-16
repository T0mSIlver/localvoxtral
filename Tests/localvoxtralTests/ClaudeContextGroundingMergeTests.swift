import XCTest
@testable import localvoxtral

/// How the Claude repository and session sources behave in the ONE cross-source
/// grounding merge, alongside the terminal and the clipboard.
///
/// The merge rules themselves are `PolishContextGroundingTests`' subject. What
/// is asserted here is that the two new sources are subject to them — a source
/// that appends after the merge has silently opted out of both agreement and
/// conflict detection, and pre-applies its own reading of a contested span
/// unopposed.
final class ClaudeContextGroundingMergeTests: XCTestCase {
    private func candidate(
        _ source: PolishContextSource,
        _ entries: [(exact: String, heard: [String])],
        fallbackOnly: Bool = false
    ) -> PolishContextGrounding.Candidate {
        PolishContextGrounding.Candidate(
            source: source,
            entries: entries.map { ReplacementEntry(replaceWith: $0.exact, matches: $0.heard) },
            isFallbackOnly: fallbackOnly
        )
    }

    // MARK: - Conflict

    /// The repo the speaker is working in and their clipboard reading the same
    /// span as two DIFFERENT terms: neither is pre-applied. Being the stronger
    /// source is not the same as being unopposed — pre-applying the wrong bytes
    /// edits the user's words into something they did not say.
    func testClaudeRepoConflictingWithClipboardAbstainsOnThatSpan() {
        let merged = PolishContextGrounding.merge([
            candidate(.repository, [(exact: "useAuth.ts", heard: ["use auth dot ts"])]),
            candidate(.clipboard, [(exact: "useOAuth.ts", heard: ["use auth dot ts"])]),
        ])
        XCTAssertTrue(
            merged.all.isEmpty,
            "two readings of one span means we do not know which is right"
        )
    }

    /// The session and the terminal screen disagreeing abstains too — no source
    /// is exempt.
    func testClaudeSessionConflictingWithTerminalAbstains() {
        let merged = PolishContextGrounding.merge([
            candidate(.terminal, [(exact: "Payment.swift", heard: ["payment dot swift"])]),
            candidate(.claude, [(exact: "Payments.swift", heard: ["payment dot swift"])]),
        ])
        XCTAssertTrue(merged.all.isEmpty)
    }

    // MARK: - Agreement

    /// The joined session and the repository agreeing corroborate: one entry.
    func testClaudeSessionAgreeingWithRepositoryCollapsesToOneEntry() {
        let merged = PolishContextGrounding.merge([
            candidate(
                .repository,
                [(exact: "PolishContextBudget.swift", heard: ["polish context budget"])]
            ),
            candidate(
                .claude,
                [(exact: "PolishContextBudget.swift", heard: ["polish context budget"])]
            ),
        ])
        XCTAssertEqual(merged.all.count, 1)
        XCTAssertEqual(merged.entries(from: .repository).count, 1)
        XCTAssertEqual(
            merged.entries(from: .claude).count, 0,
            "an agreed term is attributed to the earlier rank, never duplicated into both"
        )
    }

    // MARK: - Fallback provenance

    /// A repo aligned-fallback GUESS yields to a solid hit from another source
    /// on the same span, rather than competing with it.
    func testClaudeRepoFallbackGuessYieldsToASolidClipboardHit() {
        let merged = PolishContextGrounding.merge([
            candidate(
                .repository,
                [(exact: "Widget.swift", heard: ["wigit dot swift"])],
                fallbackOnly: true
            ),
            candidate(.clipboard, [(exact: "Widgit.swift", heard: ["wigit dot swift"])]),
        ])
        XCTAssertEqual(merged.all.map(\.replaceWith), ["Widgit.swift"])
    }

    /// A fallback guess survives when nothing better covers its span.
    func testClaudeRepoFallbackGuessSurvivesUncontested() {
        let merged = PolishContextGrounding.merge([
            candidate(
                .repository,
                [(exact: "Widget.swift", heard: ["wigit dot swift"])],
                fallbackOnly: true
            ),
            candidate(.clipboard, [(exact: "Other.swift", heard: ["other dot swift"])]),
        ])
        XCTAssertEqual(merged.all.map(\.replaceWith), ["Widget.swift", "Other.swift"])
    }

    // MARK: - Order

    /// All four sources at once, in fixed rank order.
    func testAllFourSourcesOrderByRank() {
        let merged = PolishContextGrounding.merge([
            candidate(.clipboard, [(exact: "Clip.swift", heard: ["clip dot swift"])]),
            candidate(.claude, [(exact: "Claude.swift", heard: ["claude dot swift"])]),
            candidate(.terminal, [(exact: "Term.swift", heard: ["term dot swift"])]),
            candidate(.repository, [(exact: "Repo.swift", heard: ["repo dot swift"])]),
        ])
        XCTAssertEqual(
            merged.all.map(\.replaceWith),
            ["Repo.swift", "Term.swift", "Claude.swift", "Clip.swift"]
        )
    }

    /// Two `.repository` candidates — the terminal-cwd vocabulary and the joined
    /// session's repo — share one bucket by design: both are "the repo the
    /// speaker is working in", and they render under one prompt header.
    func testBothRepositoryCandidatesShareOneBucket() {
        let merged = PolishContextGrounding.merge([
            candidate(.repository, [(exact: "A.swift", heard: ["a dot swift"])]),
            candidate(.repository, [(exact: "B.swift", heard: ["b dot swift"])]),
        ])
        XCTAssertEqual(
            merged.entries(from: .repository).map(\.replaceWith), ["A.swift", "B.swift"]
        )
    }
}

/// The budget's generic allocation, which the repository source's internal
/// section split reuses.
final class ClaudeContextBudgetTests: XCTestCase {
    /// The common case: everything fits, so every source is granted its FULL
    /// demand and nothing is trimmed.
    func testAllFourSourcesFitAreGrantedInFull() {
        let allocation = PolishContextBudget.allocate(demands: [
            .repository: 800, .terminal: 400, .claude: 300, .clipboard: 200,
        ])
        XCTAssertEqual(allocation[.repository], 800)
        XCTAssertEqual(allocation[.terminal], 400)
        XCTAssertEqual(allocation[.claude], 300)
        XCTAssertEqual(allocation[.clipboard], 200)
    }

    /// A huge repository must not starve the other sources: every populated
    /// source takes its floor before anyone takes a second helping.
    func testHugeRepositoryDoesNotStarveTheOtherSources() {
        let allocation = PolishContextBudget.allocate(demands: [
            .repository: 5_000_000, .terminal: 900, .claude: 900, .clipboard: 900,
        ])
        for source in [PolishContextSource.terminal, .claude, .clipboard] {
            XCTAssertGreaterThanOrEqual(
                allocation[source] ?? 0,
                PolishContextBudget.sourceFloorCharacters,
                "\(source) was starved by the repository"
            )
        }
        XCTAssertLessThanOrEqual(
            allocation.values.reduce(0, +), PolishContextBudget.totalCharacterBudget
        )
    }

    /// An unpopulated source is never given a floor.
    func testUnpopulatedClaudeSourceIsGrantedNothing() {
        let allocation = PolishContextBudget.allocate(demands: [
            .repository: 5_000_000, .claude: 0,
        ])
        XCTAssertNil(allocation[.claude])
    }

    // MARK: - The generic overload

    /// The repository's section split is the same function, not a similar one.
    func testGenericAllocationHonorsOrderFloorsAndTotal() {
        let order = ClaudeRepoContextSelection.Section.allCases
        let allocation = PolishContextBudget.allocate(
            demands: [.activeFiles: 10_000, .diff: 10_000, .worktree: 10_000, .snippets: 10_000],
            order: order,
            floor: ClaudeRepoContextSelection.sectionFloorCharacters,
            total: 1000
        )
        XCTAssertEqual(allocation.values.reduce(0, +), 1000)
        for section in order {
            XCTAssertGreaterThanOrEqual(
                allocation[section] ?? 0,
                ClaudeRepoContextSelection.sectionFloorCharacters
            )
        }
    }

    /// When the floors alone exceed the total, earlier ranks keep their floor
    /// and later ranks get what is left — a deliberate preference for the more
    /// useful section over an even split that leaves every one of them useless.
    func testFloorsExceedingTotalFavorEarlierSections() {
        let allocation = PolishContextBudget.allocate(
            demands: [.activeFiles: 10_000, .diff: 10_000, .worktree: 10_000, .snippets: 10_000],
            order: ClaudeRepoContextSelection.Section.allCases,
            floor: 150,
            total: 200
        )
        XCTAssertEqual(allocation[.activeFiles], 150)
        XCTAssertEqual(allocation[.diff], 50)
        XCTAssertNil(allocation[.snippets])
        XCTAssertEqual(allocation.values.reduce(0, +), 200)
    }

    /// Never over demand: a section that fits is never told to render padding.
    func testGenericAllocationNeverGrantsMoreThanDemanded() {
        let allocation = PolishContextBudget.allocate(
            demands: [.activeFiles: 10, .diff: 10_000],
            order: ClaudeRepoContextSelection.Section.allCases,
            floor: 150,
            total: 1000
        )
        XCTAssertEqual(allocation[.activeFiles], 10)
    }

    func testGenericAllocationIsDeterministic() {
        let demands: [ClaudeRepoContextSelection.Section: Int] = [
            .activeFiles: 3000, .diff: 2000, .worktree: 100, .snippets: 5000,
        ]
        let first = PolishContextBudget.allocate(
            demands: demands,
            order: ClaudeRepoContextSelection.Section.allCases,
            floor: 150,
            total: 1200
        )
        for _ in 0..<10 {
            XCTAssertEqual(
                first,
                PolishContextBudget.allocate(
                    demands: demands,
                    order: ClaudeRepoContextSelection.Section.allCases,
                    floor: 150,
                    total: 1200
                )
            )
        }
    }
}
