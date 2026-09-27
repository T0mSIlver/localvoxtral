import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Takes the hook sockets back when the copy of the app that held them exits
/// (#655).
///
/// Every hook reaches the app through two sockets: the local broker's and the
/// remote listener's 127.0.0.1 port. A second copy (a `try-pr.sh` build next to
/// the installed one, a CI launch smoke on the owner's Mac) loses both binds to
/// the copy already running, and must: taking a live copy's socket is how hooks
/// used to vanish silently. But the loser used to stay deaf after the winner
/// quit. Measured 2026-09-27: the owner quit the older copy, the survivor kept
/// dictating, and every join abstained until a relaunch, because no hook
/// reached it.
///
/// So a copy that lost a bind to another copy retries it each time another
/// copy exits. It never retries while they all run: the broker's liveness
/// check connects to the owner's socket, and a timer would make it log a
/// connection every few seconds. A retry that still finds the socket held
/// (the copy that exited was not the owner) waits for the next exit.
@MainActor
public final class ClaudeHookSocketTakeover {
    public enum Outcome: Equatable, Sendable {
        case bound
        /// Another live copy holds the socket; retry when a copy exits.
        case heldByAnotherCopy
        /// Any other failure. Waiting for a copy to exit would not fix it;
        /// the step's own error line and Settings say what did.
        case failed

        /// How a start error of the broker or of the listener reads here.
        /// Only the two "a live process holds it" answers wait.
        public init(startError error: any Error) {
            #if canImport(Darwin) || canImport(Glibc)
            if case .socketOwnedByLiveInstance? = error as? ClaudeContextBroker.StartFailure {
                self = .heldByAnotherCopy
                return
            }
            if case .bindFailed(let code)? = error as? ClaudeRemoteContextListener.StartFailure,
               code == EADDRINUSE {
                self = .heldByAnotherCopy
                return
            }
            #endif
            self = .failed
        }
    }

    public struct Step {
        public let name: String
        public let attempt: @MainActor () -> Outcome

        public init(name: String, attempt: @escaping @MainActor () -> Outcome) {
            self.name = name
            self.attempt = attempt
        }
    }

    /// Arms `onExit` once when `pid` exits, and cancels it when the returned
    /// object is released.
    public typealias ExitWatch = @MainActor (
        _ pid: Int32, _ onExit: @escaping @MainActor @Sendable () -> Void
    ) -> AnyObject

    private var pending: [Step]
    private let otherCopies: @MainActor () -> [Int32]
    private let watchExit: ExitWatch
    private var watches: [AnyObject] = []
    /// Bumped on every retry, so a watch armed before it cannot fire again.
    private var generation = 0

    /// - Parameters:
    ///   - steps: the binds that lost to another copy at launch, in the order
    ///     launch ran them.
    ///   - otherCopies: pids of the other running copies of the app.
    public init(
        steps: [Step],
        otherCopies: @escaping @MainActor () -> [Int32],
        watchExit: @escaping ExitWatch
    ) {
        self.pending = steps
        self.otherCopies = otherCopies
        self.watchExit = watchExit
    }

    /// True while a step waits for another copy to exit.
    public var isWaiting: Bool { !pending.isEmpty }

    /// Names of the steps still waiting.
    public var waitingSteps: [String] { pending.map(\.name) }

    /// Watch the other copies. Call once, after launch ran the steps and
    /// they lost.
    public func begin() {
        armWatches()
    }

    private func retry() {
        generation += 1
        watches.removeAll()
        pending = pending.filter { step in
            switch step.attempt() {
            case .bound:
                Log.claudeContext.notice(
                    "Claude hook socket takeover: \(step.name, privacy: .public) bound after another copy exited"
                )
                return false
            case .heldByAnotherCopy:
                return true
            case .failed:
                Log.claudeContext.error(
                    "Claude hook socket takeover: \(step.name, privacy: .public) failed after another copy exited; giving up"
                )
                return false
            }
        }
        armWatches()
    }

    private func armWatches() {
        guard isWaiting else { return }
        let pids = otherCopies()
        let names = waitingSteps.joined(separator: ", ")
        guard !pids.isEmpty else {
            // A socket held by something that is not a copy of the app: no
            // exit to wait for. Settings' Retry is the way back.
            Log.claudeContext.error(
                "Claude hook socket takeover: \(names, privacy: .public) held, but no other copy of the app runs; not waiting"
            )
            return
        }
        Log.claudeContext.notice(
            "Claude hook socket takeover: \(names, privacy: .public) held by another copy; retrying when one of \(pids.count, privacy: .public) exits"
        )
        // One exit is enough to retry: the retry re-reads the copies and
        // drops these watches.
        let armed = generation
        watches = pids.map { pid in
            watchExit(pid) { [weak self] in
                guard let self, self.generation == armed else { return }
                self.retry()
            }
        }
    }
}

#if canImport(Darwin)
/// Calls `onExit` once, on the main actor, when `pid` exits. Any process of
/// this user: a kqueue process source, not `waitpid`, which is for children
/// only.
public final class ProcessExitWatch: @unchecked Sendable {
    private let source: DispatchSourceProcess

    public init(pid: pid_t, onExit: @escaping @MainActor @Sendable () -> Void) {
        let fired = Mutex(false)
        let fire: @Sendable () -> Void = {
            guard fired.withLock({ done in defer { done = true }; return !done }) else { return }
            Task { @MainActor in onExit() }
        }
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler(handler: fire)
        // A process that exited before the kevent was installed never fires
        // it. `resume` only schedules the install, so check once it ran.
        source.setRegistrationHandler {
            if kill(pid, 0) != 0, errno == ESRCH {
                fire()
            }
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
#endif
