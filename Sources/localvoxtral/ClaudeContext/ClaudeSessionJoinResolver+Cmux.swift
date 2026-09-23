import ClaudeContextWire
import CoreGraphics
import Foundation

extension ClaudeSessionJoinResolver {
    /// The cmux arm: bind the FOCUSED cmux surface to a live session by the
    /// surface id cmux itself injected into that session's environment.
    ///
    /// cmux mints `CMUX_SURFACE_ID` and puts it in the surface's process
    /// environment — and, through its own ssh relay, in the environment of a
    /// `cmux ssh` shell on another host. So the same id can come back to us from
    /// two different transports, and this arm accepts both:
    ///
    /// * LOCAL: the id arrived in `process` over the peer-UID-authenticated
    ///   AF_UNIX socket. Where both sides know a tty, they must agree — a free
    ///   cross-check that costs nothing and catches a stale environment.
    /// * REMOTE: the id arrived as an `X-Lvx-Env-*` header over the enrolled
    ///   host's authenticated channel. Nothing local is read for it; the join
    ///   only unlocks that session's own prompt/excerpts, and
    ///   `localWorkspacePath` still refuses to hand a remote cwd to the
    ///   filesystem. A compromised enrolled host could replay a surface id and
    ///   claim the focused pane — bounded by enrollment the user can revoke,
    ///   and additionally by the fresh remote-hosted evidence below.
    ///
    /// `CMUX_WORKSPACE_ID` is deliberately never consulted: cmux regenerates it
    /// when a workspace is restored, so a join keyed on it would silently start
    /// pointing at nothing after a relaunch.
    func resolveViaCmux(target: TerminalScreenTarget) async -> ClaudeSessionJoin? {
        guard cmuxJoinEnabled() else {
            Self.abstainedCmuxJoin(outcome: "cmux join not enabled")
            return nil
        }
        guard let cmuxSurfaces else {
            Self.abstainedCmuxJoin(outcome: "surface query capability unavailable")
            return nil
        }

        let surface: CmuxFocusedSurface
        // The peer the socket must turn out to be: the frontmost cmux process
        // this join is already about. The client refuses to send the stored
        // password to anything else.
        switch await cmuxSurfaces.focusedSurface(expectedPeerPID: target.pid) {
        case .value(let focused):
            surface = focused
        case .authenticationRequired:
            // The one failure the user can fix, so it is the one failure that
            // gets a sentence in Settings instead of only a log line.
            reportCmuxStatus(.authenticationRequired)
            Self.abstainedCmuxJoin(outcome: "socket requires password mode")
            return nil
        case .unavailable:
            reportCmuxStatus(.unavailable)
            Self.abstainedCmuxJoin(outcome: "focused surface unavailable")
            return nil
        }
        reportCmuxStatus(.ok)

        let local = registry.resolve(cmuxSurfaceID: surface.surfaceID)
        let remote = registry.resolveRemote(cmuxSurfaceID: surface.surfaceID)

        // EXACTLY ONE side may have a candidate at all, and it must be a clean
        // `.resolved` while the other is a clean `.unknown`.
        //
        // The earlier rule only rejected `.resolved`/`.resolved`, which made
        // ambiguity asymmetric: two local sessions claiming the surface
        // (`.ambiguous`) next to one remote claim would fall through and join
        // the REMOTE one, and the mirror image joined the local one. Ambiguity
        // on either side is the registry saying it cannot name the session, and
        // a claim from the other origin is not the tie-breaker — it is a
        // different machine answering a question about this surface.
        // `.stale` is treated the same way: a dead claimant on one side is
        // evidence the surface changed hands, which is exactly when the other
        // side's claim deserves the least trust.
        guard Self.isCleanlyResolved(local, other: remote)
            || Self.isCleanlyResolved(remote, other: local)
        else {
            Self.abstainedCmuxJoin(outcome: Self.cmuxOutcome(local: local, remote: remote))
            return nil
        }

        if case .resolved(let snapshot) = local {
            // Belt and braces, and REQUIRED on both sides: the surface's tty
            // and the session's must both be known and equal.
            //
            // Treating an absent tty as "no evidence, carry on" waived the
            // check precisely when it was needed — a process that inherited a
            // stale `CMUX_SURFACE_ID` and then moved to another pane publishes
            // no tty we can contradict, so id-alone would join it to whatever
            // surface now carries that id. Absent evidence is not permission.
            //
            // Cost, stated plainly: a session whose publisher reports no tty
            // cannot join over this arm. That is every opencode session (its
            // server half deliberately publishes no tty, because it cannot
            // prove it owns a pane), so opencode inside cmux gets no join at
            // all. A missed join costs an excerpt; a wrong one puts another
            // session's screen in this prompt.
            guard let sessionTTY = snapshot.process?.tty else {
                Self.abstainedCmuxJoin(outcome: "session published no tty to cross-check")
                return nil
            }
            guard let surfaceTTY = surface.tty else {
                Self.abstainedCmuxJoin(outcome: "cmux reported no tty for the focused surface")
                return nil
            }
            guard sessionTTY == surfaceTTY else {
                Self.abstainedCmuxJoin(outcome: "surface tty disagrees with the session's tty")
                return nil
            }
            Log.claudeContext.info(
                "Terminal pane joined to a live local Claude session via cmux surface"
            )
            return cmuxJoin(target: target, snapshot: snapshot, surface: surface)
        }

        if case .resolved(let snapshot) = remote {
            guard Self.remoteClaimIsCurrentlyHosted(surface: surface) else { return nil }
            Log.claudeContext.info(
                "Terminal pane joined to a live remote Claude session via cmux surface"
            )
            return cmuxJoin(target: target, snapshot: snapshot, surface: surface)
        }

        Self.abstainedCmuxJoin(outcome: Self.cmuxOutcome(local: local, remote: remote))
        return nil
    }

