import Foundation
import Synchronization

/// Side-channel for the two pipeline facts the commit path cannot see in its
/// own return values: WHY a join abstained, and WHAT the terminal-cwd repo
/// vocabulary harvested.
///
/// Both producers already reduce those facts to a log line before returning —
/// the resolver returns `nil` for every abstention cause, and the vocabulary
/// pipeline returns a `GroundingOutcome` that no longer carries its term pool.
/// Threading them through the return types would fork the production signatures
/// for the record alone, so they are tapped here instead: producers note, the
/// commit path consumes.
///
/// One dictation at a time by design (the commit path is serialized on the main
/// actor), so a single slot per fact is enough. `beginSession()` clears both
/// slots at dictation start; a fact noted by an abandoned pipeline after its
/// session's commit consumed the slot is cleared there rather than leaking into
/// the next record.
///
/// `Mutex` rather than an actor because the producers are on different
/// isolation domains: the resolver runs on the main actor, the repo-vocabulary
/// pipeline in a detached utility task.
final class DiagnosticCaptureTap: Sendable {
    static let shared = DiagnosticCaptureTap()

    private struct State {
        /// Which dictation the slots belong to. Bumped by `beginSession`, so a
        /// note carrying an older generation can be recognized as stale.
        var generation: UInt64 = 0
        var joinAbstentions: [String] = []
        var repoVocabularyHarvest: [String]?
        /// The last join this app RESOLVED, summarized at resolution time.
        ///
        /// Deliberately outside the consume/clear cycle above. `join report` on
        /// the dogfood control socket has to answer after a dictation has
        /// finished, and by then the commit path has consumed the abstentions
        /// AND `SessionContextResolver.claudeSessionJoin` — the commit path
        /// consumes the join, by design (docs/agent/invariants.md). So the
        /// summary is snapshotted the moment it is resolved and kept until the
        /// next resolution replaces it. It is the same
        /// `ClaudeSessionJoinSummary` the record and `--probe-surface` use, so
        /// a report and a record cannot describe the same dictation
        /// differently.
        var lastResolvedJoin: ClaudeSessionJoinSummary?
    }

    private let state = Mutex(State())

    /// The join resolver and the herdr panel probe live in the core, which
    /// can't see this tap, so they note abstentions through this sink.
    private init() {
        ClaudeJoinAbstentionTap.diagnosticSink.withLock {
            $0 = { [self] cause in noteJoinAbstention(cause) }
        }
    }

    /// The generation a harvest note was created under. The repo-vocabulary
    /// pipeline is a DETACHED task racing `RepoVocabularyPipeline.deadline`
    /// (3 s at the time of writing); when the deadline
    /// wins, the pipeline is abandoned but keeps running, and its eventual
    /// harvest note can land after the owning session already consumed — which
    /// would put session A's repo terms into session B's record, the exact
    /// bucket-1 misattribution the record exists to prevent (review, 2026-07-25).
    /// The commit path binds this task-local around the pipeline body at task
    /// creation (task-locals do not cross `Task.detached` on their own), and
    /// `noteRepoVocabularyHarvest` rejects a note whose generation has passed.
    /// Nil (an unbound caller, e.g. a direct unit test) is accepted as current.
    @TaskLocal static var noteGeneration: UInt64?

    /// Clears both slots and advances the generation. Called at dictation
    /// start, before the join resolves.
    func beginSession() {
        state.withLock {
            $0.generation &+= 1
            $0.joinAbstentions = []
            $0.repoVocabularyHarvest = nil
        }
    }

    var currentGeneration: UInt64 {
        state.withLock { $0.generation }
    }

    /// One arm's abstention cause, e.g. `"tty: stale"`. Accumulated: a single
    /// resolve can abstain on the tty arm and then again on the remote-herdr
    /// arm, and the record wants the whole story, not the last chapter.
    ///
    /// No generation check, deliberately: abstentions are noted synchronously
    /// on the main actor during session start, and overlapping session starts
    /// are blocked upstream — there is no abandoned producer to guard against.
    func noteJoinAbstention(_ cause: String) {
        state.withLock { $0.joinAbstentions.append(cause) }
    }

