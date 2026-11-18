import Foundation
import Observation

/// One "Check key" row: the verdict and the key it belongs to. Settings and the
/// onboarding wizard each own one, so a verdict is never shown next to a key
/// it did not check (#1626, #1873).
@MainActor
@Observable
final class MistralAPIKeyCheck {
    private var checkedKey: String?
    private var lastState: MistralAPIKeyCheckState = .idle
    /// Bumped by every check and every `invalidate`, so only the latest
    /// check publishes.
    @ObservationIgnored private var generation = 0
    /// The in-flight check. Kept awaitable so the unit suite observes the
    /// result without polling a clock.
    @ObservationIgnored private(set) var task: Task<Void, Never>?

    /// The verdict for `key`: idle when the last check was of another key.
    func state(for key: String) -> MistralAPIKeyCheckState {
        key == checkedKey ? lastState : .idle
    }

    func start(
        key: String,
        verify: @escaping @MainActor (String) async -> MistralAPIKeyVerification
    ) {
        guard !state(for: key).isChecking else { return }
        generation += 1
        let generation = generation
        checkedKey = key
        lastState = .checking
        task = Task { @MainActor [weak self] in
            let verification = await verify(key)
            guard let self, self.generation == generation else { return }
            self.lastState = .finished(verification)
        }
    }

    /// Forget the verdict and drop a check still running, for an owner that
    /// sees every edit of its key: the same key typed again then gets a fresh
    /// check instead of the older one's answer.
    func invalidate() {
        generation += 1
        checkedKey = nil
        lastState = .idle
    }
}
