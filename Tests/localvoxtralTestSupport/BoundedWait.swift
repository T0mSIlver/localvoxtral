import Foundation
import Synchronization

/// A wait that ends once: when the awaited event resolves it, or when
/// `failAfter` seconds of wall time pass first. The event resumes the waiting
/// task directly, in the caller's isolation, so a passing test runs in the
/// same order it would with a bare continuation. The wall-time bound only
/// ends a wait that was going to hang: it is never what a passing test waits
/// on.
package final class BoundedWait: Sendable {
    private enum State {
        case idle
        case suspended(CheckedContinuation<Bool, Never>)
        case resolved(Bool)
    }

    private let state = Mutex(State.idle)

    /// Ends the wait with `true`. Only the first resolution counts.
    package init() {}

    package func resolve() { finish(true) }

    /// Returns `true` if `resolve()` came first, `false` if the bound did.
    package func value(
        failAfter: TimeInterval,
        isolation: isolated (any Actor)? = #isolation
    ) async -> Bool {
        let bound = Task { [self] in
            try? await Task.sleep(for: .seconds(failAfter))
            if !Task.isCancelled { finish(false) }
        }
        defer { bound.cancel() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resolved = state.withLock { state -> Bool? in
                if case .resolved(let value) = state { return value }
                state = .suspended(continuation)
                return nil
            }
            if let resolved { continuation.resume(returning: resolved) }
        }
    }

    private func finish(_ value: Bool) {
        let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            switch state {
            case .idle:
                state = .resolved(value)
                return nil
            case .suspended(let continuation):
                state = .resolved(value)
                return continuation
            case .resolved:
                return nil
            }
        }
        continuation?.resume(returning: value)
    }
}