    /// The exact term pool the terminal-cwd repo vocabulary matched against.
    /// Dropped when `noteGeneration` says the note is from a session that has
    /// already ended — see `noteGeneration`.
    func noteRepoVocabularyHarvest(_ terms: [String]) {
        state.withLock {
            if let generation = Self.noteGeneration, generation != $0.generation {
                return
            }
            $0.repoVocabularyHarvest = terms
        }
    }

    /// All abstention causes noted since `beginSession`, oldest first, and
    /// clears them.
    func consumeJoinAbstentions() -> [String] {
        state.withLock {
            let causes = $0.joinAbstentions
            $0.joinAbstentions = []
            return causes
        }
    }

    /// The abstention causes so far WITHOUT clearing them.
    ///
    /// `consumeJoinAbstentions` is the commit path's, and it empties the slot.
    /// The join summary is snapshotted at resolution time, long before that
    /// commit, so it must be able to read the causes without stealing them.
    func peekJoinAbstentions() -> [String] {
        state.withLock { $0.joinAbstentions }
    }

    /// Snapshot the join this dictation resolved. Replaces the previous one;
    /// never cleared by `beginSession`, so it survives the commit that consumes
    /// the join itself.
    func noteResolvedJoin(_ summary: ClaudeSessionJoinSummary) {
        state.withLock { $0.lastResolvedJoin = summary }
    }

    /// The last resolved join, or nil when no dictation has resolved one in
    /// this process. Non-consuming: two readers must see the same answer.
    func lastResolvedJoin() -> ClaudeSessionJoinSummary? {
        state.withLock { $0.lastResolvedJoin }
    }

    /// The noted harvest, if any, and clears it.
    func consumeRepoVocabularyHarvest() -> [String]? {
        state.withLock {
            let harvest = $0.repoVocabularyHarvest
            $0.repoVocabularyHarvest = nil
            return harvest
        }
    }
}

/// Assembles a `DiagnosticRecord` from the values the commit path already
/// holds, and derives the few record fields that are not literally one of them.
///
/// Pure and `nonisolated`: the harvest re-derivations walk complete retained
/// buffers (a clipboard can retain 2M characters), and the commit path is
/// `@MainActor` — so `build` is awaited off-actor exactly like the preparations
/// whose inputs it mirrors.
enum DiagnosticRecordBuilder {
    /// Harvest lists are capped in the RECORD, never in matching (which already
    /// ran). 500 terms is comfortably past where scanning a record stops being
    /// how anyone reviews it; `harvestTruncated` says the cap fired so a review
    /// never mistakes a truncated harvest for a retrieval miss.
    static let harvestTermCap = 500

    /// Screen text is capped at the AX reader's own retention cap; anything
    /// past it was never in memory to begin with, so this only guards against
    /// a future cap change silently growing records.
    static let sanitizedScreenTextCap = 32_000

    struct SourceInputs {
        var source: PolishContextSource
        var harvest: [String]
        var outcome: RepoVocabularyMatcher.GroundingOutcome
        var renderedExcerpt: String?
    }

    /// `host` class only, never the URL: `loopback`, `lan`, or `remote`.
    /// Deliberately coarse — the record needs "was this the bundled helper, a
    /// LAN box, or something else", not the user's network layout.
    static func endpointClass(of url: URL) -> String {
        if PolishContextClipboardReader.isLoopbackEndpoint(url) { return "loopback" }
        guard let host = url.host?.lowercased() else { return "remote" }
        if host.hasSuffix(".local") || host.hasPrefix("10.") || host.hasPrefix("192.168.") {
            return "lan"
        }
        if host.hasPrefix("172."),
           let second = host.split(separator: ".").dropFirst().first,
           let octet = Int(second), (16...31).contains(octet)
        {
            return "lan"
        }
        return "remote"
    }

