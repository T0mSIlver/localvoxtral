import Foundation
@testable import localvoxtral

/// Plays the hold-delay timer of the modifier-key gestures: it keeps each
/// scheduled callback until the test fires it.
@MainActor
final class HoldSchedulerProbe {
    private var delays: [Double] = []
    private var callbacks: [@MainActor @Sendable () -> Void] = []

    var scheduler: ModifierOnlyHotKeyManager.HoldScheduler {
        { [weak self] delay, fire in
            self?.delays.append(delay)
            self?.callbacks.append(fire)
        }
    }

    var scheduledDelays: [Double] {
        delays
    }

    func fire(at index: Int) {
        let callback = callbacks.remove(at: index)
        callback()
    }

    func fireAll() {
        let callbacks = callbacks
        self.callbacks.removeAll()
        callbacks.forEach { $0() }
    }
}
