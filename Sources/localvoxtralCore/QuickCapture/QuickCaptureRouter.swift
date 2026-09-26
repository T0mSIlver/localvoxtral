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

    package init(destination: Destination, classifier: Classifier, reason: Reason, topProbability: Double?) {
        self.destination = destination
        self.classifier = classifier
        self.reason = reason
        self.topProbability = topProbability
    }
}

/// One option as a classifier sees it: a short id the answer names, and the
/// text that describes it.
package struct QuickCaptureOption: Equatable, Sendable {
    package let id: String
    /// Nil for the catch-all.
    package let projectKey: String?
    package let description: String

    package init(id: String, projectKey: String?, description: String) {
        self.id = id
        self.projectKey = projectKey
        self.description = description
    }
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
    /// catch-all.
    package static let minimumTopProbability = 0.5
    /// A top option this close to the second is a tie.
    package static let minimumMargin = 0.15

    /// The options a classifier gets: one per project, then the catch-all.
    /// Ids are the project names made safe (letters, digits, `-`), with a
    /// numeric suffix where two projects share a name.
    package static func options(for projects: [QuickCaptureProject]) -> [QuickCaptureOption] {
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
        options.append(QuickCaptureOption(id: catchAllID, projectKey: nil, description: catchAllDescription))
        return options
    }

    /// The decision on one answer. The catch-all wins whenever the top
    /// option is the catch-all, below `minimumTopProbability`, or within
    /// `minimumMargin` of the runner-up; never a guessed project.
    package static func decide(
        probabilities: [String: Double],
        options: [QuickCaptureOption],
        classifier: QuickCaptureRoute.Classifier
    ) -> QuickCaptureRoute {
        let ranked = options
            .map { ($0, probabilities[$0.id] ?? 0) }
            .sorted { $0.1 > $1.1 }
        guard let (top, topProbability) = ranked.first else {
            return QuickCaptureRoute(destination: .catchAll, classifier: classifier, reason: .noProjects, topProbability: nil)
        }
        func catchAll(_ reason: QuickCaptureRoute.Reason) -> QuickCaptureRoute {
            QuickCaptureRoute(destination: .catchAll, classifier: classifier, reason: reason, topProbability: topProbability)
        }
        guard let key = top.projectKey else { return catchAll(.classifierChoseCatchAll) }
        guard topProbability >= minimumTopProbability else { return catchAll(.lowConfidence) }
        let runnerUp = ranked.count > 1 ? ranked[1].1 : 0
        guard topProbability - runnerUp >= minimumMargin else { return catchAll(.nearTie) }
        return QuickCaptureRoute(destination: .project(key), classifier: classifier, reason: .confident, topProbability: topProbability)
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
        let text = capture.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return QuickCaptureRoute(destination: .catchAll, classifier: .none, reason: .emptyCapture, topProbability: nil)
        }
        // With no project there is nothing to choose, and nothing leaves the Mac.
        guard !projects.isEmpty else {
            Log.backends.info("Quick capture: no joined project, kept in the inbox")
            return QuickCaptureRoute(destination: .catchAll, classifier: .none, reason: .noProjects, topProbability: nil)
        }
        let options = QuickCaptureRouting.options(for: projects)
        for classifier in classifiers {
            Log.backends.info(
                "Quick capture: asking \(classifier.kind.rawValue, privacy: .public) across \(options.count, privacy: .public) options"
            )
            do {
                let probabilities = try await classifier.classify(capture: text, options: options)
                let route = QuickCaptureRouting.decide(probabilities: probabilities, options: options, classifier: classifier.kind)
                Log.backends.info(
                    "Quick capture: \(classifier.kind.rawValue, privacy: .public) answered, \(route.reason.rawValue, privacy: .public) at \(route.topProbability ?? 0, privacy: .public)"
                )
                return route
            } catch {
                Log.backends.error(
                    "Quick capture: \(classifier.kind.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
        return QuickCaptureRoute(destination: .catchAll, classifier: .none, reason: .classifierFailed, topProbability: nil)
    }
}
