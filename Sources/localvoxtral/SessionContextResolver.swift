import Foundation

/// The context a dictation carries from start to commit: the terminal screen
/// as it looked when the user began speaking, the Claude Code session the
/// focused pane joined, that pane's socket sample, and the leases on any
/// remote herdr tunnel the join opened. Owned by `DictationViewModel` and
/// reached as `viewModel.context`; captured at session start, decided and
/// consumed at commit, discarded on every other exit.
///
/// Every gate here is what keeps repository contents, prior prompts and
/// screen text away from an endpoint the user has not consented to. Read
/// docs/agent/invariants.md ("Claude Code context reaches the prompt only
/// through a positive join") before changing any of it.
@MainActor
final class SessionContextResolver {
    let settings: SettingsStore
    let textInsertion: TextInsertionService

    /// The Ghostty screen as it looked when the user started speaking, sampled
    /// at session start before the overlay can take focus. Nil whenever the
    /// opt-in gate rejected (setting off, remote endpoint, non-Ghostty app,
    /// no Accessibility trust), in which case no AX call was made at all.
    /// Consumed at commit by `terminalScreenContextDecision()`.
    var terminalScreenStartCapture: TerminalScreenCapture?

    /// Resolves the focused pane to a live Claude Code session. Installed by
    /// `AppDelegate` once the broker is actually listening, and nil otherwise,
    /// so a build where broker startup failed simply never joins.
    var claudeSessionJoinResolver: ClaudeSessionJoinResolver?

    /// THE session join for the current dictation, resolved once at start.
    /// Read by three consumers (raw screen attachment, the session block,
    /// repository collection), which is why it is stored rather than
    /// re-derived: they must all describe the same session. Nil whenever the
    /// pane did not positively join. Cleared on every session exit.
    var claudeSessionJoin: ClaudeSessionJoin?
    /// Panel indicators own their associated remote forward until an explicit
    /// token clear has completed, so teardown cannot close the tunnel before
    /// the clear request reaches herdr.
    var liveRemoteHerdrIndicators: [HerdrPanelMicIndicator] = []
    /// Remote herdr `ssh -L` leases this dictation has open. See
    /// `retainRemoteHerdrForward(of:)` for why they are owned here and not by
    /// the join that travels.
    private var liveRemoteHerdrForwards: [ClaudeRemoteHerdrForwardHandle] = []

    /// The JOINED pane's visible text at dictation start, read over its own
    /// multiplexer socket. Non-nil only for a socket-routed pane join with the
    /// screen-context consent gate cleared at start. At commit it replaces the
    /// AX screen decision; cleared on every session exit.
    var socketPaneStartCapture: SocketPaneScreenCapture?

    /// Collects the joined Claude session's repository. A stored property so
    /// tests drive the whole commit path against an in-memory tree.
    var claudeRepoCollector: any ClaudeRepoCollecting = ClaudeRepoCollector()

    /// Where the per-dictation join line goes. A stored property so tests read
    /// the line without the unified log.
    var joinOutcomeLog: @MainActor (String) -> Void = { line in
        Log.claudeContext.notice("Claude join outcome: \(line, privacy: .public)")
    }

    init(settings: SettingsStore, textInsertion: TextInsertionService) {
        self.settings = settings
        self.textInsertion = textInsertion
    }

