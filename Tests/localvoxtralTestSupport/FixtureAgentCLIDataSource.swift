import ClaudeContextWire
import Foundation
import Synchronization
import localvoxtralCore

/// A fixture store for the `localvoxtral` command (#721): history, terms and
/// status held in memory, with the app's query semantics (newest first, text
/// matched ignoring case and diacritics, `since` inclusive).
package final class FixtureAgentCLIDataSource: AgentCLIDataSource, @unchecked Sendable {
    package struct State: Sendable {
        package var historyKept = true
        package var dictations: [AgentCLIDictation] = []
        package var last: AgentCLIDictation?
        package var userTerms: [String] = []
        package var refusedTerms: [String] = []
        package var learned = LearnedTerms()
        package var status = AgentCLIStatus(running: true)
        package var now = Date(timeIntervalSince1970: 1_790_000_000)

        package init() {}
    }

    package let state: Mutex<State>

    package init(_ state: State = State()) {
        self.state = Mutex(state)
    }

    package func historyKept() async -> Bool { state.withLock { $0.historyKept } }

    package func dictations(matching text: String, since: Date?, limit: Int) async -> [AgentCLIDictation] {
        state.withLock { state in
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            return Array(
                state.dictations
                    .filter { dictation in
                        text.isEmpty
                            || dictation.rawText.range(of: text, options: options) != nil
                            || dictation.finalText.range(of: text, options: options) != nil
                    }
                    .filter { dictation in since.map { dictation.startedAt >= $0 } ?? true }
                    .sorted { $0.startedAt > $1.startedAt }
                    .prefix(limit)
            )
        }
    }

    package func lastDictation() async -> AgentCLIDictation? { state.withLock { $0.last } }
    package func userTerms() async -> [String] { state.withLock { $0.userTerms } }
    package func refusedTerms() async -> [String] { state.withLock { $0.refusedTerms } }
    package func learnedTerms() async -> LearnedTerms { state.withLock { $0.learned } }

    package func recordProposal(
        _ terms: [String],
        proposer: String,
        project: LearnedTermProjectIdentity,
        excluding: [String]
    ) async -> [String] {
        state.withLock { state in
            state.learned.recordCommandProposal(
                terms, proposer: proposer, project: project, excluding: excluding, now: state.now)
        }
    }

    package func status() async -> AgentCLIStatus { state.withLock { $0.status } }
}
