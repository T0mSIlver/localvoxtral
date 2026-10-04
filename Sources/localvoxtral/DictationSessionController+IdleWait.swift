import Foundation

extension DictationSessionController {
    /// No dictation is listening or finalizing: restarting the managed
    /// speech engine now loses no words (#1759). A session still connecting
    /// has sent the engine nothing; waiting on it could mean waiting out the
    /// old model's download.
    var isDictationIdle: Bool {
        !isDictating && !isFinalizingStop
    }

    /// Returns once `isDictationIdle` holds, or the calling task is cancelled.
    func waitUntilDictationIsIdle() async {
        while !isDictationIdle, !Task.isCancelled {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if isDictationIdle || Task.isCancelled {
                        continuation.resume()
                    } else {
                        idleWaiters[id] = continuation
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.idleWaiters.removeValue(forKey: id)?.resume()
                }
            }
        }
    }

    func resumeIdleWaitersIfIdle() {
        guard isDictationIdle, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters.values
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
