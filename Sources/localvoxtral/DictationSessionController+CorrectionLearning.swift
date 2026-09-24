import Foundation

/// Hands a committed dictation to `CorrectionLearning`, which compares it with
/// the next prompt the joined session submits.
extension DictationSessionController {
    /// Only a dictation with a join can be compared: the join names the
    /// session whose submitted prompt holds the user's fix, and without one
    /// no prompt belongs to this text.
    ///
    /// - Parameter project: the project the polish pipeline resolved, which
    ///   widens a session in a subdirectory to its repository. Without
    ///   polish, the joined session's own workspace decides.
    func expectCorrection(
        of inserted: @autoclosure () -> String,
        join: ClaudeSessionJoin?,
        project: LearnedTermProjectResolver.Identity?
    ) {
        guard let correctionLearning, let join else { return }
        guard let project = project ?? LearnedTermProjectResolver.resolve(
            repositoryRoot: .unknown,
            workspace: join.snapshot.workspace
        ) else { return }
        correctionLearning.expect(
            inserted: inserted(),
            sessionID: join.snapshot.sessionID,
            project: project
        )
    }

    /// What Live Auto-Paste typed: the transcript with the replacement rules
    /// the session latched at start, as `LiveHoldBackReplacementStream`
    /// released it. Only the latched dictionary: loading one here would read
    /// the config file on a stop that never loaded it. The newline and tab
    /// sanitizing the stream also does only changes whitespace, which the
    /// comparison ignores.
    func liveTypedText() -> String {
        let raw = transcript.currentDictationEventText
        guard let dictionary = sessionReplacementDictionary else { return raw }
        return LiveReplacementCorrector.completedBoundaryCorrectedText(
            raw,
            dictionary: dictionary,
            includeFinalUnboundedWord: true
        )
    }
}
