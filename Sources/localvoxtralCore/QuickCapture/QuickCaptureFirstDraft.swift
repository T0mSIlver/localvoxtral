import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The first stage of a quick capture's draft (#918): one OpenAI-compatible
/// `chat/completions` call to the polishing model, with the context the app
/// gathered (`QuickCaptureContext`). It sorts the capture by kind and writes
/// the title and body in 10 to 50 seconds, without reading code; an issue's
/// draft is then checked against the code by the project's agent.
///
/// Measured on #918's four captures (GLM 5.3, `reasoning_effort: low`):
/// about 7,500 tokens in and 3,000 to 8,000 out, of which the reasoning
/// once took the whole 8,000-token cap; hence `maxTokens`.
package enum QuickCaptureFirstDraft {
    package static let requestTimeout: TimeInterval = 120
    package static let maxTokens = 16_384

    package static let systemPrompt = """
        You sort and draft a developer's dictated notes about one of their \
        software projects. A note is a quick brain dump, and speech recognition \
        may have misheard a few words. First decide what the note is:
        - "issue": a change to the project: a feature, a bug, a refactor, docs.
        - "question": the developer asks something about the project.
        - "task": something the developer means to do themselves, such as a \
        reminder to check or try something, that is not a change to the project.
        - "note": anything else worth keeping: a thought or an observation.
        For an issue: \(QuickCaptureDraft.issueSections) You have not read the \
        code: name files, types and functions only as they appear in the search \
        hits, and put what you would need to read under Open questions. Link \
        only numbers from the lists given.
        For a question: the body answers it in a few sentences from the context, \
        citing issue and pull request numbers or files, and says what the \
        context cannot tell.
        For a task or a note: the body restates it plainly in the developer's \
        words, in one to three sentences.
        Every kind gets a title under 70 characters, in the developer's words.
        Reply with JSON only: {"kind": "issue" | "question" | "task" | "note", \
        "title": "...", "body": "...", "relation": "none" | "duplicate" | \
        "extends", "issue": <an open issue's number or null>}. Relation and \
        issue name the open issue an issue duplicates or extends; they are \
        "none" and null for every other kind.
        """

    package static func userMessage(capture: String, projectName: String, context: QuickCaptureContext) -> String {
        var text = "Project: \(projectName)\n"
        if let readme = context.readme {
            text += "\n<readme>\n\(readme)\n</readme>\n"
        }
        if let rules = context.issueRules {
            text += "\n<guide>\n\(rules)\n</guide>\n"
        }
        text += "\n<search-hits>\n"
        text += context.codeHits.isEmpty ? "(none)\n" : context.codeHits.joined(separator: "\n") + "\n"
        text += "</search-hits>\n\n<open-issues>\n"
        if let issues = context.openIssues {
            if issues.isEmpty { text += "(none)\n" }
            for issue in issues.prefix(QuickCaptureDraft.maxListedIssues) {
                let excerpt = QuickCaptureDraft.oneLine(issue.body, limit: QuickCaptureDraft.maxIssueExcerptCharacters)
                text += "#\(issue.number) \(QuickCaptureDraft.oneLine(issue.title, limit: 200))"
                    + (excerpt.isEmpty ? "" : ": \(excerpt)") + "\n"
            }
        } else {
            text += "(could not be listed; do not claim a duplicate)\n"
        }
        text += "</open-issues>\n"
        func references(_ tag: String, _ list: [QuickCaptureContext.Reference]?) {
            guard let list, !list.isEmpty else { return }
            text += "\n<\(tag)>\n" + list.map { "#\($0.number) \($0.title)" }.joined(separator: "\n") + "\n</\(tag)>\n"
        }
        references("recently-closed-issues", context.closedIssues)
        references("recently-merged-pull-requests", context.mergedPullRequests)
        text += "\n<note>\n\(capture)\n</note>"
        return text
    }

    /// - Parameter extraBody: fields the polishing configuration adds (a
    ///   reasoning effort, chat template switches), merged last.
    package static func requestBody(
        model: String,
        capture: String,
        projectName: String,
        context: QuickCaptureContext,
        extraBody: [String: any Sendable] = [:]
    ) -> Data {
        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage(capture: capture, projectName: projectName, context: context)],
            ],
        ]
        for (key, value) in extraBody { body[key] = value }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// The model's answer read as a draft. The same untrusted-text rules as
    /// the agent's (`QuickCaptureDraft.draft(from:openIssues:)`).
    package static func outcome(status: Int, body: Data, openIssues: [Int]) -> QuickCaptureDraft.Outcome {
        guard (200..<300).contains(status) else { return .failed(.agentError("http \(status)")) }
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else { return .failed(.malformedOutput) }
        if choices.first?["finish_reason"] as? String == "length" { return .failed(.outputTooLarge) }
        guard let content = QuickCaptureChatRouting.text(ofContent: message["content"]),
              let answer = QuickCaptureChatRouting.jsonObject(in: content),
              let draft = QuickCaptureDraft.draft(from: answer, openIssues: openIssues)
        else { return .failed(.malformedOutput) }
        let usage = LLMTokenUsage(responseObject: json)
        return .draft(
            draft.keepingFiles(nil),
            usage: usage.map {
                ProjectTermProposal.Usage(
                    turns: 1, costUSD: nil, inputTokens: $0.promptTokens, cacheWriteTokens: nil,
                    cacheReadTokens: $0.cachedPromptTokens, outputTokens: $0.completionTokens
                )
            }
        )
    }
}