    /// Samples the focused terminal's screen for polish grounding (Ghostty
    /// over AX, iTerm2/Terminal.app over AppleScript contents), at the same
    /// moment and
    /// for the same reason as the verdict above: this is the last point where
    /// the app the user is dictating INTO is reliably frontmost. The target is
    /// resolved independently of the overlay (see
    /// `TerminalScreenContextSource.frontmostTarget`).
    ///
    /// Every privacy gate is evaluated inside the source before any AX or
    /// AppleScript call, so
    /// an opted-out user, a remote polishing endpoint, or an unlisted app
    /// means the screen is never read. A nil polishing configuration also means
    /// no read: with no endpoint there is nothing to ground for.
    func captureAtStart() async -> OverlayClaudeJoinBadge {
        #if LOCALVOXTRAL_DOGFOOD
        // A fresh dictation gets fresh tap slots: an abandoned pipeline's late
        // note from the PREVIOUS session must not describe this one. (The
        // owner supersedes its post-commit edit watch before calling here.)
        DogfoodCaptureTap.shared.beginSession()
        #endif
        guard let endpointURL = settings.llmPolishingConfiguration?.endpointURL else {
            terminalScreenStartCapture = nil
            claudeSessionJoin = nil
            socketPaneStartCapture = nil
            // No endpoint means the join is never consumed by anything, so
            // there is no grounding to report on either way. Saying "no Claude
            // session" here would be true and useless — nothing would have used
            // one.
            noteJoinOutcome(.gated(.noPolishingEndpoint), causes: [])
            return .hidden
        }
        terminalScreenStartCapture = TerminalScreenContextSource.captureAtStart(
            settingEnabled: settings.terminalScreenContextEnabled,
            endpointURL: endpointURL,
            isAccessibilityTrusted: textInsertion.isAccessibilityTrusted,
            trustedEndpointEnabled: settings.polishContextTrustedEndpointEnabled
        )
        // The resolver's abstention causes are collected HERE, around the one
        // resolution, because it reduces each of them to a log line and a nil;
        // after it returns, nothing else can say why.
        let (attempt, causes) = await ClaudeJoinAbstentionTap.collecting {
            await resolveClaudeSessionJoin(endpointURL: endpointURL)
        }
        claudeSessionJoin = attempt.join
        noteJoinOutcome(attempt, causes: causes)
        // Ownership of the join's `ssh -L` is taken HERE, at the one place a
        // join is ever assigned, and never given back to whoever happens to
        // hold the join later. The commit path CONSUMES the join, so an owner
        // that reached the child only through `claudeSessionJoin` was nil at
        // exactly the moments it mattered — quit during polish, an aborted
        // connect — and the ssh outlived the app (review finding 4).
        retainRemoteHerdrForward(of: claudeSessionJoin)
        // Read from the ONE resolved join, never by asking again. The badge is
        // a description of `claudeSessionJoin`, so it cannot disagree with the
        // context that actually ships.
        let badge = OverlayClaudeJoinBadge.resolve(
            attempt: attempt,
            liveSessionsExist: { [claudeSessionJoinResolver] in
                claudeSessionJoinResolver?.hasLiveSessions() ?? false
            }
        )
        // Only a socket-routed pane join — herdr, remote herdr, or cmux —
        // produces a sample here (the function refuses everything else before
        // any socket request), and it reads exactly the joined pane. Fetched at
        // start for the same reason the AX screen is:
        // this text is evidence of what the user could see while choosing
        // their words, and only a start sample can be that.
        socketPaneStartCapture = await SocketPaneScreenContext.captureAtStart(
            join: claudeSessionJoin,
            resolver: claudeSessionJoinResolver,
            settingEnabled: settings.terminalScreenContextEnabled,
            endpointURL: endpointURL,
            isAccessibilityTrusted: textInsertion.isAccessibilityTrusted,
            trustedEndpointEnabled: settings.polishContextTrustedEndpointEnabled
        )
        return badge
    }

