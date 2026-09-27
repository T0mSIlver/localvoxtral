import Foundation

/// The only code that files anything (#732): `gh issue create`, run when the
/// user presses File, as the user, with the title and body the Inbox shows.
package enum QuickCaptureFiling {
    package static func createArguments(repository: String, title: String, body: String) -> [String] {
        ["issue", "create", "--repo", repository, "--title", title, "--body", body]
    }

    /// `gh repo view --json nameWithOwner` in a checkout: its GitHub
    /// repository. Asked only when the checkout has no `origin`: with an
    /// `upstream` remote, gh answers the upstream (#919).
    package static let repoViewArguments = ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]

    /// `owner/name` of a github.com remote URL: https, ssh or scp-like
    /// (`git@github.com:owner/name`), with or without `.git`. Nil for any
    /// other host.
    package static func repository(fromRemoteURL url: String) -> String? {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: Substring
        var path: Substring
        if let scheme = url.range(of: "://") {
            guard ["https", "http", "ssh", "git"].contains(url[..<scheme.lowerBound].lowercased()) else { return nil }
            let rest = url[scheme.upperBound...]
            let authority = rest.prefix { $0 != "/" }
            path = rest.dropFirst(authority.count)
            host = (authority.split(separator: "@").last ?? "").split(separator: ":").first ?? ""
        } else {
            guard let colon = url.firstIndex(of: ":") else { return nil }
            host = url[..<colon].split(separator: "@").last ?? ""
            path = url[url.index(after: colon)...]
        }
        guard host.lowercased() == "github.com" else { return nil }
        while path.hasPrefix("/") { path = path.dropFirst() }
        while path.hasSuffix("/") { path = path.dropLast() }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        let name = String(path)
        return QuickCaptureInbox.isRepository(name) ? name : nil
    }

    /// The checkout's GitHub repository: `origin`'s, else gh's pick when it
    /// has no `origin`. Nil when `origin` is not on github.com.
    package static func repository(
        ofCheckout path: String, environment: [String: String], isExecutable: @Sendable (String) -> Bool
    ) async -> String? {
        // gh only when git says there is no origin (exit 2): after a timeout
        // or any other failure, gh would answer the upstream again.
        if let origin = await RepoGitRunner.run(
            arguments: ["remote", "get-url", "origin"], root: path, timeoutSeconds: 20, maxBytes: 4096
        ) {
            guard !origin.timedOut, origin.exitCode == 0 || origin.exitCode == 2 else {
                Log.backends.error("Quick capture: git remote get-url origin exited \(origin.exitCode, privacy: .public)")
                return nil
            }
            if origin.exitCode == 0 {
                let repository = Self.repository(fromRemoteURL: String(decoding: origin.data, as: UTF8.self))
                if repository == nil {
                    Log.backends.info("Quick capture: the checkout's origin is not on GitHub")
                }
                return repository
            }
        }
        guard let gh = QuickCaptureDrafter.ghCandidates(environment: environment).first(where: isExecutable),
              let output = await BoundedProcess.run(
                  executableURL: URL(fileURLWithPath: gh), arguments: repoViewArguments, environment: environment,
                  currentDirectory: path, timeoutSeconds: 20, maxBytes: 4096, label: "quick capture gh repo view"
              ), output.exitCode == 0, !output.timedOut
        else { return nil }
        let name = String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return QuickCaptureInbox.isRepository(name) ? name : nil
    }

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
        await QuickCaptureFiling.repository(ofCheckout: path, environment: environment, isExecutable: isExecutable)
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
