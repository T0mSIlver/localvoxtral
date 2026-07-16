import XCTest
@testable import localvoxtral

final class PolishContextBudgetTests: XCTestCase {
    private typealias Source = PolishContextSource

    // MARK: - Everything fits

    func testEveryPopulatedSourceGetsItsFullDemandWhenTotalFits() {
        let demands: [Source: Int] = [.clipboard: 300, .terminal: 200]
        let allocation = PolishContextBudget.allocate(demands: demands)
        XCTAssertEqual(allocation, demands)
    }

    func testSingleSmallSourceGetsExactlyWhatItAskedFor() {
        let allocation = PolishContextBudget.allocate(demands: [.clipboard: 42])
        XCTAssertEqual(allocation[.clipboard], 42)
    }

    func testDemandExactlyAtTotalIsGrantedWhole() {
        let allocation = PolishContextBudget.allocate(
            demands: [.clipboard: PolishContextBudget.totalCharacterBudget]
        )
        XCTAssertEqual(allocation[.clipboard], PolishContextBudget.totalCharacterBudget)
    }

    // MARK: - Unpopulated sources

    func testZeroAndNegativeAndAbsentDemandsGrantNothing() {
        let allocation = PolishContextBudget.allocate(
            demands: [.clipboard: 100, .terminal: 0, .claude: -5]
        )
        XCTAssertEqual(allocation[.clipboard], 100)
        XCTAssertNil(allocation[.terminal], "an empty source must never be given space")
        XCTAssertNil(allocation[.claude], "a negative demand is a bug, not a credit")
        XCTAssertNil(allocation[.repository])
    }

    func testNoDemandsAllocatesNothing() {
        XCTAssertTrue(PolishContextBudget.allocate(demands: [:]).isEmpty)
    }

    func testZeroTotalAllocatesNothing() {
        XCTAssertTrue(PolishContextBudget.allocate(demands: [.clipboard: 500], total: 0).isEmpty)
    }

    // MARK: - Overflow invariants

    /// The two invariants everything else depends on: the render budget is a
    /// ceiling, and no source is ever told to render more than it has.
    func testOverflowNeverExceedsTotalAndNeverExceedsDemand() {
        let demands: [Source: Int] = [
            .repository: 5000, .terminal: 5000, .claude: 5000, .clipboard: 5000,
        ]
        let allocation = PolishContextBudget.allocate(demands: demands, total: 1000)
        XCTAssertLessThanOrEqual(allocation.values.reduce(0, +), 1000)
        for (source, granted) in allocation {
            XCTAssertLessThanOrEqual(granted, demands[source]!)
        }
    }