/// Writes a first draft. The seam the drafter's tests replace.
package protocol QuickCaptureFirstDrafting: Sendable {
    func firstDraft(capture: String, projectName: String, context: QuickCaptureContext) async -> QuickCaptureDraft.Outcome
}

/// The polishing model's call.
package struct QuickCaptureFirstDrafter: QuickCaptureFirstDrafting {
    private let endpoint: URL
    private let apiKey: String
    private let model: String
    private let extraBody: [String: any Sendable]
    private let session: URLSession
    private let usageBackend: UsageEntry.Backend
    private let usageRecorder: (any UsageRecording)?
    private let now: @Sendable () -> Date

    /// - Parameter endpoint: the full `chat/completions` URL.
    package init(
        endpoint: URL,
        apiKey: String,
        model: String,
        extraBody: [String: any Sendable] = [:],
        session: URLSession = SameOriginHTTP.shared,
        usageBackend: UsageEntry.Backend = .userServer,
        usageRecorder: (any UsageRecording)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.extraBody = extraBody
        self.session = session
        self.usageBackend = usageBackend
        self.usageRecorder = usageRecorder
        self.now = now
    }

    package func firstDraft(capture: String, projectName: String, context: QuickCaptureContext) async -> QuickCaptureDraft.Outcome {
        var request = URLRequest(url: endpoint, timeoutInterval: QuickCaptureFirstDraft.requestTimeout)
        request.httpMethod = "POST"
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = QuickCaptureFirstDraft.requestBody(
            model: model, capture: capture, projectName: projectName, context: context, extraBody: extraBody
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let timedOut = (error as? URLError)?.code == .timedOut
            Log.backends.error(
                "Quick capture first draft: request failed: \(timedOut ? "timed out" : String(describing: type(of: error)), privacy: .public)"
            )
            return .failed(timedOut ? .timedOut : .launchFailed)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // A 2xx is billed whether or not its answer is usable.
        if (200..<300).contains(status), let usageRecorder {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            usageRecorder.record(UsageEntry.chat(
                date: now(),
                feature: .quickCaptureDrafting,
                backend: usageBackend,
                requestedModel: model,
                usage: json.flatMap(LLMTokenUsage.init(responseObject:))
            ))
        }
        return QuickCaptureFirstDraft.outcome(
            status: status, body: data, openIssues: context.openIssues?.map(\.number) ?? []
        )
    }
}
