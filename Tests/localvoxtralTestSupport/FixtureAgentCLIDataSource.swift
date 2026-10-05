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
        package var doctorFacts = AgentCLIDoctorFacts(
            microphone: .granted,
            accessibilityTrusted: true,
            speech: .managed(.ready),
            polish: .off,
            claudePlugin: nil,
            remoteHosts: [],
            recentJoins: [],
            now: Date(timeIntervalSince1970: 1_790_000_000)
        )
        package var now = Date(timeIntervalSince1970: 1_790_000_000)
        /// Nil: the app has no Inbox.
        package var inbox: QuickCaptureInbox? = QuickCaptureInbox()
        /// The captures `openCapture` brought forward, in order.
        package var opened: [UUID] = []

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
    package func doctorFacts() async -> AgentCLIDoctorFacts { state.withLock { $0.doctorFacts } }

    package func captures() async -> [QuickCaptureItem]? { state.withLock { $0.inbox?.items } }

    package func openCapture(_ id: UUID) async -> Bool? {
        state.withLock { state in
            guard let inbox = state.inbox else { return nil }
            guard inbox.items.contains(where: { $0.id == id }) else { return false }
            state.opened.append(id)
            return true
        }
    }

    package func markCaptureFiled(
        _ id: UUID, url: String
    ) async -> Result<QuickCaptureItem, QuickCaptureInbox.MarkFiledRefusal>? {
        state.withLock { state in
            let now = state.now
            return state.inbox?.markFiled(id, url: url, now: now)
        }
    }
}