    /// The record's join block, derived from the SHARED summary rather than
    /// from a second reading of `ClaudeSessionJoin`.
    ///
    /// `--probe-surface` reports the same six facts, and a record and a probe
    /// run that disagreed about one dictation would make both useless. So the
    /// arm vocabulary, the origin class, the terminal name, and the abstention
    /// joining all live in `ClaudeSessionJoinSummary`, and this is a field copy.
    static func join(
        from join: ClaudeSessionJoin?,
        abstentions: [String]
    ) -> DiagnosticRecord.Join {
        // A resolved join can still have earlier arms' abstentions (tty
        // abstained, the herdr pane arm answered) — kept, because "the tty arm
        // never answers" is invisible in a record that only names the winner.
        let summary = ClaudeSessionJoinSummary.summarize(join: join, abstentions: abstentions)
        return DiagnosticRecord.Join(
            arm: summary.arm,
            abstentionReason: summary.abstentionReason,
            origin: summary.origin,
            terminal: summary.terminal,
            herdrBound: summary.herdrBound,
            workspaceIsLocal: summary.workspaceIsLocal
        )
    }

    static func screen(
        from decision: TerminalScreenContextDecision,
        targetBundleID: String?,
        socketPaneSwapApplied: Bool
    ) -> DiagnosticRecord.Screen {
        let route: String?
        if socketPaneSwapApplied {
            // The swap only ever comes from the joined pane's own socket, so
            // the target app names which one answered.
            route = targetBundleID == TerminalScreenAllowlist.cmuxBundleID
                ? "cmuxSurfaceRead" : "herdrPaneRead"
        } else if let targetBundleID,
                  TerminalScreenAllowlist.axCaptureBundleIDs.contains(targetBundleID)
        {
            route = "axGrid"
        } else if let targetBundleID,
                  TerminalScreenAllowlist.appleScriptCaptureBundleIDs.contains(targetBundleID)
        {
            route = "appleScriptContents"
        } else {
            route = nil
        }

        switch decision {
        case let .render(excerpt, startText, elidedChurnLines):
            return screenRecord(
                route: route,
                decision: "render",
                cause: elidedChurnLines > 0 ? "elided-churn-lines:\(elidedChurnLines)" : nil,
                sanitizedText: startText.isEmpty ? excerpt : startText
            )
        case let .vocabularyOnly(startText, cause):
            return screenRecord(
                route: route,
                decision: "vocabularyOnly",
                cause: cause.summarySlug,
                sanitizedText: startText
            )
        case let .drop(reason):
            return screenRecord(
                route: route,
                decision: "drop",
                cause: reason.rawValue,
                sanitizedText: nil
            )
        }
    }

    private static func screenRecord(
        route: String?,
        decision: String,
        cause: String?,
        sanitizedText: String?
    ) -> DiagnosticRecord.Screen {
        let truncated = (sanitizedText?.count ?? 0) > sanitizedScreenTextCap
        return DiagnosticRecord.Screen(
            route: route,
            decision: decision,
            cause: cause,
            sanitizedCharacterCount: sanitizedText?.count ?? 0,
            sanitizedText: truncated
                ? sanitizedText.map { String($0.prefix(sanitizedScreenTextCap)) }
                : sanitizedText,
            sanitizedTextTruncated: truncated
        )
    }