    /// Resolves this dictation's Claude session join, ONCE, here at start.
    ///
    /// Start, not commit, for the same reason the screen is sampled here: this
    /// is the last moment the app the user is dictating INTO is reliably
    /// frontmost, and by commit time the frontmost app may be our own overlay.
    /// It also means the join describes the pane the user was looking at while
    /// choosing their words, which is the only pane whose context is evidence of
    /// what they meant.
    ///
    /// Every gate is checked BEFORE the resolver is asked, because asking is not
    /// passive: it sends an Apple event to the terminal for the focused pane's
    /// TTY, walks the local process table, and may dial a multiplexer socket or
    /// open an `ssh -L`. (It reads no window title — no join has since #250.)
    /// An opted-out user, a remote endpoint, or a revoked Accessibility grant
    /// means none of that happens.
    private func resolveClaudeSessionJoin(endpointURL: URL) async -> ClaudeJoinAttempt {
        guard let resolver = claudeSessionJoinResolver else {
            return .gated(.noResolver)
        }
        // Either context feature can want a join: the screen needs it to
        // authorize a raw excerpt, the repo/session blocks ARE the join's
        // content. Neither being enabled means there is nothing to resolve for.
        guard settings.terminalScreenContextEnabled || settings.claudeRepoContextEnabled else {
            return .gated(.contextSettingsOff)
        }
        // Permitted endpoints only (loopback, or any endpoint under the
        // explicit trusted-endpoint opt-in). Repository contents and a prior
        // prompt must never ride to an endpoint the user has not consented to,
        // and this is the gate that guarantees no filesystem read even STARTS
        // for one — the collector is downstream of the join, so an unresolved
        // join means no git subprocess, no file read.
        guard PolishContextClipboardReader.isPermittedContextEndpoint(
            endpointURL,
            trustedEndpointEnabled: settings.polishContextTrustedEndpointEnabled
        ) else {
            return .gated(.endpointNotPermitted)
        }
        guard textInsertion.isAccessibilityTrusted else {
            return .gated(.accessibilityNotTrusted)
        }
        guard let target = TerminalScreenContextSource.frontmostTarget() else {
            return .gated(.noFrontmostTarget)
        }
        // The browser entry path. `frontmostTarget()` answers for ANY app and
        // the resolver owns the allowlists, so a browser reaches the resolver
        // through the same one call a terminal does — except for this gate: a
        // browser join can only ever produce the session/repo blocks (the
        // authorizer refuses `.browserTab` raw attachment outright), so the
        // screen-context setting alone must not send an Apple event to the
        // user's browser, nor raise its Automation consent sheet.
        if BrowserTabAllowlist.isSupported(target.bundleID),
           !settings.claudeRepoContextEnabled {
            return .gated(.browserWithoutSessionContext)
        }
        // Claude Desktop, on the same terms: its join authorizes no screen
        // either, so the screen setting alone must not read another app's
        // accessibility tree (or switch Electron's tree on to do it).
        if ClaudeDesktopAllowlist.isSupported(target.bundleID),
           !settings.claudeRepoContextEnabled {
            return .gated(.desktopWithoutSessionContext)
        }
        return .resolved(await resolver.resolution(target: target))
    }

    /// Writes this dictation's ONE persisted join line: the arm that joined,
    /// or the gate or abstention chain that stopped it. `.notice`, because
    /// the unified log keeps no `.info` line past the moment, and a join is
    /// only ever questioned after the dictation. Categories only — the same
    /// `ClaudeSessionJoinSummary` a dogfood record and `--probe-surface`
    /// print, which carries no id, path, host or address.
    private func noteJoinOutcome(_ attempt: ClaudeJoinAttempt, causes: [String]) {
        var causes = causes
        if case .gated(let gate) = attempt {
            causes.append(gate.rawValue)
            #if LOCALVOXTRAL_DOGFOOD
            DogfoodCaptureTap.shared.noteJoinAbstention(gate.rawValue)
            #endif
        }
        let summary = ClaudeSessionJoinSummary.summarize(join: attempt.join, abstentions: causes)
        joinOutcomeLog(summary.noticeText)
        #if LOCALVOXTRAL_DOGFOOD
        // Snapshotted HERE, at the single resolution, because the commit path
        // consumes both the join and the tap's abstention causes — by the time
        // anything could ask afterwards, neither exists. Recorded for a gated
        // dictation too: `join report` answering with the PREVIOUS dictation's
        // join would be the worst possible answer — a stale arm name for a
        // dictation that never resolved one.
        dogfoodNoteResolvedJoin(attempt.join)
        #endif
    }

    /// Drops any retained screen capture. Idempotent, and safe to call on a
    /// path that already consumed it. Screen text must not outlive the session
    /// that captured it: every exit — cancel, connect abort, an early return in
    /// the commit path — funnels here or through
    /// `terminalScreenContextDecision(endpointURL:)`, and session start
    /// reassigns the property unconditionally as a backstop.
    func discardTerminalScreenCapture() {
        terminalScreenStartCapture = nil
        // The join goes with it. It names a session and a pane that belong to
        // the session being abandoned, and a stale join surviving into the next
        // dictation is precisely how the wrong repo's context would get
        // attached to an unrelated sentence.
        //
        claudeSessionJoin = nil
        // And the pane text with the join: it is that session's screen.
        socketPaneStartCapture = nil
        // Every `ssh -L` lease, not just this join's — abandoning a dictation
        // cannot pin a persistent forward as actively used.
        closeRemoteHerdrForwards()
    }

    /// Takes ownership of a join's remote herdr tunnel, if it has one.
    ///
    /// One owner, deliberately: the join object travels (it is consumed by the
    /// commit path and captured into a Task), and a resource whose owner is
    /// "whoever currently holds the value" has no owner at all.
    func retainRemoteHerdrForward(of join: ClaudeSessionJoin?) {
        if let indicator = join?.remoteHerdrIndicator {
            liveRemoteHerdrIndicators.append(indicator)
            indicator.start()
            return
        }
        guard let forward = join?.remoteHerdrForward else { return }
        liveRemoteHerdrForwards.append(forward)
    }

