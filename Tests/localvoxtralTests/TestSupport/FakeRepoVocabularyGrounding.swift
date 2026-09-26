import ClaudeContextWire
import Foundation
@testable import localvoxtral

/// Answers the repository-vocabulary question from memory and reports the
/// git root the test names, so a commit exercises the setting and endpoint
/// gates without AX or a git subprocess. Consulted only after those gates
/// pass, so "off" and "remote" tests still prove the no-op paths.
@MainActor
final class FakeRepoVocabularyGrounding: RepoVocabularyGrounding {
    typealias Answer = @MainActor (String) -> RepoVocabularyMatcher.GroundingOutcome?

    private let answer: Answer
    /// The git root reported to the commit; nil means "ran, no repository",
    /// the same as the live path — never "did not run".
    var root: String?
    private(set) var transcripts: [String] = []
    /// The joined workspace each call was handed, nil where there was none.
    private(set) var joinedWorkspaces: [String?] = []
    var callCount: Int { transcripts.count }

    init(root: String? = nil, _ answer: @escaping Answer) {
        self.root = root
        self.answer = answer
    }

    convenience init(outcome: RepoVocabularyMatcher.GroundingOutcome?, root: String? = nil) {
        self.init(root: root) { _ in outcome }
    }

    func grounding(
        endpointURL _: URL,
        transcript: String,
        joinedWorkspace: LocalWorkspacePath?,
        repositoryRoot: RepoVocabularyRootBox?
    ) async -> RepoVocabularyMatcher.GroundingOutcome? {
        transcripts.append(transcript)
        joinedWorkspaces.append(joinedWorkspace?.path)
        repositoryRoot?.report(root)
        return answer(transcript)
    }
}
