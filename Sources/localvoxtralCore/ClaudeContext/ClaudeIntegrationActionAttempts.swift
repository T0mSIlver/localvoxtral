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
    /// What failed, without the CLI's output, which can hold anything the
    /// user's Claude Code prints: the part safe to log public (#936).
    public var publicLogDescription: String

    public init(_ error: any Error) {
        serviceError = error as? ClaudePluginInstallService.ServiceError
        describedError = String(describing: error)
        publicLogDescription = Self.publicLogDescription(of: error)
    }

    static func publicLogDescription(of error: any Error) -> String {
        guard let serviceError = error as? ClaudePluginInstallService.ServiceError else {
            // A Swift error bridges to its type's name and case index.
            let bridged = error as NSError
            return "\(bridged.domain) error \(bridged.code)"
        }
        switch serviceError {
        case .claudeCLINotFound:
            return "claude CLI not found"
        case .marketplaceUnavailable:
            return "bundled marketplace missing"
        case .commandFailed(let action, let exitCode, let message):
            return "claude plugin \(action) exited \(exitCode) with \(message.count) characters of output"
        case .commandTimedOut(let action, _, let seconds):
            let command = action.map { String(describing: $0) } ?? "command"
            return "claude plugin \(command) timed out after \(Int(seconds)) s"
        case .outputTooLarge(_, let capBytes):
            return "claude plugin output passed \(capBytes / 1024) KB"
        }
    }
}

public struct ClaudeEnrollmentActionFailure: Sendable, Equatable {
    public var serviceError: ClaudeRemoteEnrollmentService.ServiceError?
    public var describedError: String
    /// What failed, without the command or its output, which can hold ssh
    /// and file-system text: the part safe to log public (#983).
    public var publicLogDescription: String

    public init(_ error: any Error) {
        serviceError = error as? ClaudeRemoteEnrollmentService.ServiceError
        describedError = String(describing: error)
        publicLogDescription = Self.publicLogDescription(of: error)
    }

    static func publicLogDescription(of error: any Error) -> String {
        guard let serviceError = error as? ClaudeRemoteEnrollmentService.ServiceError else {
            // A Swift error bridges to its type's name and case index.
            let bridged = error as NSError
            return "\(bridged.domain) error \(bridged.code)"
        }
        switch serviceError {
        case .executionNotConfigured:
            return "execution not configured"
        case .sshConfigEditingNotConfigured:
            return "ssh config editing not configured"
        case .invalidSSHConfigEncoding:
            return "ssh config is not UTF-8"
        case .sshConfigIsSymlink:
            return "ssh config is a symlink"
        case .sshDirectoryNotTrusted:
            return "~/.ssh not trusted"
        case .sshConfigBlockDamaged:
            return "ssh config block markers unpaired"
        case .commandFailed(let step, _, let exitCode, let message):
            return "step \(step) exited \(exitCode) with \(message.count) characters of output"
        case .commandTimedOut(let step, _, let seconds, _):
            return "step \(step) timed out after \(Int(seconds)) s"
        case .runnerFailed(let step, _, let message):
            return "step \(step) runner failed with \(message.count) characters of output"
        case .invalidHostAlias:
            return "invalid host alias"
        case .localHerdrPanelConfigAlreadyCustomized:
            return "local herdr config already customized"
        case .localHerdrConfigEditingNotConfigured:
            return "local herdr config editing not configured"
        case .localHerdrConfigUnreadable:
            return "local herdr config unreadable"
        }
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
