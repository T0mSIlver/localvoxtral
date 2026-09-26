import ClaudeContextWire
import Foundation

/// A Sendable snapshot of a plugin-action failure.
///
/// `any Error` is an existential and is NOT Sendable, so it cannot be returned
/// out of the detached task the action runs in — Swift 6 rejects it, correctly.
/// Everything the pane needs is captured here at the throw site instead: the
/// typed case when it is one of ours, and a description otherwise.
public struct ClaudePluginActionFailure: Sendable, Equatable {
    public var serviceError: ClaudePluginInstallService.ServiceError?
    public var describedError: String

    public init(_ error: any Error) {
        serviceError = error as? ClaudePluginInstallService.ServiceError
        describedError = String(describing: error)
    }
}

public struct ClaudeEnrollmentActionFailure: Sendable, Equatable {
    public var serviceError: ClaudeRemoteEnrollmentService.ServiceError?
    public var describedError: String

    public init(_ error: any Error) {
        serviceError = error as? ClaudeRemoteEnrollmentService.ServiceError
        describedError = String(describing: error)
    }
}

/// The verification counterpart of `ClaudeEnrollmentActionAttempt`: verdicts,
/// or the reason there are none. Same shape for the same reason — `any Error`
/// is not Sendable and cannot come back out of the detached task.
public struct ClaudeVerificationAttempt: Sendable, Equatable {
    public var checks: [ClaudeRemoteEnrollmentService.VerificationCheck]
    public var failure: ClaudeEnrollmentActionFailure?

    public init(
        checks: [ClaudeRemoteEnrollmentService.VerificationCheck],
        failure: ClaudeEnrollmentActionFailure?
    ) {
        self.checks = checks
        self.failure = failure
    }
}

public struct ClaudeEnrollmentActionAttempt: Sendable, Equatable {
    public var steps: [ClaudeRemoteEnrollmentService.ExecutionStep]
    public var failure: ClaudeEnrollmentActionFailure?

    public init(
        steps: [ClaudeRemoteEnrollmentService.ExecutionStep],
        failure: ClaudeEnrollmentActionFailure?
    ) {
        self.steps = steps
        self.failure = failure
    }
}