    /// Releases every remote herdr lease. Idempotent, and safe from any path —
    /// including ones that never knew a tunnel existed.
    ///
    /// Called from every dictation exit (`discardTerminalScreenCapture`, the
    /// commit path once the stop-side pane read is done, `abortConnectingSession`)
    /// and from `applicationWillTerminate`. Closing ALL of them rather than one
    /// is what makes a leaked handle from some path nobody thought of
    /// self-healing at the next exit.
    func closeRemoteHerdrForwards() {
        let indicators = liveRemoteHerdrIndicators
        liveRemoteHerdrIndicators = []
        for indicator in indicators { indicator.stop() }

        guard !liveRemoteHerdrForwards.isEmpty else { return }
        let forwards = liveRemoteHerdrForwards
        liveRemoteHerdrForwards = []
        for forward in forwards { forward.close() }
    }

    /// Test seam: how many tunnels this view model is holding open.
    var openRemoteHerdrForwardCount: Int {
        liveRemoteHerdrForwards.count + liveRemoteHerdrIndicators.count
    }

    /// Reconciles the start capture against a stop-time re-read of the SAME
    /// PID/bundle and clears it. See `TerminalScreenContext.reconcile` for the
    /// truth table. Returns `.drop(.noStartCapture)` when nothing was captured,
    /// which is also what makes stop-only context unrepresentable.
    func terminalScreenContextDecision(endpointURL: URL) -> TerminalScreenContextDecision {
        let start = terminalScreenStartCapture
        terminalScreenStartCapture = nil
        return TerminalScreenContextSource.reconcileAtStop(
            start: start,
            settingEnabled: settings.terminalScreenContextEnabled,
            endpointURL: endpointURL,
            isAccessibilityTrusted: textInsertion.isAccessibilityTrusted,
            trustedEndpointEnabled: settings.polishContextTrustedEndpointEnabled
        )
    }

    /// Takes this dictation's join and clears it.
    ///
    /// MUST be called after `terminalScreenContextDecision`, which is what asks
    /// the authorizer about the join. Consuming first would clear it out from
    /// under that call and silently withdraw every raw screen attachment.
    func consumeClaudeSessionJoin() -> ClaudeSessionJoin? {
        let join = claudeSessionJoin
        claudeSessionJoin = nil
        return join
    }

    /// Takes this dictation's socket pane start sample and clears it. Consumed
    /// alongside the join at commit; a sample must never survive into another
    /// session's reconciliation.
    func consumeSocketPaneStartCapture() -> SocketPaneScreenCapture? {
        let capture = socketPaneStartCapture
        socketPaneStartCapture = nil
        return capture
    }

    /// The repository snapshot for `join`, or nil when any gate rejects.
    ///
    /// Re-checks the FULL gate rather than trusting the start-time resolution,
    /// because consent can be withdrawn mid-session: the user can toggle the
    /// setting off or repoint the endpoint while they are speaking, and either
    /// is a withdrawal that must land before a single file is read. The order
    /// here is the point — every cheap, local check runs before the collector is
    /// reached, so "no join ⇒ no filesystem call" and "setting off ⇒ no
    /// filesystem call" are properties of the control flow, not of the
    /// collector's manners.
    func claudeRepoSnapshotIfEnabled(
        join: ClaudeSessionJoin?,
        endpointURL: URL,
        transcript: String
    ) async -> ClaudeRepoSnapshot? {
        guard settings.claudeRepoContextEnabled else { return nil }
        guard PolishContextClipboardReader.isPermittedContextEndpoint(
            endpointURL,
            trustedEndpointEnabled: settings.polishContextTrustedEndpointEnabled
        ) else {
            Log.claudeContext.info(
                "Claude repo context skipped: polishing endpoint is not permitted (loopback-only without the trusted-endpoint opt-in)"
            )
            return nil
        }
        guard let join else { return nil }
        guard let resolver = claudeSessionJoinResolver, resolver.isStillLive(join) else {
            Log.claudeContext.info("Claude repo context skipped: session no longer live")
            return nil
        }
        // The type is the gate. A remote session has no `localWorkspacePath` to
        // hand the collector — not because this checks the origin, but because
        // `ClaudeWorkspaceReference.make` never built a `LocalWorkspacePath` for
        // one. There is nothing here to get wrong.
        guard let workspace = join.localWorkspacePath else {
            Log.claudeContext.info("Claude repo context skipped: session workspace is not local")
            return nil
        }
        return await claudeRepoCollector.collect(
            workspace: workspace,
            // `localRecentFiles`, not `recentFiles`: the collector opens these
            // paths. The workspace gate above already proves this session is
            // local, so today the two are the same array — but the accessor is
            // the documented gate for per-file paths (which are plain strings on
            // the wire, unlike the cwd, which the type system covers), and a
            // consumer that touches the filesystem must read it from there. Not
            // a behavior change; a change to which invariant is load-bearing.
            recentFiles: join.snapshot.localRecentFiles,
            transcript: transcript
        )
    }