    /// Randomized invariant sweep: no demand mix may break the ceiling or
    /// hand a source more than it asked for. Seeded, so a failure reproduces.
    func testInvariantsHoldAcrossManyDemandMixes() {
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            // xorshift64 — deterministic, no dependency on the test order.
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Int(seed % UInt64(bound))
        }
        for _ in 0..<500 {
            var demands: [Source: Int] = [:]
            for source in Source.allCases {
                demands[source] = next(9000)
            }
            let total = next(9000) + 1
            let allocation = PolishContextBudget.allocate(demands: demands, total: total)
            XCTAssertLessThanOrEqual(
                allocation.values.reduce(0, +), total,
                "demands=\(demands) total=\(total)"
            )
            for (source, granted) in allocation {
                XCTAssertLessThanOrEqual(
                    granted, max(0, demands[source] ?? 0),
                    "demands=\(demands) total=\(total)"
                )
                XCTAssertGreaterThan(granted, 0)
            }
        }
    }

    // MARK: - Floors

    /// The reason floors exist: a huge source must not starve a small, highly
    /// relevant one just by asking first or asking bigger.
    func testPopulatedSourceKeepsItsFloorAgainstAHugeCompetitor() {
        let allocation = PolishContextBudget.allocate(
            demands: [.clipboard: 100_000, .terminal: 500],
            total: 2000
        )
        XCTAssertGreaterThanOrEqual(
            allocation[.terminal] ?? 0,
            PolishContextBudget.sourceFloorCharacters
        )
        XCTAssertEqual(allocation.values.reduce(0, +), 2000)
    }

    /// A source demanding less than the floor gets its demand, not the floor —
    /// nobody is padded up.
    func testSourceUnderTheFloorIsNotPaddedUpToIt() {
        let allocation = PolishContextBudget.allocate(
            demands: [.clipboard: 100_000, .terminal: 50],
            total: 2000
        )
        XCTAssertEqual(allocation[.terminal], 50)
        XCTAssertEqual(allocation[.clipboard], 1950, "the unused floor flows on, it is not lost")
        XCTAssertEqual(allocation.values.reduce(0, +), 2000)
    }

    /// Floors alone over budget: earlier ranks win, and the ceiling still holds.
    func testFloorsExceedingTotalFavorEarlierRanksWithoutBreakingTheCeiling() {
        let allocation = PolishContextBudget.allocate(
            demands: [.repository: 5000, .terminal: 5000, .claude: 5000, .clipboard: 5000],
            total: 500
        )
        XCTAssertLessThanOrEqual(allocation.values.reduce(0, +), 500)
        XCTAssertEqual(allocation[.repository], PolishContextBudget.sourceFloorCharacters)
        XCTAssertEqual(allocation[.terminal], 100)
        XCTAssertNil(allocation[.claude])
        XCTAssertNil(allocation[.clipboard])
    }

    // MARK: - Water-filling

    /// Space a nearly-satisfied source cannot use flows to one that can, rather
    /// than being lost to an even split.
    func testLeftoverFromASatisfiedSourceFlowsToAHungryOne() {
        let allocation = PolishContextBudget.allocate(
            demands: [.terminal: 600, .clipboard: 100_000],
            total: 3000
        )
        XCTAssertEqual(allocation[.terminal], 600, "a source that fits is fully served")
        XCTAssertEqual(allocation[.clipboard], 2400, "the rest flows to the hungry source")
        XCTAssertEqual(allocation.values.reduce(0, +), 3000)
    }

    func testEqualDemandsSplitEvenly() {
        let allocation = PolishContextBudget.allocate(
            demands: [.terminal: 10_000, .clipboard: 10_000],
            total: 4000
        )
        XCTAssertEqual(allocation[.terminal], 2000)
        XCTAssertEqual(allocation[.clipboard], 2000)
    }

    /// An indivisible remainder goes to the earlier rank — a rule, not a race.
    func testOddRemainderGoesToTheEarlierRank() {
        let allocation = PolishContextBudget.allocate(
            demands: [.terminal: 10_000, .clipboard: 10_000],
            total: 4001
        )
        XCTAssertEqual(allocation[.terminal], 2001)
        XCTAssertEqual(allocation[.clipboard], 2000)
        XCTAssertEqual(allocation.values.reduce(0, +), 4001)
    }

    // MARK: - Determinism

    /// Dictionary iteration order is not stable across runs; the allocation
    /// must not inherit that. Same demands in ⇒ same split out, always.
    func testAllocationIsDeterministicAcrossRepeatedCalls() {
        let demands: [Source: Int] = [
            .repository: 3000, .terminal: 1200, .claude: 8000, .clipboard: 25_000,
        ]
        let first = PolishContextBudget.allocate(demands: demands, total: 5000)
        for _ in 0..<50 {
            XCTAssertEqual(PolishContextBudget.allocate(demands: demands, total: 5000), first)
        }
    }

    func testAllocationDoesNotDependOnDictionaryInsertionOrder() {
        var forward: [Source: Int] = [:]
        for source in Source.allCases { forward[source] = 7000 }
        var reversed: [Source: Int] = [:]
        for source in Source.allCases.reversed() { reversed[source] = 7000 }
        XCTAssertEqual(
            PolishContextBudget.allocate(demands: forward, total: 3333),
            PolishContextBudget.allocate(demands: reversed, total: 3333)
        )
    }

    // MARK: - Centralization

    /// The default is one constant, not a per-source literal — the whole point
    /// of routing every source through this type.
    func testDefaultTotalIsTheCentralConstant() {
        let allocation = PolishContextBudget.allocate(demands: [.clipboard: 1_000_000])
        XCTAssertEqual(allocation[.clipboard], PolishContextBudget.totalCharacterBudget)
    }
}

// MARK: - Composer

final class PolishContextComposerTests: XCTestCase {
    /// The cached-prefix contract: polishd checkpoints all-but-last messages,
    /// so attaching context must leave every earlier message byte-identical.
    /// Break this and every request pays a cold 4B re-prefill.
    func testEveryMessageBeforeTheLastIsByteIdentical() {
        let prompts = ["cached system-ish preamble", "cached few-shot", "transcript goes here"]
        let updated = PolishContextComposer.prepending(
            contextMessage: "CONTEXT BLOCK",
            to: prompts
        )
        XCTAssertEqual(updated.count, prompts.count)
        XCTAssertEqual(Array(updated.dropLast()), Array(prompts.dropLast()))
    }

    /// Context is prepended INSIDE the final message and the transcript stays
    /// last — this model family echoes instructions placed after the input.
    func testContextRidesInsideTheLastMessageWithTranscriptStillLast() {
        let updated = PolishContextComposer.prepending(
            contextMessage: "CONTEXT BLOCK",
            to: ["cached", "transcript goes here"]
        )
        XCTAssertEqual(updated.count, 2, "no new message may be inserted")
        XCTAssertTrue(updated[1].hasPrefix("CONTEXT BLOCK"))
        XCTAssertTrue(updated[1].hasSuffix("transcript goes here"))
    }

    func testEmptyContextIsANoOp() {
        let prompts = ["cached", "transcript"]
        XCTAssertEqual(PolishContextComposer.prepending(contextMessage: "", to: prompts), prompts)
    }

    func testEmptyPromptListIsANoOp() {
        XCTAssertEqual(PolishContextComposer.prepending(contextMessage: "ctx", to: []), [])
    }

    func testSingleMessageStillGetsContextPrepended() {
        let updated = PolishContextComposer.prepending(contextMessage: "ctx", to: ["transcript"])
        XCTAssertEqual(updated, ["ctx\n\ntranscript"])
    }
}
