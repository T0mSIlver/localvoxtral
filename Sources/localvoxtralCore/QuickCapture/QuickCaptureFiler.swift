import Foundation

/// The only code that files anything (#732): `gh issue create`, run when the
/// user presses File, as the user, with the title and body the Inbox shows.
package enum QuickCaptureFiling {
    package static func createArguments(repository: String, title: String, body: String) -> [String] {
        ["issue", "create", "--repo", repository, "--title", title, "--body", body]
    }

    /// `gh repo view --json nameWithOwner` in a checkout: its GitHub repository.
    package static let repoViewArguments = ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]

    package enum Failure: Error, Equatable, Sendable {
        case ghNotFound
        case failed(exitCode: Int32)
        case noURL
    }

    /// The issue URL `gh issue create` prints last.
    package static func issueURL(inOutput data: Data) -> String? {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("https://") && $0.contains("/issues/") }
    }
}

/// Runs `gh`. The seam the Inbox model's tests replace.
package protocol QuickCaptureGitHub: Sendable {
    /// The checkout's `owner/name`, nil when it has no GitHub remote.
    func repository(ofCheckout path: String) async -> String?
    func openIssues(ofCheckout path: String) async -> [QuickCaptureDraft.OpenIssue]?
    func createIssue(repository: String, title: String, body: String) async -> Result<String, QuickCaptureFiling.Failure>
}

package struct QuickCaptureGHClient: QuickCaptureGitHub {
    private let environment: [String: String]
    private let isExecutable: @Sendable (String) -> Bool

    package init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.environment = environment
        self.isExecutable = isExecutable
    }

    private var gh: URL? {
        QuickCaptureDrafter.ghCandidates(environment: environment).first(where: isExecutable).map(URL.init(fileURLWithPath:))
    }

    package func repository(ofCheckout path: String) async -> String? {
        guard let gh, let output = await BoundedProcess.run(
            executableURL: gh, arguments: QuickCaptureFiling.repoViewArguments, environment: environment,
            currentDirectory: path, timeoutSeconds: 20, maxBytes: 4096, label: "quick capture gh repo view"
        ), output.exitCode == 0, !output.timedOut else { return nil }
        let name = String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return QuickCaptureInbox.isRepository(name) ? name : nil
    }

    package func openIssues(ofCheckout path: String) async -> [QuickCaptureDraft.OpenIssue]? {
        await QuickCaptureDrafter.ghOpenIssues(environment: environment, isExecutable: isExecutable)(path)
    }

    package func createIssue(repository: String, title: String, body: String) async -> Result<String, QuickCaptureFiling.Failure> {
        guard let gh else { return .failure(.ghNotFound) }
        Log.backends.info("Quick capture: filing an issue in \(repository, privacy: .public)")
        guard let output = await BoundedProcess.run(
            executableURL: gh,
            arguments: QuickCaptureFiling.createArguments(repository: repository, title: title, body: body),
            environment: environment, timeoutSeconds: 60, maxBytes: 65_536, label: "quick capture gh issue create"
        ) else { return .failure(.failed(exitCode: -1)) }
        guard output.exitCode == 0, !output.timedOut else {
            Log.backends.error("Quick capture: gh issue create exited \(output.exitCode, privacy: .public)")
            return .failure(.failed(exitCode: output.exitCode))
        }
        guard let url = QuickCaptureFiling.issueURL(inOutput: output.data) else { return .failure(.noURL) }
        Log.backends.info("Quick capture: filed \(url, privacy: .public)")
        return .success(url)
    }
}
