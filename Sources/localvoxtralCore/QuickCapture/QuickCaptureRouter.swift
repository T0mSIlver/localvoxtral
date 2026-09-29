import Foundation

/// Where a quick capture went (#725), and why. Kept with the capture in
/// History, so a capture is never lost whatever the router decided.
package struct QuickCaptureRoute: Codable, Equatable, Sendable {
    package enum Destination: Codable, Equatable, Sendable {
        /// A `QuickCaptureProject.key`.
        case project(String)
        /// The catch-all: the capture waits in the Inbox until the user
        /// moves it to a project.
        case catchAll
    }

    /// What made the decision.
    package enum Classifier: String, Codable, Equatable, Sendable {
        case jev
        /// The polishing model in its routing mode (`QuickCaptureChatClassifier`).
        case chatModel
        /// Nothing was asked: no projects, an empty capture, or every
        /// classifier failed.
        case none
    }

    package enum Reason: String, Codable, Equatable, Sendable {
        /// The top option cleared both bars.
        case confident
        /// The classifier picked the catch-all itself.
        case classifierChoseCatchAll
        case lowConfidence
        case nearTie
        case noProjects
        case emptyCapture
        case classifierFailed
    }

    package let destination: Destination
    package let classifier: Classifier
    package let reason: Reason
    /// The winning option's probability, when a classifier answered.
    package let topProbability: Double?
    /// The project a low or tied answer named (#938): the capture waits in
    /// the Inbox, and one click moves it there.
    package let suggestion: String?

    package init(
        destination: Destination, classifier: Classifier, reason: Reason, topProbability: Double?,
        suggestion: String? = nil
    ) {
        self.destination = destination
        self.classifier = classifier
        self.reason = reason
        self.topProbability = topProbability
        self.suggestion = suggestion
    }
}

/// One option as a classifier sees it: a short id the answer names, and the
/// text that describes it.
package struct QuickCaptureOption: Equatable, Sendable {
    package let id: String
    /// Nil for the catch-all. For an open capture, its project, if it has one.
    package let projectKey: String?
    package let description: String
    /// Set for an open capture the new one can join (#965).
    package let captureID: UUID?

    package init(id: String, projectKey: String?, description: String, captureID: UUID? = nil) {
        self.id = id
        self.projectKey = projectKey
        self.description = description
        self.captureID = captureID
    }
}

/// An Inbox item a new capture may be a follow-up to (#965): not filed, and
/// captured or joined within the hour.
package struct QuickCaptureOpenCapture: Equatable, Sendable {
    package let id: UUID
    package let projectKey: String?
    /// The draft's title, else the capture's first words.
    package let summary: String

    package init(id: UUID, projectKey: String?, summary: String) {
        self.id = id
        self.projectKey = projectKey
        self.summary = summary
    }
}

/// The router's answer once open captures are options too (#965): a route,
/// or the open capture the new one continues.
package enum QuickCaptureRouteAnswer: Equatable, Sendable {
    case route(QuickCaptureRoute)
    case join(UUID, classifier: QuickCaptureRoute.Classifier, probability: Double)
}

/// Picks one option for a capture. Answers a probability per option id it
/// knows; ids it leaves out count as zero.
package protocol QuickCaptureClassifying: Sendable {
    var kind: QuickCaptureRoute.Classifier { get }
    func classify(capture: String, options: [QuickCaptureOption]) async throws -> [String: Double]
}