    static func source(_ inputs: SourceInputs) -> DiagnosticRecord.Source {
        let truncated = inputs.harvest.count > harvestTermCap
        return DiagnosticRecord.Source(
            source: inputs.source.rawValue,
            harvest: truncated
                ? Array(inputs.harvest.prefix(harvestTermCap)) : inputs.harvest,
            harvestCount: inputs.harvest.count,
            harvestTruncated: truncated,
            entries: entries(inputs.outcome.entries),
            phoneticEntries: entries(inputs.outcome.phoneticEntries),
            verificationEntries: entries(inputs.outcome.verificationCandidates),
            isFallbackOnly: inputs.outcome.isFallbackOnly,
            renderedExcerpt: inputs.renderedExcerpt.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private static func entries(
        _ entries: [ReplacementEntry]
    ) -> [DiagnosticRecord.Source.Entry] {
        entries.map { .init(term: $0.replaceWith, heard: $0.matches) }
    }

    static func allocations(
        demands: [PolishContextSource: Int],
        grants: [PolishContextSource: Int],
        rendered: [PolishContextSource: Int]
    ) -> [DiagnosticRecord.Allocation] {
        // Every source that DEMANDED, in allocation-rank order — a source
        // granted zero is the whole of bucket 4 and it leaves no other trace.
        PolishContextSource.allCases.compactMap { source in
            let demand = demands[source] ?? 0
            guard demand > 0 else { return nil }
            let grant = grants[source] ?? 0
            return DiagnosticRecord.Allocation(
                source: source.rawValue,
                demandedCharacters: demand,
                grantedCharacters: grant,
                renderedCharacters: rendered[source] ?? 0,
                excerptWasSelected: demand > grant
            )
        }
    }

    /// The candidate term pool for a flat text source — the same derivation
    /// `ClipboardVocabulary.candidateOutcome` starts from, re-run here because
    /// the outcome discards it. Runs off-actor (this whole type does), once per
    /// recorded dictation, and the cost lands in `Timings.captureMilliseconds`.
    static func textSourceHarvest(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return ClipboardVocabulary.entities(inExcerpt: text)
    }

    /// The joined-session repo's term pool — the exact list
    /// `ClaudeRepoContextPreparation.prepare` matched against.
    static func claudeRepoHarvest(_ snapshot: ClaudeRepoSnapshot?) -> [String] {
        guard let snapshot else { return [] }
        return ClaudeRepoContextPreparation.terms(
            from: ClaudeRepoContextPreparation.groundingSources(snapshot: snapshot)
        )
    }
}

/// Everything the polish commit path knows that a record needs, captured by
/// value so assembly can run off the main actor after the commit completed.
///
/// A nil text/snapshot means that source never ran this dictation and gets no
/// `Source` row; an empty-but-present one ran and harvested nothing, which is
/// exactly the retrieval evidence (bucket 1) the record exists to keep.
struct DiagnosticRecordInputs: Sendable {
    var session: DiagnosticRecord.Session
    var join: ClaudeSessionJoin?
    var joinAbstentions: [String]
    var screenDecision: TerminalScreenContextDecision
    var socketPaneSwapApplied: Bool
    var targetBundleID: String?

    var demands: [PolishContextSource: Int]
    var grants: [PolishContextSource: Int]
    var rendered: [PolishContextSource: Int]

    /// The terminal-cwd repo vocabulary's term pool from the tap, nil when the
    /// pipeline never built a vocabulary.
    var repoVocabularyHarvest: [String]?
    var repoVocabularyOutcome: RepoVocabularyMatcher.GroundingOutcome
    var claudeRepoSnapshot: ClaudeRepoSnapshot?
    var claudeRepoOutcome: RepoVocabularyMatcher.GroundingOutcome
    var claudeRepoRenderedExcerpt: String?
    var claudeSessionText: String?
    var claudeSessionOutcome: RepoVocabularyMatcher.GroundingOutcome
    var claudeSessionRenderedExcerpt: String?
    var clipboardRetainedText: String?
    var clipboardOutcome: RepoVocabularyMatcher.GroundingOutcome
    var clipboardRenderedExcerpt: String?
    var screenOutcome: RepoVocabularyMatcher.GroundingOutcome
    var screenRenderedExcerpt: String?

    var text: DiagnosticRecord.Text
    var polishSeconds: Double?
    /// The prompt the user last sent to the joined agent, which the context
    /// carried. Only used to take it back out
    /// (`DiagnosticRecordRedaction.withholdPrompt`); never written.
    var withheldPrompt: String? = nil
    /// The joined session's unsent prompt draft, which the context carried.
    /// Taken back out like `withheldPrompt`; never written.
    var withheldDraft: ClaudePromptDraft? = nil

    /// Everything the record takes back out, the prompt first.
    var withheld: [DiagnosticRecordRedaction.Withheld] {
        [.priorPrompt(withheldPrompt), .draft(withheldDraft)].compactMap { $0 }
    }
}

extension DiagnosticRecordBuilder {
    /// The full record, minus timings the caller measures around this call.
    ///
    /// Two `.repository` budget candidates exist (terminal-cwd vocabulary and
    /// the joined session's repo), so `Source` rows carry their OWN names —
    /// `repoVocabulary` / `claudeRepo` — while `Allocation` keeps the four
    /// budget sources. Collapsing the two would make a repoVocabulary matcher
    /// miss unattributable against a claudeRepo retrieval miss.
    nonisolated static func build(
        id: String,
        capturedAt: Date,
        inputs: DiagnosticRecordInputs
    ) -> DiagnosticRecord {
        var sources: [DiagnosticRecord.Source] = []

        if inputs.repoVocabularyHarvest != nil || !inputs.repoVocabularyOutcome.entries.isEmpty {
            var row = source(SourceInputs(
                source: .repository,
                harvest: inputs.repoVocabularyHarvest ?? [],
                outcome: inputs.repoVocabularyOutcome,
                renderedExcerpt: nil
            ))
            row.source = "repoVocabulary"
            sources.append(row)
        }
        if inputs.claudeRepoSnapshot != nil {
            var row = source(SourceInputs(
                source: .repository,
                harvest: claudeRepoHarvest(inputs.claudeRepoSnapshot),
                outcome: inputs.claudeRepoOutcome,
                renderedExcerpt: inputs.claudeRepoRenderedExcerpt
            ))
            row.source = "claudeRepo"
            sources.append(row)
        }
        if let screenText = inputs.screenDecision.vocabularyGroundingText {
            sources.append(source(SourceInputs(
                source: .terminal,
                harvest: textSourceHarvest(
                    DiagnosticRecordRedaction.withholding(inputs.withheld, in: screenText, softWrapped: true)),
                outcome: inputs.screenOutcome,
                renderedExcerpt: inputs.screenRenderedExcerpt
            )))
        }
        if let claudeText = inputs.claudeSessionText, !claudeText.isEmpty {
            sources.append(source(SourceInputs(
                source: .claude,
                harvest: textSourceHarvest(
                    DiagnosticRecordRedaction.withholding(inputs.withheld, in: claudeText, softWrapped: false)),
                outcome: inputs.claudeSessionOutcome,
                renderedExcerpt: inputs.claudeSessionRenderedExcerpt
            )))
        }
        if let clipboardText = inputs.clipboardRetainedText {
            sources.append(source(SourceInputs(
                source: .clipboard,
                harvest: textSourceHarvest(
                    DiagnosticRecordRedaction.withholding(inputs.withheld, in: clipboardText, softWrapped: false)),
                outcome: inputs.clipboardOutcome,
                renderedExcerpt: inputs.clipboardRenderedExcerpt
            )))
        }

        var record = DiagnosticRecord(
            id: id,
            capturedAt: capturedAt,
            session: inputs.session,
            join: join(from: inputs.join, abstentions: inputs.joinAbstentions),
            screen: screen(
                from: inputs.screenDecision,
                targetBundleID: inputs.targetBundleID,
                socketPaneSwapApplied: inputs.socketPaneSwapApplied
            ),
            allocation: allocations(
                demands: inputs.demands,
                grants: inputs.grants,
                rendered: inputs.rendered
            ),
            sources: sources,
            text: inputs.text,
            timings: DiagnosticRecord.Timings(
                polishSeconds: inputs.polishSeconds,
                captureMilliseconds: nil
            )
        )
        for withheld in inputs.withheld {
            DiagnosticRecordRedaction.withhold(withheld, from: &record)
        }
        return record
    }
}
