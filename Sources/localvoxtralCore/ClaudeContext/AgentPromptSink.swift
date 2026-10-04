import Foundation

/// The two things the app may do to an agent's prompt through a route. There
/// is no third. docs/agent/invariants.md, "The app writes into an agent only
/// through its routes".
package enum AgentPromptCall: Sendable, Equatable {
    case append(String)
    case submit
}

/// What became of one call, and so where its text goes.
package enum AgentPromptDelivery: Sendable, Equatable {
    /// The target confirmed the call reached the prompt.
    case delivered
    /// Not delivered, and keystrokes would reach the same prompt: the text
    /// is typed instead.
    case typeInstead
    /// Not delivered, or not known to be, and typing would put the text
    /// somewhere else or in twice: the target is not frontmost, or the
    /// call may have landed. The text is typed nowhere; it stays in History.
    case keepInHistory
}

/// One way into one agent's prompt, resolved at dictation start for the
/// session the join named: opencode's prompt relay (#719), a herdr pane
/// (#726) or a cmux surface (#727).
package protocol AgentPromptRoute: Sendable {
    /// For the log: which route refused or delivered.
    var name: String { get }
    func deliver(_ call: AgentPromptCall) async -> AgentPromptDelivery
    /// The appends this route answered `delivered` on hand-off but has not
    /// confirmed landed, settled now: a route whose appends go unanswered
    /// (the Claude Code mod's, #1645) learns here how far the target got.
    /// What did not land comes back in order, with where it goes.
    func settle() async -> AgentPromptSettlement
    /// Whether text goes to this route as dictated, without the terminal's
    /// newline guard and trailing-space policy, which exist for keys. What
    /// such a route gives back is sanitized before it is typed.
    var takesUnsanitizedText: Bool { get }
}

/// What `AgentPromptRoute.settle` found: the texts that did not land, in
/// the order they were appended, and whether they are typed or kept.
package struct AgentPromptSettlement: Sendable, Equatable {
    package var unlanded: [String]
    /// `typeInstead` or `keepInHistory` when `unlanded` is not empty.
    package var outcome: AgentPromptDelivery

    package init(unlanded: [String] = [], outcome: AgentPromptDelivery = .delivered) {
        self.unlanded = unlanded
        self.outcome = outcome
    }

    package static let allLanded = AgentPromptSettlement()
}

extension AgentPromptRoute {
    /// A route that answers each call once it landed has nothing to settle.
    package func settle() async -> AgentPromptSettlement { .allLanded }

    package var takesUnsanitizedText: Bool { false }
}

/// One dictation's writes into a route, delivered in the order they were
/// made, one call in flight at a time. The first call that fails ends the
/// route for the rest of the dictation: that call's text and every append
/// queued behind it go to `fallback`, in order, and every later append goes
/// straight there. When the route says `keepInHistory`, they go to `kept`
/// instead and nothing is typed. A submit queued behind a failure is
/// dropped, never turned into a key: the text it would have sent may have
/// gone elsewhere. Appends the route accepted without confirming them go
/// first, once it settles them: after a failure, and at `finish`.
@MainActor
package final class AgentPromptSink {
    /// One entry of the queue: a call, or the stop's settling of the route.
    private enum Step {
        case call(AgentPromptCall)
        case settle
    }

    package let route: any AgentPromptRoute
    private let fallback: @MainActor (String) -> Void
    private let kept: @MainActor (String) -> Void
    /// Each step with the fallback its text goes to if it is refused.
    private var queue: [(step: Step, fallback: (@MainActor (String) -> Void)?)] = []
    private var draining = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Set by the first failed call: where every later text goes.
    private var failure: AgentPromptDelivery?

    /// False from the first failed call on.
    package var isHealthy: Bool { failure == nil }

    /// Whether text handed over now stays off the keyboard: the route is
    /// healthy, or it failed with `keepInHistory`, after which the rest of
    /// the dictation is kept, not typed.
    package var takesText: Bool { failure == nil || failure == .keepInHistory }

    /// - Parameters:
    ///   - fallback: types a text the route did not take.
    ///   - kept: told of a text that is typed nowhere, so the user can be
    ///     pointed to History.
    package init(
        route: any AgentPromptRoute,
        kept: @escaping @MainActor (String) -> Void = { _ in },
        fallback: @escaping @MainActor (String) -> Void
    ) {
        self.route = route
        self.kept = kept
        self.fallback = fallback
    }

    /// `fallback`, when given, replaces the sink's own for this text: a
    /// caller that knows where refused text must go (the overlay's commit
    /// target) says so at hand-off, not when the refusal arrives.
    package func append(_ text: String, fallback: (@MainActor (String) -> Void)? = nil) {
        guard !text.isEmpty else { return }
        guard let failure else {
            enqueue(.call(.append(text)), fallback: fallback)
            return
        }
        divert(text, after: failure, fallback: fallback)
    }

    /// Submits once every append made before it has landed.
    package func submit() {
        guard isHealthy else {
            Log.backends.notice("\(self.route.name, privacy: .public): route failed earlier; submit dropped")
            return
        }
        enqueue(.call(.submit), fallback: nil)
    }

    /// The stop: once every call made before it was handled, the route
    /// settles the appends it has not confirmed, and what did not land is
    /// typed or kept like a refusal.
    package func finish() {
        guard isHealthy else { return }
        enqueue(.settle, fallback: nil)
    }

    /// Returns once nothing is queued or in flight.
    package func waitUntilIdle() async {
        guard draining else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func enqueue(_ step: Step, fallback: (@MainActor (String) -> Void)?) {
        queue.append((step, fallback))
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }

    private func divert(
        _ text: String,
        after failure: AgentPromptDelivery,
        fallback: (@MainActor (String) -> Void)?
    ) {
        if failure == .keepInHistory {
            kept(text)
        } else {
            (fallback ?? self.fallback)(text)
        }
    }

    private func drain() async {
        while let next = queue.first {
            var unlanded: [String] = []
            var outcome: AgentPromptDelivery
            switch next.step {
            case .call(let call):
                outcome = await route.deliver(call)
                if outcome != .delivered {
                    // Appends accepted before this one may not have landed
                    // either: they go first, where the route says.
                    let settlement = await route.settle()
                    unlanded = settlement.unlanded
                    if !unlanded.isEmpty, settlement.outcome == .keepInHistory { outcome = .keepInHistory }
                }
            case .settle:
                let settlement = await route.settle()
                unlanded = settlement.unlanded
                outcome = unlanded.isEmpty ? .delivered : settlement.outcome
            }
            if outcome == .delivered {
                queue.removeFirst()
                continue
            }
            failure = outcome
            var pending = queue
            queue.removeAll()
            if case .settle = next.step { pending.removeFirst() }
            let refused = unlanded.map { ($0, Optional<@MainActor (String) -> Void>.none) }
                + pending.compactMap { entry -> (String, (@MainActor (String) -> Void)?)? in
                    if case .call(.append(let text)) = entry.step { return (text, entry.fallback) }
                    return nil
                }
            let droppedSubmits = pending.filter { if case .call(.submit) = $0.step { true } else { false } }.count
            let destination = outcome == .keepInHistory ? "stay in History" : "go by keystrokes"
            Log.backends.notice(
                "\(self.route.name, privacy: .public): route failed; \(refused.count, privacy: .public) appends \(destination, privacy: .public), \(droppedSubmits, privacy: .public) submits dropped"
            )
            for (text, callFallback) in refused { divert(text, after: outcome, fallback: callFallback) }
        }
        draining = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
