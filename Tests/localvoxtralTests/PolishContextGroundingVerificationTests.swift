import XCTest
@testable import localvoxtral

final class PolishContextGroundingVerificationTests: XCTestCase {
    private func candidate(
        _ source: PolishContextSource,
        entries: [ReplacementEntry] = [],
        fallbackOnly: Bool = false,
        phonetic: [ReplacementEntry] = [],
        verification: [ReplacementEntry] = []
    ) -> PolishContextGrounding.Candidate {
        PolishContextGrounding.Candidate(
            source: source,
            entries: entries,
            isFallbackOnly: fallbackOnly,
            phoneticEntries: phonetic,
            verificationEntries: verification
        )
    }

    private func entry(_ exact: String, _ heard: String) -> ReplacementEntry {
        ReplacementEntry(replaceWith: exact, matches: [heard])
    }

    func testPhoneticGuessYieldsToSolidWithoutBecomingVerification() {
        let merged = PolishContextGrounding.merge([
            candidate(.repository, phonetic: [entry("Claude Code", "clothes code")]),
            candidate(.clipboard, entries: [entry("ClothesCode", "clothes code")]),
        ])

        XCTAssertEqual(merged.all, [entry("ClothesCode", "clothes code")])
        XCTAssertTrue(merged.verificationPairs.isEmpty)
    }

    func testConflictingPhoneticGuessesAbstainAndBecomeVerificationPairs() {
        let merged = PolishContextGrounding.merge([
            candidate(.repository, phonetic: [entry("SessionSink", "session sing")]),
            candidate(.clipboard, phonetic: [entry("SessionSync", "session sing")]),
        ])

        XCTAssertTrue(merged.all.isEmpty)
        XCTAssertEqual(
            merged.verificationPairs,
            [
                .init(heard: "session sing", exact: "SessionSink"),
                .init(heard: "session sing", exact: "SessionSync"),
            ]
        )
    }

    func testVerificationPassThroughOrderingDedupeStalenessAndCap() {
        let merged = PolishContextGrounding.merge([
            // Deliberately reverse caller order: allocation rank is the
            // stable ordering contract, not array arrival order.
            candidate(
                .clipboard,
                verification: [entry("ClipboardExact", "clipboard heard")]
            ),
            candidate(
                .claude,
                verification: [entry("ClaudeExact", "claude heard")]
            ),
            candidate(
                .terminal,
                entries: [entry("TakenExact", "taken span")],
                verification: [
                    entry("StaleAlternative", "taken-span"),
                    entry("TerminalExact", "terminal heard"),
                ]
            ),
            candidate(
                .repository,
                verification: [
                    entry("RepoExact", "repo heard"),
                    entry("RepoExact", "repo-heard"),
                    entry("identical", "identical"),
                    entry("RepoSecond", "repo second"),
                ]
            ),
        ])

        XCTAssertEqual(
            merged.verificationPairs,
            [
                .init(heard: "repo heard", exact: "RepoExact"),
                .init(heard: "repo second", exact: "RepoSecond"),
                .init(heard: "terminal heard", exact: "TerminalExact"),
                .init(heard: "claude heard", exact: "ClaudeExact"),
            ]
        )
    }

    func testSurvivingPhoneticGuessJoinsAllAndItsSourceHints() {
        let phonetic = entry("terminal pane", "terminal pain")
        let merged = PolishContextGrounding.merge([
            candidate(.terminal, phonetic: [phonetic]),
        ])

        XCTAssertEqual(merged.all, [phonetic])
        XCTAssertEqual(merged.entries(from: .terminal), [phonetic])
        XCTAssertTrue(merged.verificationPairs.isEmpty)
    }

    func testZeroInputHasNoVerificationPairs() {
        XCTAssertTrue(PolishContextGrounding.merge([]).verificationPairs.isEmpty)
        XCTAssertTrue(
            PolishContextGrounding.merge([candidate(.repository)]).verificationPairs.isEmpty
        )
    }
}
