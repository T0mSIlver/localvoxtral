import Observation
@testable import localvoxtral

/// Runs `trigger`, then returns once `value` has been written: how a test
/// waits for what another main-actor task does in response, with no seam and
/// no clock. Only wait for a write the code under test is certain to make;
/// nothing else resumes this.
@MainActor
func awaitNextWrite<Value>(
    of value: @escaping @MainActor () -> Value,
    after trigger: () -> Void
) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        withObservationTracking {
            _ = value()
        } onChange: {
            continuation.resume()
        }
        trigger()
    }
}
