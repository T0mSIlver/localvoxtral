import Foundation

/// One dictation's complete context-pipeline record, kept on this Mac beside
/// its History entry so a retrieval miss can be attributed after the fact.
///
/// The app deliberately logs context COUNTS only (`Log.polishing` /
/// `Log.claudeContext`): repository contents, screen text, clipboard text, and
/// rendered prompts must never reach the unified log. That policy is what makes
/// the shipped app's privacy claims true, and it is also why a term that came
/// out wrong is unattributable today — by commit time every intermediate the
/// answer depends on has been reduced to an integer.
///
/// This type is the deliberate exception, and it stays on disk: records are
/// 0600 files in a 0700 directory, never logged and never sent anywhere.
/// History > Storage > "Keep diagnostic records on this Mac" turns them off
/// (on by default), and History "Don't keep" writes none. Secret-shaped runs
/// are redacted and the prompt last sent to the agent is withheld
/// (`DiagnosticRecordRedaction`); the clipboard payload never enters.
///
/// ## What it is for
///
/// A missed technical term was lost by exactly one of four stages, and the fix
/// differs completely between them:
///
/// 1. `.retrieval` — the term never entered the harvest. The collector, screen
///    read, or `pane.read` did not surface it; matching never had a chance.
/// 2. `.matcher` — the term was in the harvest but no tier matched the heard
///    span (exact, edit-distance-one, phonetic, bounded aligned fallback).
/// 3. `.conflict` — a tier matched, but the cross-source merge abstained or
///    demoted it (`PolishContextGrounding`).
/// 4. `.budget` — it survived the merge but the render allocation cut the
///    excerpt that carried its evidence.
///
/// Every field below exists to make that four-way question answerable from the
/// record alone, without re-running the dictation.
package struct DiagnosticRecord: Codable, Equatable, Sendable {
    /// Bumped whenever a field changes meaning. The reviewer and the corpus
    /// converter both refuse records they were not written for rather than
    /// silently misreading an older shape.
    package static let currentSchemaVersion = 2

    package var schemaVersion: Int = DiagnosticRecord.currentSchemaVersion
    package var id: String
    package var capturedAt: Date

    package var session: Session
    package var join: Join?
    package var screen: Screen?
    package var allocation: [Allocation]
    package var sources: [Source]
    package var text: Text
    package var timings: Timings

    /// What the user DID with the insertion, patched in after the commit — see
    /// `Behavior` and `EditSignalWatcher`. Absent on records written
    /// before the field existed, on a dictation whose watch could not install a
    /// monitor, and on one whose patch write failed; in none of those is it safe
    /// to read the absence as "the user kept the text".
    ///
    /// Additive and optional, so `currentSchemaVersion` stays where it is: the
    /// version exists to stop a reader MISREADING an older shape, and no field
    /// above changed meaning. An older record decodes unchanged.
    package var behavior: Behavior?

    package struct Session: Codable, Equatable, Sendable {
        /// Bundle identifier of the app the text was inserted into.
        package var targetBundleID: String?
        /// `TerminalTargetDetector`'s verdict, as its own description.
        package var targetKind: String?
        /// Overlay Buffer vs Live Auto-Paste.
        package var outputMode: String
        /// Which polish profile rendered the prompt.
        package var promptProfile: String?
        /// Loopback vs LAN vs remote, never the URL itself.
        package var endpointClass: String?
        package var polishModel: String?

        package init(
            targetBundleID: String? = nil,
            targetKind: String? = nil,
            outputMode: String,
            promptProfile: String? = nil,
            endpointClass: String? = nil,
            polishModel: String? = nil
        ) {
            self.targetBundleID = targetBundleID
            self.targetKind = targetKind
            self.outputMode = outputMode
            self.promptProfile = promptProfile
            self.endpointClass = endpointClass
            self.polishModel = polishModel
        }
    }

    /// How (or whether) the dictation joined a Claude Code session. An
    /// abstention is as interesting as a join: "never joins" is the failure mode
    /// the herdr and TTY arms fail into, and it is invisible without the reason.
    package struct Join: Codable, Equatable, Sendable {
        /// `tty`, `herdrPane`, `cmuxSurface`, `browserTab`,
        /// `remoteHerdrPane`, `federatedHerdrPane`, `remoteSSHConnection`,
        /// `remoteLocalTTY`, or `none`.
        package var arm: String
        /// Populated when `arm == "none"`, or when an arm was attempted and
        /// abstained: the exact abstention cause, not a generic failure.
        package var abstentionReason: String?
        /// `local` or `remote`. Governs which context is even eligible.
        package var origin: String?
        /// Terminal the surface belonged to (Ghostty, iTerm2, Terminal.app,
        /// cmux).
        package var terminal: String?
        /// True when the surface TTY positively bound to a herdr client, which
        /// makes the join herdr-or-nothing from that point.
        package var herdrBound: Bool?
        package var workspaceIsLocal: Bool?

        package init(
            arm: String,
            abstentionReason: String? = nil,
            origin: String? = nil,
            terminal: String? = nil,
            herdrBound: Bool? = nil,
            workspaceIsLocal: Bool? = nil
        ) {
            self.arm = arm
            self.abstentionReason = abstentionReason
            self.origin = origin
            self.terminal = terminal
            self.herdrBound = herdrBound
            self.workspaceIsLocal = workspaceIsLocal
        }
    }

    /// The screen read and what the reconciliation decided to do with it.
    package struct Screen: Codable, Equatable, Sendable {
        /// `axGrid`, `appleScriptContents`, `herdrPaneRead`, or
        /// `cmuxSurfaceRead`.
        package var route: String?
        /// `render`, `vocabularyOnly`, or `drop`.
        package var decision: String
        /// The `VocabularyOnlyCause` / `DropReason` when either applies. This is
        /// the field that distinguishes "the feature is off" from "the read
        /// failed" from "the pane churned" — three very different bugs that all
        /// present to the user as no context.
        package var cause: String?
        /// Characters after sanitization, before excerpt selection.
        package var sanitizedCharacterCount: Int
        /// The sanitized screen as it entered matching. Bucket 1 is unanswerable
        /// without it: whether a term was ON the screen at all is exactly the
        /// retrieval question.
        package var sanitizedText: String?
        package var sanitizedTextTruncated: Bool = false

        package init(
            route: String? = nil,
            decision: String,
            cause: String? = nil,
            sanitizedCharacterCount: Int,
            sanitizedText: String? = nil,
            sanitizedTextTruncated: Bool = false
        ) {
            self.route = route
            self.decision = decision
            self.cause = cause
            self.sanitizedCharacterCount = sanitizedCharacterCount
            self.sanitizedText = sanitizedText
            self.sanitizedTextTruncated = sanitizedTextTruncated
        }
    }

    /// One source's demand and grant from the shared render budget.
    ///
    /// Present for every source that ran, including those granted zero — a
    /// source starved to nothing is the whole of bucket 4 and it leaves no other
    /// trace.
    package struct Allocation: Codable, Equatable, Sendable {
        package var source: String
        package var demandedCharacters: Int
        package var grantedCharacters: Int
        /// Characters actually rendered into the prompt block.
        package var renderedCharacters: Int
        /// True when the excerpt selector had to choose, i.e. demand exceeded
        /// the grant and evidence was necessarily dropped.
        package var excerptWasSelected: Bool

        package init(
            source: String,
            demandedCharacters: Int,
            grantedCharacters: Int,
            renderedCharacters: Int,
            excerptWasSelected: Bool
        ) {
            self.source = source
            self.demandedCharacters = demandedCharacters
            self.grantedCharacters = grantedCharacters
            self.renderedCharacters = renderedCharacters
            self.excerptWasSelected = excerptWasSelected
        }
    }

    /// One context source's harvest and everything it proposed from it.
    package struct Source: Codable, Equatable, Sendable {
        package var source: String

        /// The candidate term pool matching ran against. Bounded — see
        /// `harvestTruncated`, which is recorded rather than applied silently so
        /// a review never mistakes a truncated harvest for a retrieval miss.
        package var harvest: [String]
        package var harvestCount: Int
        package var harvestTruncated: Bool = false

        /// Pre-applied matches: spans that normalize to the term itself.
        package var entries: [Entry]
        /// Always empty since the 2026-09-18 nomination rework (phonetic hits
        /// are in `verificationEntries`); kept for record-format stability.
        package var phoneticEntries: [Entry]
        /// Every sound-alike hit (edit distance one, phonetic, aligned),
        /// offered to the model as a term; never pre-applied.
        package var verificationEntries: [Entry]
        /// Always false since the same rework; kept for format stability.
        package var isFallbackOnly: Bool

        /// The excerpt this source rendered into the prompt, if any.
        package var renderedExcerpt: String?

        package struct Entry: Codable, Equatable, Sendable {
            /// The exact local term the matcher proposes.
            package var term: String
            /// The transcript spans it claims, as heard.
            package var heard: [String]

            package init(
                term: String,
                heard: [String]
            ) {
                self.term = term
                self.heard = heard
            }
        }

        package init(
            source: String,
            harvest: [String],
            harvestCount: Int,
            harvestTruncated: Bool = false,
            entries: [Entry],
            phoneticEntries: [Entry],
            verificationEntries: [Entry],
            isFallbackOnly: Bool,
            renderedExcerpt: String? = nil
        ) {
            self.source = source
            self.harvest = harvest
            self.harvestCount = harvestCount
            self.harvestTruncated = harvestTruncated
            self.entries = entries
            self.phoneticEntries = phoneticEntries
            self.verificationEntries = verificationEntries
            self.isFallbackOnly = isFallbackOnly
            self.renderedExcerpt = renderedExcerpt
        }
    }

    /// Every text stage, in pipeline order. The diff between consecutive stages
    /// is what a review actually reads.
    package struct Text: Codable, Equatable, Sendable {
        /// Raw ASR, before the replacement dictionary and before grounding.
        package var rawTranscript: String
        /// After the replacement dictionary, before grounding pre-application.
        package var workingText: String
        /// After merged grounding entries were pre-applied — the exact string
        /// sent to the model.
        package var groundedText: String
        package var systemPrompt: String?
        /// Rendered user messages including every attached context block: the
        /// literal payload the model saw.
        package var userPrompts: [String]
        /// The model's reply, before any commit-side integrity handling.
        package var polishedOutput: String?
        /// What was actually committed to the focused app.
        package var committedText: String?

        package init(
            rawTranscript: String,
            workingText: String,
            groundedText: String,
            systemPrompt: String? = nil,
            userPrompts: [String],
            polishedOutput: String? = nil,
            committedText: String? = nil
        ) {
            self.rawTranscript = rawTranscript
            self.workingText = workingText
            self.groundedText = groundedText
            self.systemPrompt = systemPrompt
            self.userPrompts = userPrompts
            self.polishedOutput = polishedOutput
            self.committedText = committedText
        }
    }

    /// Did the user immediately take the insertion back?
    ///
    /// Every other field in this record describes what the pipeline DID; none of
    /// them says whether the answer was good. A record whose retrieval, budget,
    /// and prompt all look correct reads identically to one the owner erased
    /// half a second later, and the second is the one worth reviewing.
    ///
    /// Content-free by construction: two recognized gestures, everything else
    /// bucketed, nothing about any other key. The four-way attribution above
    /// says WHERE a term was lost; this says whether anything was lost at all.
    package struct Behavior: Codable, Equatable, Sendable {
        /// `edited`, `clean`, or `superseded`. `clean` is recorded on purpose —
        /// without the negative there is no denominator for an edit rate.
        package var outcome: EditSignalOutcome
        /// Which gesture ended the window. Nil unless `outcome == .edited`.
        package var signal: EditSignal?
        /// Bucketed delay from commit to gesture (`0-1`, `1-2`, `2-5`, `5-15`).
        /// Nil unless `outcome == .edited`.
        package var secondsSinceCommitBucket: String?
        /// Transcript length as a bucket (`1-5`, `6-15`, `16-40`, `41+`) — the
        /// same ladder step that chose the window.
        package var wordCountBucket: String
        /// The window this dictation actually got, so a review can tell a clean
        /// 2 s from a clean 15 s.
        package var watchWindowSeconds: Double
        /// Overlay Buffer vs Live Auto-Paste, duplicated from `Session` so the
        /// behavior block reads on its own in an aggregate.
        package var outputMode: String

        package init(
            outcome: EditSignalOutcome,
            signal: EditSignal? = nil,
            secondsSinceCommitBucket: String? = nil,
            wordCountBucket: String,
            watchWindowSeconds: Double,
            outputMode: String
        ) {
            self.outcome = outcome
            self.signal = signal
            self.secondsSinceCommitBucket = secondsSinceCommitBucket
            self.wordCountBucket = wordCountBucket
            self.watchWindowSeconds = watchWindowSeconds
            self.outputMode = outputMode
        }
    }

    package struct Timings: Codable, Equatable, Sendable {
        package var polishSeconds: Double?
        /// Wall time the capture itself added to the commit path. Recorded so a
        /// record cannot quietly change the latency it is measuring.
        package var captureMilliseconds: Double?

        package init(
            polishSeconds: Double? = nil,
            captureMilliseconds: Double? = nil
        ) {
            self.polishSeconds = polishSeconds
            self.captureMilliseconds = captureMilliseconds
        }
    }

    package init(
        schemaVersion: Int = DiagnosticRecord.currentSchemaVersion,
        id: String,
        capturedAt: Date,
        session: Session,
        join: Join? = nil,
        screen: Screen? = nil,
        allocation: [Allocation],
        sources: [Source],
        text: Text,
        timings: Timings,
        behavior: Behavior? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.capturedAt = capturedAt
        self.session = session
        self.join = join
        self.screen = screen
        self.allocation = allocation
        self.sources = sources
        self.text = text
        self.timings = timings
        self.behavior = behavior
    }
}

