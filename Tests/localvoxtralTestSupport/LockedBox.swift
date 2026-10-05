import Foundation

/// A value tests read and set from any thread: what a callback saw, for the
/// test body to assert on.
package final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    package init(_ value: Value) {
        stored = value
    }

    package var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    package func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    /// Changes the value in one locked step.
    package func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&stored)
        lock.unlock()
    }
}
