import Foundation
import localvoxtralCore
import Synchronization

/// `gh` for the Inbox: `/w/reach` is `o/reach`, nothing else resolves, and
/// every issue list and issue created is recorded.
package final class FakeQuickCaptureGitHub: QuickCaptureGitHub, @unchecked Sendable {
    package let created = Mutex<[[String]]>([])
    package var createResult: Result<String, QuickCaptureFiling.Failure> = .success("https://github.com/o/reach/issues/9")

    package init() {}

    package func repository(ofCheckout path: String) async -> String? { path == "/w/reach" ? "o/reach" : nil }
    package let issuesListed = Mutex<[String?]>([])

    package func openIssues(ofCheckout path: String, repository: String?) async -> [QuickCaptureDraft.OpenIssue]? {
        issuesListed.withLock { $0.append(repository) }
        return []
    }
    package func repositoryFacts(_ repository: String) async -> GitHubRepositoryFacts? { nil }
    package func createIssue(repository: String, title: String, body: String) async -> Result<String, QuickCaptureFiling.Failure> {
        created.withLock { $0.append([repository, title, body]) }
        return createResult
    }
}

/// A router's classifier that always gives `answer`.
package final class FixedQuickCaptureClassifier: QuickCaptureClassifying, @unchecked Sendable {
    let answer: [String: Double]
    package init(_ answer: [String: Double]) { self.answer = answer }
    package var kind: QuickCaptureRoute.Classifier { .jev }
    package func classify(capture: String, options: [QuickCaptureOption]) async throws -> [String: Double] { answer }
}

/// Drafts "Dark mode", then each title in `nextTitles` in turn, and records
/// every invocation's arguments, where the capture text rides.
package final class FakeQuickCaptureDraftRunner: QuickCaptureDraftRunning, @unchecked Sendable {
    package let runs = Mutex(0)
    package let arguments = Mutex<[[String]]>([])
    package let nextTitles = Mutex<[String]>([])

    package init() {}

    package func run(_ invocation: ProjectTermProposal.Invocation, openIssues: [Int]) async -> QuickCaptureDraft.Outcome {
        runs.withLock { $0 += 1 }
        arguments.withLock { $0.append(invocation.arguments) }
        let title = nextTitles.withLock { $0.isEmpty ? "Dark mode" : $0.removeFirst() }
        return .draft(.init(title: title, body: "## Scope\nAll pages.", relation: .none, issue: nil), usage: nil)
    }
}

package enum QuickCaptureFixture {
    package static let projects = [
        QuickCaptureProject(key: "/w/reach", name: "reach", summary: nil, terms: [], userLine: nil),
        QuickCaptureProject(key: "remote:website", name: "website", summary: nil, terms: [], userLine: nil),
    ]

    /// An Inbox that routes by `answer` and drafts with `runner`. A checkout
    /// is any `/w/` path or a real directory.
    @MainActor
    package static func model(
        fileURL: URL?,
        answer: [String: Double],
        github: any QuickCaptureGitHub,
        runner: FakeQuickCaptureDraftRunner,
        projects: [QuickCaptureProject] = projects,
        remote: (@Sendable (String, QuickCaptureProject) async -> QuickCaptureDraft.Outcome)? = nil
    ) -> QuickCaptureInboxModel {
        return QuickCaptureInboxModel(
            fileURL: fileURL,
            makeRouter: { QuickCaptureRouter(classifiers: [FixedQuickCaptureClassifier(answer)]) },
            projects: { projects },
            agents: { [.claude] },
            drafter: {
                QuickCaptureDrafter(
                    runner: runner,
                    openIssues: { await github.openIssues(ofCheckout: $0, repository: $1) },
                    trackedFiles: { _ in [] },
                    directoryExists: { $0.hasPrefix("/w/") || FileManager.default.fileExists(atPath: $0) },
                    remote: remote
                )
            },
            github: github,
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
    }
}
