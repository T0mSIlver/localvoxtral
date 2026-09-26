import ClaudeContextWire
import Foundation
import localvoxtralCore

/// Answers every collection with the same snapshot and never touches a
/// filesystem. Nil means "no repository", like the real collector.
package final class StubClaudeRepoCollector: ClaudeRepoCollecting, @unchecked Sendable {
    package let snapshot: ClaudeRepoSnapshot?

    package init(snapshot: ClaudeRepoSnapshot?) {
        self.snapshot = snapshot
    }

    package func collect(
        workspace _: LocalWorkspacePath,
        recentFiles _: [ClaudeRecentFile],
        transcript _: String
    ) async -> ClaudeRepoSnapshot? {
        snapshot
    }
}
