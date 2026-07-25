#if LOCALVOXTRAL_DOGFOOD

import Foundation

/// One dictation's complete context-pipeline record, written locally by an
/// opt-in dogfooding build so a retrieval miss can be attributed after the fact.
///
/// The app deliberately logs context COUNTS only (`Log.polishing` /
/// `Log.claudeContext`): repository contents, screen text, clipboard text, and
/// rendered prompts must never reach the unified log. That policy is what makes
/// the shipped app's privacy claims true, and it is also why a term that came
/// out wrong is unattributable today — by commit time every intermediate the
/// answer depends on has been reduced to an integer.
///
/// This type is the deliberate, gated exception. It exists only in a build
/// compiled with `LOCALVOXTRAL_DOGFOOD` (see `Package.swift`), and within such a
/// build it is populated only while the runtime opt-in is armed. Records are
/// written to a 0700 directory as 0600 files and are never transmitted
/// anywhere — there is no uploader, and adding one would defeat the point of
/// the compile gate.
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
struct DogfoodCaptureRecord: Codable, Equatable, Sendable {
    /// Bumped whenever a field changes meaning. The reviewer and the corpus
    /// converter both refuse records they were not written for rather than
    /// silently misreading an older shape.
    static let currentSchemaVersion = 1

    var schemaVersion: Int = DogfoodCaptureRecord.currentSchemaVersion
    var id: String
    var capturedAt: Date

    /// Set by the "flag last dictation" affordance. Flagged records are the
    /// review queue and the corpus-conversion candidates, and retention treats
    /// them differently — see `DogfoodCaptureStore`.
    var flagged: Bool = false

    var session: Session
    var join: Join?
    var screen: Screen?
    var allocation: [Allocation]
    var sources: [Source]
    var text: Text
    var timings: Timings

    struct Session: Codable, Equatable, Sendable {
        /// Bundle identifier of the app the text was inserted into.
        var targetBundleID: String?
        /// `TerminalTargetDetector`'s verdict, as its own description.
        var targetKind: String?
        /// Overlay Buffer vs Live Auto-Paste.
        var outputMode: String
        /// Which polish profile rendered the prompt.
        var promptProfile: String?
        /// Loopback vs LAN vs remote, never the URL itself.
        var endpointClass: String?
        var polishModel: String?
    }

    /// How (or whether) the dictation joined a Claude Code session. An
    /// abstention is as interesting as a join: "never joins" is the failure mode
    /// the herdr and TTY arms fail into, and it is invisible without the reason.
    struct Join: Codable, Equatable, Sendable {
        /// `tty`, `herdrPane`, `titleMarker`, or `none`.
        var arm: String
        /// Populated when `arm == "none"`, or when an arm was attempted and
        /// abstained: the exact abstention cause, not a generic failure.
        var abstentionReason: String?
        /// `local` or `remote`. Governs which context is even eligible.
        var origin: String?
        /// Terminal the surface belonged to (Ghostty, iTerm2, Terminal.app).
        var terminal: String?
        /// True when the surface TTY positively bound to a herdr client, which
        /// makes the join herdr-or-nothing from that point.
        var herdrBound: Bool?
        var workspaceIsLocal: Bool?
    }

    /// The screen read and what the reconciliation decided to do with it.
    struct Screen: Codable, Equatable, Sendable {
        /// `axGrid`, `appleScriptContents`, or `herdrPaneRead`.
        var route: String?
        /// `render`, `vocabularyOnly`, or `drop`.
        var decision: String
        /// The `VocabularyOnlyCause` / `DropReason` when either applies. This is
        /// the field that distinguishes "the feature is off" from "the read
        /// failed" from "the pane churned" — three very different bugs that all
        /// present to the user as no context.
        var cause: String?
        /// Characters after sanitization, before excerpt selection.
        var sanitizedCharacterCount: Int
        /// The sanitized screen as it entered matching. Bucket 1 is unanswerable
        /// without it: whether a term was ON the screen at all is exactly the
        /// retrieval question.
        var sanitizedText: String?
        var sanitizedTextTruncated: Bool = false
    }

    /// One source's demand and grant from the shared render budget.
    ///
    /// Present for every source that ran, including those granted zero — a
    /// source starved to nothing is the whole of bucket 4 and it leaves no other
    /// trace.
    struct Allocation: Codable, Equatable, Sendable {
        var source: String
        var demandedCharacters: Int
        var grantedCharacters: Int
        /// Characters actually rendered into the prompt block.
        var renderedCharacters: Int
        /// True when the excerpt selector had to choose, i.e. demand exceeded
        /// the grant and evidence was necessarily dropped.
        var excerptWasSelected: Bool
    }

    /// One context source's harvest and everything it proposed from it.
    struct Source: Codable, Equatable, Sendable {
        var source: String

        /// The candidate term pool matching ran against. Bounded — see
        /// `harvestTruncated`, which is recorded rather than applied silently so
        /// a review never mistakes a truncated harvest for a retrieval miss.
        var harvest: [String]
        var harvestCount: Int
        var harvestTruncated: Bool = false

        /// Pre-apply eligible matches from the exact / edit-distance-one tiers.
        var entries: [Entry]
        /// Exact unambiguous phonetic matches — guess grade once sources are
        /// reconciled, so they can be dropped by the merge even when correct.
        var phoneticEntries: [Entry]
        /// Prompt-only mishearing suggestions; never pre-applied.
        var verificationEntries: [Entry]
        /// True when `entries` came from the bounded aligned fallback rather
        /// than a solid tier.
        var isFallbackOnly: Bool

        /// The excerpt this source rendered into the prompt, if any.
        var renderedExcerpt: String?

        struct Entry: Codable, Equatable, Sendable {
            /// The exact local term the matcher proposes.
            var term: String
            /// The transcript spans it claims, as heard.
            var heard: [String]
        }
    }

    /// Every text stage, in pipeline order. The diff between consecutive stages
    /// is what a review actually reads.
    struct Text: Codable, Equatable, Sendable {
        /// Raw ASR, before the replacement dictionary and before grounding.
        var rawTranscript: String
        /// After the replacement dictionary, before grounding pre-application.
        var workingText: String
        /// After merged grounding entries were pre-applied — the exact string
        /// sent to the model.
        var groundedText: String
        var systemPrompt: String?
        /// Rendered user messages including every attached context block: the
        /// literal payload the model saw.
        var userPrompts: [String]
        /// The model's reply, before any commit-side integrity handling.
        var polishedOutput: String?
        /// What was actually committed to the focused app.
        var committedText: String?
    }

    struct Timings: Codable, Equatable, Sendable {
        var polishSeconds: Double?
        /// Wall time the capture itself added to the commit path. Recorded so a
        /// dogfooding build cannot quietly change the latency it is measuring.
        var captureMilliseconds: Double?
    }
}

#endif
