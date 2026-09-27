import Foundation
import Synchronization

/// When a dictation's socket opened, its microphone started and its first
/// buffer arrived, counted from the start press (#527). Speech before the
/// first buffer is never captured, so this line is how the field measures
/// what a start costs. The first buffer lands on the capture queue and the
/// rest on the main actor, in either order; the line is reported once, when
/// the socket open and the first buffer are both known.
package final class CaptureTimeline: @unchecked Sendable {
    private struct State {
        var socketOpen: Date?
        var micStarted: Date?
        var firstBuffer: Date?
        var reported = false
    }

    private let pressedAt: Date
    private let now: @Sendable () -> Date
    private let report: @Sendable (String) -> Void
    private let state = Mutex(State())

    package init(
        pressedAt: Date,
        now: @escaping @Sendable () -> Date,
        report: @escaping @Sendable (String) -> Void = { line in
            Log.dictation.notice("\(line, privacy: .public)")
        }
    ) {
        self.pressedAt = pressedAt
        self.now = now
        self.report = report
    }

    package func markMicStarted() { mark(\.micStarted) }
    package func markSocketOpen() { mark(\.socketOpen) }
    package func markFirstBuffer() { mark(\.firstBuffer) }

    private func mark(_ event: WritableKeyPath<State, Date?>) {
        let at = now()
        let line = state.withLock { state -> String? in
            guard state[keyPath: event] == nil else { return nil }
            state[keyPath: event] = at
            guard !state.reported, state.socketOpen != nil, state.firstBuffer != nil else {
                return nil
            }
            state.reported = true
            return "capture timeline: socket open \(offset(state.socketOpen)), "
                + "mic started \(offset(state.micStarted)), "
                + "first buffer \(offset(state.firstBuffer)) after the start"
        }
        if let line { report(line) }
    }

    private func offset(_ date: Date?) -> String {
        guard let date else { return "never" }
        return "+\(Int((date.timeIntervalSince(pressedAt) * 1000).rounded())) ms"
    }
}
