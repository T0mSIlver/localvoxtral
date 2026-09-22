import ClaudeContextWire
import Foundation
@testable import localvoxtral

/// Answers every collection with the same snapshot and never touches a
/// filesystem. Nil means "no repository", like the real collector.
final class StubClaudeRepoCollector: ClaudeRepoCollecting, @unchecked Sendable {
    let snapshot: ClaudeRepoSnapshot?

    init(snapshot: ClaudeRepoSnapshot?) {
        self.snapshot = snapshot
    }

    func collect(
        workspace _: LocalWorkspacePath,
        recentFiles _: [ClaudeRecentFile],
        transcript _: String
    ) async -> ClaudeRepoSnapshot? {
        snapshot
    }
}
