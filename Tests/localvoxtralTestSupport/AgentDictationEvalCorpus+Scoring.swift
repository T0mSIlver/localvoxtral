import Foundation

/// What each pipeline runs, and the `tokens` metric: the parts of the eval's
/// scoring that need no polish, shared by the end-to-end eval on the Mac and
/// the ASR-only run on Linux (`AgentDictationASREvalTests`).
extension AgentDictationEvalCorpus {
    package struct StagePlan: Equatable {
        /// Recorded speech or TTS(spokenForm) -> websocket ASR.
        package let runsSpeechRecognition: Bool
        /// The polish stop-commit path.
        package let runsPolish: Bool

        package init(runsSpeechRecognition: Bool, runsPolish: Bool) {
            self.runsSpeechRecognition = runsSpeechRecognition
            self.runsPolish = runsPolish
        }
    }

    package static func stagePlan(for pipeline: Pipeline) -> StagePlan {
        switch pipeline {
        case .full:
            return StagePlan(runsSpeechRecognition: true, runsPolish: true)
        case .asrOnly:
            return StagePlan(runsSpeechRecognition: true, runsPolish: false)
        case .polishOnly:
            return StagePlan(runsSpeechRecognition: false, runsPolish: true)
        }
    }

    /// `tokens` metric: every `requiredTokens` entry present (byte-exact after
    /// spacing normalization; case-sensitive unless the case sets
    /// `caseInsensitive`) AND no `forbiddenSubstrings` entry present (always
    /// case-insensitive). Returns human-readable failure descriptions; empty
    /// means pass.
    package static func tokensFailures(
        output: String,
        evalCase: Case
    ) -> [String] {
        let normalized = normalizedSpacing(output)
        let requiredHaystack = evalCase.isCaseInsensitive ? normalized.lowercased() : normalized
        var failures: [String] = []
        for token in evalCase.requiredTokens {
            var needle = normalizedSpacing(token)
            if evalCase.isCaseInsensitive { needle = needle.lowercased() }
            if !requiredHaystack.contains(needle) {
                failures.append("missing \"\(token)\"")
            }
        }
        let forbiddenHaystack = normalized.lowercased()
        for needle in evalCase.forbidden {
            let normalizedNeedle = normalizedSpacing(needle).lowercased()
            if forbiddenHaystack.contains(normalizedNeedle) {
                failures.append("contains forbidden \"\(needle)\"")
            }
        }
        return failures
    }

    /// Unifies the space variants a correct French typography can use
    /// (U+202F narrow no-break, U+00A0 no-break) with a plain space and
    /// collapses runs.
    package static func normalizedSpacing(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
    }
}
