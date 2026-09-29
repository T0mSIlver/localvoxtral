import Foundation

/// The project names every dictation's polish is told about (#1024): each
/// listed project's name and its repository's name. A speaker names their
/// repositories more than anything else, and a name nobody told the model
/// about comes back as the words it sounds like ("Vitek" for vidtheque).
///
/// The list is quick capture's (`QuickCaptureProjects.projects`), so a
/// forgotten or ignored project leaves both at once. It rides the About-you
/// block of the system prompt, which must stay the same from one dictation to
/// the next to keep the helper's cached prefix: the names are sorted, not
/// ordered by recency, so using another project does not change the prompt.
/// Only a project entering or leaving the list does, and past `maxProjects`
/// that includes one of the 30 most recent giving way to another.
package enum PolishProjectNames {
    /// The most recent projects, if there are more.
    package static let maxProjects = 30

    package static func names(from learned: LearnedTerms, now: Date) -> [String] {
        let projects = QuickCaptureProjects.projects(
            from: learned, userLines: [:], now: now, readme: { _ in nil }, checkoutExists: { _ in true }
        ).prefix(maxProjects)
        var names: [String] = []
        for project in projects {
            let repositoryName = project.repository?.split(separator: "/").last.map(String.init)
            for name in [project.name, repositoryName].compactMap({ $0 }) where !isGeneratedLabel(name) {
                names.append(name)
            }
        }
        // Sorted before the dedupe, so the spelling kept for two that differ
        // only in case does not depend on which project was used last.
        return SpeakerTerms.sanitized(names.sorted { lhs, rhs in
            lhs.caseFoldedForMatching != rhs.caseFoldedForMatching
                ? lhs.caseFoldedForMatching < rhs.caseFoldedForMatching : lhs < rhs
        })
    }

    /// The names not already in `terms`, compared as `key` compares them.
    package static func names(_ names: [String], notIn terms: [String]) -> [String] {
        let known = Set(terms.map(key))
        return names.filter { !known.contains(key($0)) }
    }

    /// The global terms that only repeat a project name: every polish sends
    /// them as a project name already, so Settings offers to remove them.
    package static func globalTerms(_ terms: [String], repeating names: [String]) -> [String] {
        let covered = Set(names.map(key))
        return terms.filter { covered.contains(key($0)) }
    }

    /// Letters and digits only, case-folded: "working set", "working-set" and
    /// "Working Set" are one name.
    package static func key(_ name: String) -> String {
        String(name.caseFoldedForMatching.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// A label a tool generated rather than a name anyone says: a remote
    /// session with no project header is named after its folder, and Claude
    /// Desktop and agent worktree folders end in a hex hash
    /// (`ci-speed-optimizations-7ffef0`, `agent-add526d17c28bb610`).
    static func isGeneratedLabel(_ name: String) -> Bool {
        guard let dash = name.lastIndex(of: "-") else { return false }
        let tail = name[name.index(after: dash)...]
        return tail.count >= 6 && tail.allSatisfy(\.isHexDigit) && tail.contains(where: \.isNumber)
    }
}
