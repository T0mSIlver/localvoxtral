import Foundation
import XCTest
@testable import localvoxtral

/// `DictationSessionRecord` is a SwiftData `@Model`, not a plain `Codable`, so
/// the "old records still decode" guarantee is SwiftData lightweight migration:
/// adding an OPTIONAL attribute leaves existing stores readable with the new
/// field defaulting to nil. These tests pin the additive-optional contract at
/// the type level — the legacy initializer shape (no `polishProfile`) still
/// compiles and yields nil, and the new field round-trips when provided.
final class DictationSessionRecordTests: XCTestCase {
    func testLegacyInitializerLeavesPolishProfileNil() {
        // Exactly the argument set every existing call site used before the
        // agent-profile field existed — must still compile and default to nil.
        let record = DictationSessionRecord(
            startedAt: Date(),
            finishedAt: Date(),
            rawText: "hello world",
            provider: "vllm",
            model: "voxtral",
            outputMode: "overlay_buffer",
            status: .sttCompleted,
            commitSucceeded: true
        )

        XCTAssertNil(record.polishProfile)
    }

    func testPolishProfileRoundTripsWhenProvided() {
        let record = DictationSessionRecord(
            startedAt: Date(),
            finishedAt: Date(),
            rawText: "run it with --force",
            polishedText: "Run it with `--force`.",
            provider: "vllm",
            model: "voxtral",
            outputMode: "overlay_buffer",
            status: .completed,
            commitSucceeded: true,
            polishProfile: PolishPromptProfile.agent.rawValue
        )

        XCTAssertEqual(record.polishProfile, "agent")
    }
}
