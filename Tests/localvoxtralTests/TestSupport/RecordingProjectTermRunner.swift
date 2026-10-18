import Foundation
import Synchronization
@testable import localvoxtral

/// A project-term proposal runner that only counts its runs and answers one
/// term. Wiring tests use it to see whether a commit asked at all.
final class RecordingProjectTermRunner: ProjectTermProposalRunning, @unchecked Sendable {
    private let invocations = Mutex<[ProjectTermProposal.Invocation]>([])

    var all: [ProjectTermProposal.Invocation] { invocations.withLock { $0 } }

    func run(_ invocation: ProjectTermProposal.Invocation) async -> ProjectTermProposal.Outcome {
        invocations.withLock { $0.append(invocation) }
        return .terms(["inkwell"])
    }
}