    /// Whether cmux says the focused surface is CURRENTLY hosted by a live
    /// remote workspace — the precondition for accepting any remote claim.
    ///
    /// Without it, a remote session's surface id is a REMEMBERED LABEL and
    /// nothing more: a compromised enrolled host can publish an id it saw
    /// during an earlier `cmux ssh` session, and once that surface has gone
    /// back to a local shell the replayed claim is the sole remote candidate
    /// and joins — pairing attacker-chosen context with whatever the user is
    /// now looking at.
    ///
    /// cmux exposes no remote-ness on the surface itself (a `cmux ssh` surface
    /// is an ordinary `type: "terminal"`; the state lives on the workspace), so
    /// the evidence comes from `workspace.remote.status` for the focused
    /// surface's own workspace, read in the same connection as the focus
    /// answer. Unknown fails closed.
    ///
    /// What this does NOT prove, stated plainly: that the remote session
    /// claiming the surface is the one on the other end of THAT ssh link. With
    /// two enrolled hosts, a compromised one can still claim a surface hosted
    /// by the other. It is bounded to genuinely-remote surfaces and to
    /// enrolled hosts.
    private static func remoteClaimIsCurrentlyHosted(surface: CmuxFocusedSurface) -> Bool {
        switch surface.workspaceIsRemote {
        case true:
            return true
        case false:
            abstainedCmuxJoin(
                outcome: "a remote session claims a surface cmux reports as local"
            )
            return false
        default:
            abstainedCmuxJoin(
                outcome: "cmux would not say whether the focused surface is remote-hosted"
            )
            return false
        }
    }

    /// One side resolved to exactly one session, and the other side had no
    /// candidate whatsoever.
    private static func isCleanlyResolved(
        _ resolution: ClaudeSessionResolution,
        other: ClaudeSessionResolution
    ) -> Bool {
        guard case .resolved = resolution else { return false }
        guard case .unknown = other else { return false }
        return true
    }

    private func cmuxJoin(
        target: TerminalScreenTarget,
        snapshot: ClaudeSessionSnapshot,
        surface: CmuxFocusedSurface
    ) -> ClaudeSessionJoin {
        ClaudeSessionJoin(
            target: target,
            snapshot: snapshot,
            windowID: focusedWindowID(target.pid),
            mechanism: .cmuxSurface,
            cmuxSurface: ClaudeCmuxSurfaceBinding(surfaceID: surface.surfaceID)
        )
    }

    /// Names WHICH side had nothing, so a hook that never published the surface
    /// id is distinguishable from an ambiguous registry — the herdr arm's
    /// silent abstention cost a field afternoon (2026-07-20).
    private static func cmuxOutcome(
        local: ClaudeSessionResolution,
        remote: ClaudeSessionResolution
    ) -> String {
        switch (local, remote) {
        case (.resolved, .resolved):
            return "a local and a remote session both claim this surface"
        case (.resolved, _), (_, .resolved):
            // One side named a session and the other side had SOMETHING —
            // ambiguous or stale. Named separately from plain ambiguity because
            // this is the case that used to join the resolved side.
            return "one origin resolved but the other also claims this surface"
        case (.ambiguous, _), (_, .ambiguous):
            return "focused surface matches several sessions"
        case (.stale, _), (_, .stale):
            return "focused surface session stale"
        default:
            return "focused surface has no live session"
        }
    }

    /// The joined cmux surface's visible text, or nil on any refusal or failure.
    ///
    /// The mirror of `herdrPaneVisibleText(for:)`, and the ONLY path that issues
    /// a `surface.read_text`: the request is keyed by the binding the cmux arm
    /// captured at resolution, so no other surface — and no other join
    /// mechanism — can reach cmux's socket through it. Returns RAW wire text;
    /// the caller owns sanitization, bounding, and every consent gate.
    func cmuxSurfaceVisibleText(for join: ClaudeSessionJoin) async -> String? {
        guard join.mechanism == .cmuxSurface, let binding = join.cmuxSurface else {
            Log.claudeContext.info("cmux surface read refused: join is not a cmux surface join")
            return nil
        }
        guard cmuxJoinEnabled() else {
            Log.claudeContext.info("cmux surface read refused: cmux join not enabled")
            return nil
        }
        guard let cmuxSurfaces else {
            Log.claudeContext.info("cmux surface read refused: surface query capability unavailable")
            return nil
        }
        switch await cmuxSurfaces.surfaceText(
            surfaceID: binding.surfaceID, expectedPeerPID: join.target.pid
        ) {
        case .value(let text):
            return text
        case .authenticationRequired:
            reportCmuxStatus(.authenticationRequired)
            Log.claudeContext.info("cmux surface read refused: socket requires password mode")
            return nil
        case .unavailable:
            Log.claudeContext.info("cmux surface read failed: surface text unavailable")
            return nil
        }
    }

    /// Outcome only: surface ids and surface text are live join material and
    /// never belong in the unified log.
    private static func abstainedCmuxJoin(outcome: String) {
        Log.claudeContext.info(
            "cmux surface matched no session (\(outcome, privacy: .public))"
        )
        Self.noteAbstention("cmux: \(outcome)")
    }
}
