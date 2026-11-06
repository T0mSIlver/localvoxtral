import XCTest
@testable import localvoxtralCore

final class PolishContextGroundingVerificationTests: XCTestCase {
    private func candidate(
        _ source: PolishContextSource,
        entries: [ReplacementEntry] = [],
        verification: [ReplacementEntry] = []
    ) -> PolishContextGrounding.Candidate {
        PolishContextGrounding.Candidate(
            source: source,
            entries: entries,
            verificationEntries: verification
        )
    }

    private func entry(_ exact: String, _ heard: String) -> ReplacementEntry {
        ReplacementEntry(replaceWith: exact, matches: [heard])
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

    func testZeroInputHasNoVerificationPairs() {
        XCTAssertTrue(PolishContextGrounding.merge([]).verificationPairs.isEmpty)
        XCTAssertTrue(
            PolishContextGrounding.merge([candidate(.repository)]).verificationPairs.isEmpty
        )
    }
}
