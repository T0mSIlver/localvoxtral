import Foundation
import Observation
@testable import localvoxtral

/// Records every call to the managed backend manager and starts nothing.
/// `@Observable` so the onboarding driver's `withObservationTracking` mirror
/// fires on status mutation; the Engines pane tests read the call counts.
@MainActor
@Observable
final class OnboardingTestBackendManager: ManagedBackendManaging {
    struct EnsureCall: Equatable {
        var dictation: Bool
        var polishing: Bool
    }

    var speechdStatus: ManagedBackendStatus = .stopped
    var polishdStatus: ManagedBackendStatus = .stopped
    @ObservationIgnored private var statusUpdateContinuations: [UUID: AsyncStream<ManagedBackendStatusUpdate>.Continuation] = [:]
    var statusUpdates: AsyncStream<ManagedBackendStatusUpdate> {
        let id = UUID()
        let stream = AsyncStream<ManagedBackendStatusUpdate>.makeStream(of: ManagedBackendStatusUpdate.self)
        statusUpdateContinuations[id] = stream.continuation
        stream.continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.statusUpdateContinuations[id] = nil
            }
        }
        return stream.stream
    }

    @ObservationIgnored private(set) var ensureCalls: [EnsureCall] = []
    @ObservationIgnored private(set) var stopAllCallCount = 0
    @ObservationIgnored private(set) var stopDictationCallCount = 0
    @ObservationIgnored private(set) var stopPolishingCallCount = 0
    @ObservationIgnored private(set) var pausedDownloadSpecIDs: [String] = []
    @ObservationIgnored private(set) var cancelledDownloadSpecIDs: [String] = []
    @ObservationIgnored private var ensureContinuation: CheckedContinuation<Void, Never>?

    func ensureReady(dictation: Bool, polishing: Bool) async throws {
        ensureCalls.append(EnsureCall(dictation: dictation, polishing: polishing))
        ensureContinuation?.resume()
        ensureContinuation = nil
    }

    func stopAll() async { stopAllCallCount += 1 }
    func stopDictation() async { stopDictationCallCount += 1 }
    func stopPolishing() async { stopPolishingCallCount += 1 }
    func pauseModelDownload(for spec: ManagedBackendSpec) async {
        pausedDownloadSpecIDs.append(spec.id)
    }
    func cancelModelDownload(for spec: ManagedBackendSpec) async {
        cancelledDownloadSpecIDs.append(spec.id)
    }
    func recentOutput(for spec: ManagedBackendSpec) -> [String] { [] }

    /// Suspends until `ensureReady` has been invoked at least once.
    func waitForEnsure() async {
        if !ensureCalls.isEmpty { return }
        await withCheckedContinuation { continuation in
            ensureContinuation = continuation
        }
    }
}
