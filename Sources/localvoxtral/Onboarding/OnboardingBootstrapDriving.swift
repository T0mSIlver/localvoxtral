import Foundation

/// The managed downloads the onboarding wizard can kick off. Each maps to one
/// managed backend + its model weights.
enum OnboardingItemID: String, CaseIterable, Identifiable, Sendable {
    /// Bundled speechd + the Voxtral realtime dictation model.
    case dictation
    /// The bundled polishing engine's LLM model.
    case polishing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation:
            return "Dictation engine"
        case .polishing:
            return "Polishing model"
        }
    }

    /// One short line describing what gets downloaded.
    var detail: String {
        switch self {
        case .dictation:
            return "the bundled dictation engine + Voxtral model"
        case .polishing:
            return "the polishing LLM (bundled engine)"
        }
    }
}

/// UI-facing state of a single onboarding download item. Deliberately decoupled
/// from `ManagedBackendStatus` so the wizard compiles against today's backend
/// API and the mapping (see `OnboardingItemState.init(managedStatus:)`) is the
/// single place that absorbs backend-status changes (e.g. PR #62).
enum OnboardingItemState: Equatable, Sendable {
    case pending
    /// In progress. `fraction` drives a determinate bar when non-nil, otherwise
    /// the UI shows an indeterminate spinner alongside `detail`.
    case working(detail: String, fraction: Double?)
    case ready
    case failed(summary: String)
}

/// Drives the wizard's Downloads page. The wizard depends ONLY on this small
/// surface, so the live implementation can evolve with the backend API without
/// the wizard changing. Two implementations ship: `LiveOnboardingBootstrapDriver`
/// (wraps `BackendManager`) and `PreviewOnboardingBootstrapDriver` (scripted, for
/// tests and previews).
@MainActor
protocol OnboardingBootstrapDriving: AnyObject {
    /// Observable per-item state. Empty until `start` is called.
    var itemStates: [OnboardingItemID: OnboardingItemState] { get }

    /// Kick off model download for the requested items. Nothing runs
    /// until this is called (preserves the app's lazy-bootstrap invariant).
    func start(dictation: Bool, polishing: Bool)

    /// Cancel any in-flight work. Item states are left as last observed.
    func cancel()
}

extension OnboardingItemState {
    /// Map a live `ManagedBackendStatus` into the wizard's item state. This is
    /// the single seam that absorbs backend-status shape changes.
    init(managedStatus status: ManagedBackendStatus) {
        switch status {
        case .stopped:
            self = .pending
        case .preparingModel(let progress):
            self = .working(
                detail: Self.modelDownloadDetail(progress),
                fraction: progress.fraction
            )
        case .starting:
            // Managed servers download the model weights internally before
            // /health responds, so "starting" can be a long, opaque wait.
            self = .working(detail: "Loading the model…", fraction: nil)
        case .ready:
            self = .ready
        case .failed(let summary, _):
            self = .failed(summary: summary)
        }
    }

    private static func modelDownloadDetail(_ progress: ModelDownloadProgress) -> String {
        guard let totalBytes = progress.totalBytes, totalBytes > 0 else {
            // Bytes moving but no total (CDN sent no length): show movement
            // rather than pretending we are still checking.
            if progress.downloadedBytes > 0 {
                let megabytes = progress.downloadedBytes / 1_048_576
                return "Downloading model - \(megabytes) MB"
            }
            return "Checking model..."
        }
        return "Downloading model \(Int(((progress.fraction ?? 0) * 100).rounded()))%"
    }
}
