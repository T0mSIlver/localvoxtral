import ClaudeContextWire
import Foundation

// Which agent sessions need the user (#717): one queue across every harness
// and host the registry hears from. A session waits (a permission prompt, a
// question) or has finished its turn while the user looked elsewhere; each
// new entry cues once, and the answer hotkey brings the oldest one's pane
// forward. Owner rulings on #717, 2026-09-26: a wait always cues, a finished
// turn only when the user was not looking at that session's pane, and the
// reply text never reaches the app.

package enum AgentAttentionKind: String, Equatable, Sendable {
    /// The agent waits on a decision: a permission, a question.
    case waiting
    /// The turn ended while the user was not looking at the session's pane.
    case finished
}

package struct AgentAttentionEntry: Equatable, Sendable {
    package var sessionID: String
    package var kind: AgentAttentionKind
    package var since: Date
    /// What the popover line and the banner call the session.
    package var name: String
    package var agent: ClaudeHookAgent

    package init(sessionID: String, kind: AgentAttentionKind, since: Date, name: String, agent: ClaudeHookAgent) {
        self.sessionID = sessionID
        self.kind = kind
        self.since = since
        self.name = name
        self.agent = agent
    }
}

/// What a hook event means for the queue.
package enum AgentAttentionSignal: Equatable, Sendable {
    case waiting
    case turnEnded
    /// The session moved on without the user answering here: a new prompt,
    /// a tool running again after a permission, the session's end.
    case cleared

    package static func of(_ event: ClaudeHookEvent) -> AgentAttentionSignal? {
        switch event {
        case .notification: .waiting
        case .stop: .turnEnded
        case .userPromptSubmit, .postToolUse, .fileChanged, .sessionEnd: .cleared
        case .sessionStart, .cwdChanged, .focusChanged, .focusCleared, .statusQuery: nil
        }
    }
}

/// The sessions that need the user, at most one entry each.
package struct AgentAttentionQueue: Equatable, Sendable {
    package private(set) var entries: [AgentAttentionEntry] = []

    package init() {}

    package var isEmpty: Bool { entries.isEmpty }

    /// The session the answer hotkey goes to: the oldest wait, else the
    /// oldest finished turn.
    package var next: AgentAttentionEntry? {
        entries.filter { $0.kind == .waiting }.min { $0.since < $1.since }
            ?? entries.min { $0.since < $1.since }
    }

    /// A wait. Cues every time, even for a session already waiting: a second
    /// prompt in one turn is a second question. The entry keeps its place.
    @discardableResult
    package mutating func wait(sessionID: String, name: String, agent: ClaudeHookAgent, at time: Date) -> AgentAttentionEntry {
        if let index = entries.firstIndex(where: { $0.sessionID == sessionID }) {
            if entries[index].kind != .waiting {
                entries[index].kind = .waiting
                entries[index].since = time
            }
            entries[index].name = name
            return entries[index]
        }
        let entry = AgentAttentionEntry(sessionID: sessionID, kind: .waiting, since: time, name: name, agent: agent)
        entries.append(entry)
        return entry
    }

    /// A turn's end: whatever the session waited for is over. It stays in
    /// the queue as finished only when the user was not looking at its pane.
    @discardableResult
    package mutating func endTurn(
        sessionID: String, name: String, agent: ClaudeHookAgent, at time: Date, watched: Bool
    ) -> AgentAttentionEntry? {
        remove(sessionID: sessionID)
        guard !watched else { return nil }
        let entry = AgentAttentionEntry(sessionID: sessionID, kind: .finished, since: time, name: name, agent: agent)
        entries.append(entry)
        return entry
    }

    package mutating func remove(sessionID: String) {
        entries.removeAll { $0.sessionID == sessionID }
    }

    /// Drops the sessions the registry no longer holds: one that died
    /// without a session-end event must not keep the cue lit.
    package mutating func retain(liveSessionIDs: Set<String>) {
        entries.removeAll { !liveSessionIDs.contains($0.sessionID) }
    }
}