    /// The Claude session block's text, re-gated at commit exactly like
    /// `claudeRepoSnapshotIfEnabled` — current setting, currently permitted
    /// endpoint, this exact join still live.
    ///
    /// The same three gates because it carries the same kind of thing: the
    /// session's workspace name, the PRIOR PROMPT the user typed to the agent,
    /// the paths it touched, and (remote only) bounded tool excerpts. That is
    /// the session's content, which is what the setting consents to and what a
    /// unpermitted endpoint must never receive. The block previously checked
    /// only the setting, so a session that died mid-sentence still had its
    /// prompt attached, and a Settings change to a remote endpoint sent it
    /// there.
    ///
    /// There is deliberately no LOCAL-workspace gate, which is the one place
    /// this diverges from the repo collector: that gate exists because the
    /// collector opens files, and this opens nothing. A remote session's
    /// off-screen facts are exactly what this block is for.
    ///
    /// Returns "" rather than a snapshot on purpose. "" produces no
    /// preparation, which withholds the GROUNDING as well as the rendered
    /// block — a gate that suppressed only the excerpt would still let the
    /// prior prompt's words reach the model as replacement entries.
    func claudeSessionTextIfEnabled(join: ClaudeSessionJoin?, endpointURL: URL) -> String {
        guard settings.claudeRepoContextEnabled else { return "" }
        guard PolishContextClipboardReader.isPermittedContextEndpoint(
            endpointURL,
            trustedEndpointEnabled: settings.polishContextTrustedEndpointEnabled
        ) else {
            Log.claudeContext.info(
                "Claude session context skipped: polishing endpoint is not permitted (loopback-only without the trusted-endpoint opt-in)"
            )
            return ""
        }
        guard let join else { return "" }
        guard let resolver = claudeSessionJoinResolver, resolver.isStillLive(join) else {
            Log.claudeContext.info("Claude session context skipped: session no longer live")
            return ""
        }
        return ClaudeSessionContextText.text(for: join.snapshot)
    }
}

#if LOCALVOXTRAL_DOGFOOD
extension SessionContextResolver {
    /// Snapshot the resolved join for `join report`, with the abstention chain
    /// as it stands at resolution time, gate included.
    func dogfoodNoteResolvedJoin(_ join: ClaudeSessionJoin?) {
        DogfoodCaptureTap.shared.noteResolvedJoin(
            ClaudeSessionJoinSummary.summarize(
                join: join,
                abstentions: DogfoodCaptureTap.shared.peekJoinAbstentions()
            )
        )
    }
}
#endif

/// Why a dictation's join never reached the resolver. The raw value is the
/// cause the outcome line and the dogfood record carry: a category, never a
/// path, host, address or id.
enum ClaudeJoinGate: String, Equatable, Sendable {
    case noPolishingEndpoint = "gate: no polishing endpoint"
    case noResolver = "gate: no resolver installed"
    case contextSettingsOff = "gate: both context settings off"
    case endpointNotPermitted = "gate: endpoint not permitted"
    case accessibilityNotTrusted = "gate: accessibility not trusted"
    case noFrontmostTarget = "gate: no frontmost supported terminal"
    case browserWithoutSessionContext = "gate: browser target without session context"
    case desktopWithoutSessionContext = "gate: Claude Desktop target without session context"
}

/// How far one dictation's join got: stopped by a gate before the resolver
/// was asked, or answered by it.
enum ClaudeJoinAttempt: Equatable, Sendable {
    case gated(ClaudeJoinGate)
    case resolved(ClaudeJoinResolution)

    var join: ClaudeSessionJoin? {
        guard case .resolved(let resolution) = self else { return nil }
        return resolution.join
    }
}
