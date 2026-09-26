import Foundation
@testable import localvoxtral

/// A login item that never touches `~/Library/LaunchAgents`: the state it
/// reports and what `register`/`unregister` do are the test's to set.
@MainActor
final class FakeLoginItemRegistrar: LoginItemRegistering {
    var state: LoginItemState
    /// What `register()` lands on when it does not throw — the system, not
    /// the caller, decides whether approval is still needed.
    var stateAfterRegister: LoginItemState = .enabled
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(state: LoginItemState) {
        self.state = state
    }

    func currentState() -> LoginItemState { state }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        state = stateAfterRegister
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        state = .disabled
    }
}