/// Keeps the queue from the registry's events, in the order they arrived.
@MainActor
package final class AgentAttentionTracker {
    package private(set) var queue = AgentAttentionQueue()
    /// Called with each entry that cues: the sound and the banner.
    package var onCue: ((AgentAttentionEntry) -> Void)?
    /// Called after every change to `queue`.
    package var onChange: (() -> Void)?

    private let isEnabled: () -> Bool
    private let isWatching: (ClaudeSessionSnapshot) async -> Bool
    private let liveSessionIDs: () -> Set<String>
    private let now: () -> Date
    /// Bumped by every event of a session and never reset, so a turn's end
    /// whose pane check finished after the session's next event does not
    /// undo that event.
    private var eventCount: [String: Int] = [:]

    /// - Parameters:
    ///   - isEnabled: whether the user turned the feature on (an answer
    ///     hotkey is set). Off, nothing is queued and the queue empties.
    ///   - isWatching: whether the user is looking at the session's pane now.
    ///     Asked only at a turn's end.
    package init(
        isEnabled: @escaping () -> Bool,
        isWatching: @escaping (ClaudeSessionSnapshot) async -> Bool,
        liveSessionIDs: @escaping () -> Set<String>,
        now: @escaping () -> Date
    ) {
        self.isEnabled = isEnabled
        self.isWatching = isWatching
        self.liveSessionIDs = liveSessionIDs
        self.now = now
    }

    /// Takes one event, in the order the registry accepted them. A turn's
    /// end asks whether the user is looking at the pane; the returned task
    /// finishes when that answer has been applied.
    @discardableResult
    package func receive(_ event: ClaudeHookEvent, session: ClaudeSessionSnapshot) -> Task<Void, Never>? {
        guard let signal = AgentAttentionSignal.of(event) else { return nil }
        guard isEnabled() else {
            clear()
            return nil
        }
        let id = session.sessionID
        eventCount[id, default: 0] += 1
        let count = eventCount[id]
        let name = AgentAttentionText.name(of: session)
        switch signal {
        case .waiting:
            let entry = queue.wait(sessionID: id, name: name, agent: session.agent, at: now())
            changed()
            cue(entry)
            return nil
        case .cleared:
            guard queue.entries.contains(where: { $0.sessionID == id }) else { return nil }
            queue.remove(sessionID: id)
            changed()
            return nil
        case .turnEnded:
            let endedAt = now()
            return Task { @MainActor [weak self] in
                guard let self else { return }
                let watched = await self.isWatching(session)
                // The session's next event, or the user reaching it, came
                // first and decides.
                guard self.eventCount[id] == count, self.isEnabled() else { return }
                let entry = self.queue.endTurn(
                    sessionID: id, name: name, agent: session.agent, at: endedAt, watched: watched
                )
                self.changed()
                if let entry { self.cue(entry) }
            }
        }
    }

    /// The user reached the session: the answer hotkey brought its pane
    /// forward, or a dictation joined it.
    package func answered(sessionID: String) {
        eventCount[sessionID, default: 0] += 1
        guard queue.entries.contains(where: { $0.sessionID == sessionID }) else { return }
        queue.remove(sessionID: sessionID)
        changed()
    }

    /// The oldest entry whose session is still live.
    package func next() -> AgentAttentionEntry? {
        prune()
        return queue.next
    }

    package func prune() {
        let before = queue
        queue.retain(liveSessionIDs: liveSessionIDs())
        if queue != before { changed() }
    }

    package func clear() {
        guard !queue.isEmpty else { return }
        queue = AgentAttentionQueue()
        changed()
    }

    private func cue(_ entry: AgentAttentionEntry) {
        Log.claudeContext.notice("needs-you cue: \(entry.kind.rawValue, privacy: .public)")
        onCue?(entry)
    }

    private func changed() {
        onChange?()
    }
}

/// The words the cue uses. The popover line stays within one line of the
/// 280 pt menu (about 44 characters).
package enum AgentAttentionText {
    package static let maxNameLength = 24
    package static let unnamed = "An agent"

    /// The session's git root or working directory name, with no
    /// filesystem walk: the queue is fed on every hook.
    package static func name(of session: ClaudeSessionSnapshot) -> String {
        let names = SessionDefaultNames.of(session, repositoryRoot: .unknown)
        guard let name = names.primary, !name.isEmpty else { return unnamed }
        return shortened(name)
    }

    package static func shortened(_ name: String) -> String {
        let clean = String(name.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : Character($0)
        })
        guard clean.count > maxNameLength else { return clean }
        return String(clean.prefix(maxNameLength - 1)) + "…"
    }

    /// "payments needs you", "payments finished", with a count of the others.
    package static func popoverLine(_ queue: AgentAttentionQueue) -> String? {
        guard let next = queue.next else { return nil }
        let others = queue.entries.count - 1
        let line = sentence(next)
        return others > 0 ? "\(line) (+\(others))" : line
    }

    package static func sentence(_ entry: AgentAttentionEntry) -> String {
        switch entry.kind {
        case .waiting: "\(entry.name) needs you"
        case .finished: "\(entry.name) finished"
        }
    }

    /// The banner's second line.
    package static func detail(_ entry: AgentAttentionEntry) -> String {
        let agent = agentName(entry.agent)
        return switch entry.kind {
        case .waiting: "\(agent) is waiting for your answer."
        case .finished: "\(agent) finished its turn."
        }
    }

    package static func agentName(_ agent: ClaudeHookAgent) -> String {
        switch agent {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "opencode"
        case .vibe: "Mistral Vibe"
        }
    }
}