package enum QuickCaptureRouting {
    /// The catch-all's option id.
    package static let catchAllID = "inbox"
    package static let catchAllDescription =
        "None of the projects above: a personal note, a task or an idea about something else, or too vague to place."
    /// Below this, the top option is a guess and the capture goes to the
    /// catch-all. Measured on the owner's 36-capture replay (2026-09-26),
    /// three project sets each:
    /// - GLM 5.3's self-reported confidence: all 19 wrong-project answers
    ///   said 0.85 or less, all 25 answers at 0.9 or more were right.
    /// - Jev through Vercel AI Gateway: every right project came at 0.95 or
    ///   more; 10 of its 12 wrong ones came under 0.9, and the two above were
    ///   captures whose project was not in the list at all.
    /// One bar for both, then.
    package static let minimumTopProbability = 0.9
    /// A top option this close to the second is a tie. Under the 0.9 bar
    /// only a classifier whose numbers do not sum to one can tie.
    package static let minimumMargin = 0.15

    /// At most this many open captures become options, the most recent.
    package static let maxOpenCaptures = 5

    /// The options a classifier gets: one per project, one per open capture
    /// (`capture-1`, …), then the catch-all.
    /// Ids are the project names made safe (letters, digits, `-`), with a
    /// numeric suffix where two projects share a name.
    package static func options(
        for projects: [QuickCaptureProject], openCaptures: [QuickCaptureOpenCapture] = []
    ) -> [QuickCaptureOption] {
        var used: Set<String> = [catchAllID]
        var options: [QuickCaptureOption] = []
        for project in projects {
            let base = slug(project.name)
            var id = base.isEmpty ? "project" : base
            var suffix = 2
            while used.contains(id) {
                id = "\(base.isEmpty ? "project" : base)-\(suffix)"
                suffix += 1
            }
            used.insert(id)
            options.append(QuickCaptureOption(id: id, projectKey: project.key, description: project.description))
        }
        let names = Dictionary(projects.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first })
        for (index, capture) in openCaptures.prefix(maxOpenCaptures).enumerated() {
            var id = "capture-\(index + 1)"
            while used.contains(id) { id += "-note" }
            used.insert(id)
            let project = capture.projectKey.flatMap { names[$0] }.map { " (\($0))" } ?? ""
            options.append(QuickCaptureOption(
                id: id, projectKey: capture.projectKey,
                description: "An earlier note, not filed yet\(project): \"\(capture.summary)\"",
                captureID: capture.id
            ))
        }
        options.append(QuickCaptureOption(id: catchAllID, projectKey: nil, description: catchAllDescription))
        return options
    }

    /// The decision on one answer. The catch-all wins whenever the top
    /// option is the catch-all, below `minimumTopProbability`, or within
    /// `minimumMargin` of the runner-up; never a guessed project. A guessed
    /// project is kept as the route's suggestion, for the user to confirm.
    package static func decide(
        probabilities: [String: Double],
        options: [QuickCaptureOption],
        classifier: QuickCaptureRoute.Classifier
    ) -> QuickCaptureRoute {
        switch answer(probabilities: probabilities, options: options, classifier: classifier) {
        case .route(let route): route
        // Only an open capture's option joins, and callers of `decide` list none.
        case .join(_, _, let probability):
            QuickCaptureRoute(destination: .catchAll, classifier: classifier, reason: .lowConfidence, topProbability: probability)
        }
    }

    /// `decide`, where an open capture's option (#965) may win: it joins
    /// only past the same bars as a project. Under them the capture waits
    /// unplaced, with that capture's project as the suggestion.
    package static func answer(
        probabilities: [String: Double],
        options: [QuickCaptureOption],
        classifier: QuickCaptureRoute.Classifier
    ) -> QuickCaptureRouteAnswer {
        let ranked = options
            .map { ($0, probabilities[$0.id] ?? 0) }
            .sorted { $0.1 > $1.1 }
        guard let (top, topProbability) = ranked.first else {
            return .route(QuickCaptureRoute(destination: .catchAll, classifier: classifier, reason: .noProjects, topProbability: nil))
        }
        func catchAll(_ reason: QuickCaptureRoute.Reason, suggesting key: String? = nil) -> QuickCaptureRouteAnswer {
            .route(QuickCaptureRoute(
                destination: .catchAll, classifier: classifier, reason: reason, topProbability: topProbability,
                suggestion: key
            ))
        }
        guard top.captureID != nil || top.projectKey != nil else { return catchAll(.classifierChoseCatchAll) }
        let suggestion = topProbability > 0 ? top.projectKey : nil
        guard topProbability >= minimumTopProbability else { return catchAll(.lowConfidence, suggesting: suggestion) }
        let runnerUp = ranked.count > 1 ? ranked[1].1 : 0
        guard topProbability - runnerUp >= minimumMargin else { return catchAll(.nearTie, suggesting: suggestion) }
        if let captureID = top.captureID {
            return .join(captureID, classifier: classifier, probability: topProbability)
        }
        guard let key = top.projectKey else { return catchAll(.classifierChoseCatchAll) }
        return .route(QuickCaptureRoute(destination: .project(key), classifier: classifier, reason: .confident, topProbability: topProbability))
    }

    private static func slug(_ name: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return String(result.prefix(48))
    }
}

/// Routes one capture: Jev when the user allowed it and a key exists, else
/// or on failure the polishing model's routing mode, else the catch-all.
package struct QuickCaptureRouter: Sendable {
    /// In order of preference. The app passes Jev only when its consent
    /// toggle is on.
    private let classifiers: [any QuickCaptureClassifying]

    package init(classifiers: [any QuickCaptureClassifying]) {
        self.classifiers = classifiers
    }

    package func route(capture: String, projects: [QuickCaptureProject]) async -> QuickCaptureRoute {
        switch await answer(capture: capture, projects: projects) {
        case .route(let route): route
        case .join(_, let classifier, let probability):
            QuickCaptureRoute(destination: .catchAll, classifier: classifier, reason: .lowConfidence, topProbability: probability)
        }
    }

    /// `route`, with the open captures the new one may continue (#965) as
    /// options on the same call.
    package func answer(
        capture: String, projects: [QuickCaptureProject], openCaptures: [QuickCaptureOpenCapture] = []
    ) async -> QuickCaptureRouteAnswer {
        let text = capture.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .route(QuickCaptureRoute(destination: .catchAll, classifier: .none, reason: .emptyCapture, topProbability: nil))
        }
        // With no project there is nothing to choose, and nothing leaves the Mac.
        guard !projects.isEmpty else {
            Log.backends.info("Quick capture: no joined project, kept in the inbox")
            return .route(QuickCaptureRoute(destination: .catchAll, classifier: .none, reason: .noProjects, topProbability: nil))
        }
        let options = QuickCaptureRouting.options(for: projects, openCaptures: openCaptures)
        for classifier in classifiers {
            Log.backends.info(
                "Quick capture: asking \(classifier.kind.rawValue, privacy: .public) across \(options.count, privacy: .public) options"
            )
            do {
                let probabilities = try await classifier.classify(capture: text, options: options)
                let answer = QuickCaptureRouting.answer(probabilities: probabilities, options: options, classifier: classifier.kind)
                switch answer {
                case .route(let route):
                    Log.backends.info(
                        "Quick capture: \(classifier.kind.rawValue, privacy: .public) answered, \(route.reason.rawValue, privacy: .public) at \(route.topProbability ?? 0, privacy: .public)"
                    )
                case .join(_, _, let probability):
                    Log.backends.info(
                        "Quick capture: \(classifier.kind.rawValue, privacy: .public) answered a follow-up to an open capture at \(probability, privacy: .public)"
                    )
                }
                return answer
            } catch {
                Log.backends.error(
                    "Quick capture: \(classifier.kind.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
        return .route(QuickCaptureRoute(destination: .catchAll, classifier: .none, reason: .classifierFailed, topProbability: nil))
    }
}
