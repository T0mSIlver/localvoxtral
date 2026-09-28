import Foundation
import localvoxtralCore
import Synchronization

/// `gh` for the Inbox: `/w/reach` is `o/reach`, nothing else resolves, and
/// every issue list and issue created is recorded.
package final class FakeQuickCaptureGitHub: QuickCaptureGitHub, @unchecked Sendable {
    package let created = Mutex<[[String]]>([])
    package var createResult: Result<String, QuickCaptureFiling.Failure> = .success("https://github.com/o/reach/issues/9")
    /// Set, `gh issue create` waits on it before it answers.
    package var createGate: ManualSleeper?

    package init() {}

    package func repository(ofCheckout path: String) async -> String? { path == "/w/reach" ? "o/reach" : nil }
    package let issuesListed = Mutex<[String?]>([])

    package func openIssues(ofCheckout path: String, repository: String?) async -> [QuickCaptureDraft.OpenIssue]? {
        issuesListed.withLock { $0.append(repository) }
        return []
    }
    package func repositoryFacts(_ repository: String) async -> GitHubRepositoryFacts? { nil }
    package func createIssue(repository: String, title: String, body: String) async -> Result<String, QuickCaptureFiling.Failure> {
        if let createGate { await createGate.sleep(0) }
        created.withLock { $0.append([repository, title, body]) }
        return createResult
    }

    /// Every `gh issue comment`: repository, issue number, body.
    package let comments = Mutex<[[String]]>([])
    package var commentResult: Result<String, QuickCaptureFiling.Failure> =
        .success("https://github.com/o/reach/issues/7#issuecomment-1")

    package func commentOnIssue(repository: String, issue: Int, body: String) async -> Result<String, QuickCaptureFiling.Failure> {
        comments.withLock { $0.append([repository, String(issue), body]) }
        return commentResult
    }
}

/// A router's classifier that always gives `answer`.
package final class FixedQuickCaptureClassifier: QuickCaptureClassifying, @unchecked Sendable {
    let answer: [String: Double]
    package init(_ answer: [String: Double]) { self.answer = answer }
    package var kind: QuickCaptureRoute.Classifier { .jev }
    package func classify(capture: String, options: [QuickCaptureOption]) async throws -> [String: Double] { answer }
}

/// A router's classifier that gives `answers` in turn (the last one
/// repeats), and records the capture and options of each call.
package final class ScriptedQuickCaptureClassifier: QuickCaptureClassifying, @unchecked Sendable {
    private let answers: Mutex<[[String: Double]]>
    package let calls = Mutex<[[QuickCaptureOption]]>([])
    package let captures = Mutex<[String]>([])
    package init(_ answers: [[String: Double]]) { self.answers = Mutex(answers) }
    package var kind: QuickCaptureRoute.Classifier { .chatModel }
    package func classify(capture: String, options: [QuickCaptureOption]) async throws -> [String: Double] {
        calls.withLock { $0.append(options) }
        captures.withLock { $0.append(capture) }
        return answers.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
    }
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

/// An agent run that answers `answers` in turn (the last one repeats),
/// records each prompt, and, when `gate` is set, waits on it first.
package final class FakeQuickCaptureCheckRunner: QuickCaptureDraftRunning, @unchecked Sendable {
    package let gate: ManualSleeper?
    package let answers: Mutex<[QuickCaptureDraft.Outcome]>
    package let prompts = Mutex<[String]>([])

    package init(_ answers: [QuickCaptureDraft.Outcome], gated: Bool = false) {
        self.answers = Mutex(answers)
        gate = gated ? ManualSleeper() : nil
    }

    package var runs: Int { prompts.withLock { $0.count } }

    package func run(_ invocation: ProjectTermProposal.Invocation, openIssues: [Int]) async -> QuickCaptureDraft.Outcome {
        prompts.withLock { $0.append(invocation.arguments.count > 1 ? invocation.arguments[1] : "") }
        if let gate { await gate.sleep(0) }
        return answers.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
    }
}

/// The polishing model's first draft (#918): `answers` in turn (the last
/// one repeats), with each context it was given; when `gate` is set, it
/// waits on it before answering.
package final class FakeQuickCaptureFirstDrafter: QuickCaptureFirstDrafting, @unchecked Sendable {
    package let gate: ManualSleeper?
    package let answers: Mutex<[QuickCaptureDraft.Outcome]>
    package let contexts = Mutex<[QuickCaptureContext]>([])

    package init(_ answers: [QuickCaptureDraft.Outcome], gated: Bool = false) {
        self.answers = Mutex(answers)
        gate = gated ? ManualSleeper() : nil
    }

    package func firstDraft(capture: String, projectName: String, context: QuickCaptureContext) async -> QuickCaptureDraft.Outcome {
        contexts.withLock { $0.append(context) }
        if let gate { await gate.sleep(0) }
        return answers.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
    }
}

/// The capture's polish (#970): `answer` maps the words it gets to the
/// words it returns, else nil, as a failed request does. Records each call;
/// when `gate` is set, every call waits on it before answering, and a call
/// whose index is in `callGates` waits on its own gate.
@MainActor
package final class FakeQuickCapturePolisher: QuickCapturePolishing {
    package let answer: (String) -> String?
    package let gate: ManualSleeper?
    package let callGates: [Int: ManualSleeper]
    package private(set) var calls: [(text: String, vocabulary: [String])] = []

    package init(gated: Bool = false, gatedCalls: [Int] = [], answer: @escaping (String) -> String?) {
        self.answer = answer
        gate = gated ? ManualSleeper() : nil
        callGates = Dictionary(uniqueKeysWithValues: gatedCalls.map { ($0, ManualSleeper()) })
    }

    package func polish(_ text: String, vocabulary: [String]) async -> QuickCapturePolish? {
        let index = calls.count
        calls.append((text, vocabulary))
        if let gate { await gate.sleep(0) }
        if let callGate = callGates[index] { await callGate.sleep(0) }
        return answer(text).map { QuickCapturePolish(text: $0, durationSeconds: 1.5) }
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
        runner: any QuickCaptureDraftRunning,
        projects: [QuickCaptureProject] = projects,
        remote: QuickCaptureDrafter.Remote? = nil,
        classifier: (any QuickCaptureClassifying)? = nil,
        polisher: (any QuickCapturePolishing)? = nil,
        polishVocabulary: @escaping @MainActor ([QuickCaptureProject]) -> [String] = { _ in [] },
        now: @escaping @MainActor () -> Date = { Date(timeIntervalSince1970: 1_000_000) }
    ) -> QuickCaptureInboxModel {
        let classifier = classifier ?? FixedQuickCaptureClassifier(answer)
        return QuickCaptureInboxModel(
            fileURL: fileURL,
            makeRouter: { QuickCaptureRouter(classifiers: [classifier]) },
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
            polisher: { polisher },
            polishVocabulary: polishVocabulary,
            now: now
        )
    }
}
