import Foundation

/// The two things the app may do to an agent's prompt through a route. There
/// is no third. docs/agent/invariants.md, "The app writes into an agent only
/// through its routes".
package enum AgentPromptCall: Sendable, Equatable {
    case append(String)
    case submit
}

/// One way into one agent's prompt, resolved at dictation start for the
/// session the join named: opencode's prompt relay (#719), a herdr pane
/// (#726) or a cmux surface (#727).
package protocol AgentPromptRoute: Sendable {
    /// For the log: which route refused or delivered.
    var name: String { get }
    /// True only when the target confirmed the call reached the prompt.
    func deliver(_ call: AgentPromptCall) async -> Bool
}

/// One dictation's writes into a route, delivered in the order they were
/// made, one call in flight at a time. The first call that fails ends the
/// route for the rest of the dictation: that call's text and every append
/// queued behind it go to `fallback`, in order, and every later append goes
/// straight there. A submit queued behind a failure is dropped, never turned
/// into a key: the text it would have sent may have gone elsewhere.
@MainActor
package final class AgentPromptSink {
    package let route: any AgentPromptRoute
    private let fallback: @MainActor (String) -> Void
    /// Each call with the fallback its text goes to if it is refused.
    private var queue: [(call: AgentPromptCall, fallback: (@MainActor (String) -> Void)?)] = []
    private var draining = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// False from the first failed call on.
    package private(set) var isHealthy = true

    package init(route: any AgentPromptRoute, fallback: @escaping @MainActor (String) -> Void) {
        self.route = route
        self.fallback = fallback
    }

    /// `fallback`, when given, replaces the sink's own for this text: a
    /// caller that knows where refused text must go (the overlay's commit
    /// target) says so at hand-off, not when the refusal arrives.
    package func append(_ text: String, fallback: (@MainActor (String) -> Void)? = nil) {
        guard !text.isEmpty else { return }
        guard isHealthy else {
            (fallback ?? self.fallback)(text)
            return
        }
        enqueue(.append(text), fallback: fallback)
    }

    /// Submits once every append made before it has landed.
    package func submit() {
        guard isHealthy else {
            Log.backends.notice("\(self.route.name, privacy: .public): route failed earlier; submit dropped")
            return
        }
        enqueue(.submit, fallback: nil)
    }

    /// Returns once nothing is queued or in flight.
    package func waitUntilIdle() async {
        guard draining else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func enqueue(_ call: AgentPromptCall, fallback: (@MainActor (String) -> Void)?) {
        queue.append((call, fallback))
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }

    private func drain() async {
        while let next = queue.first {
            let delivered = await route.deliver(next.call)
            if delivered {
                queue.removeFirst()
                continue
            }
            isHealthy = false
            let pending = queue
            queue.removeAll()
            let refused = pending.compactMap { entry -> (String, (@MainActor (String) -> Void)?)? in
                if case .append(let text) = entry.call { return (text, entry.fallback) }
                return nil
            }
            let droppedSubmits = pending.count - refused.count
            Log.backends.notice(
                "\(self.route.name, privacy: .public): route failed; \(refused.count, privacy: .public) appends go by keystrokes, \(droppedSubmits, privacy: .public) submits dropped"
            )
            for (text, callFallback) in refused { (callFallback ?? fallback)(text) }
        }
        draining = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
