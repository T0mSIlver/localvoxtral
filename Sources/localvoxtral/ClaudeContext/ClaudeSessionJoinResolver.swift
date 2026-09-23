import ClaudeContextWire
import CoreGraphics
import Foundation

/// Resolves the focused pane to a live Claude session, and authorizes raw
/// screen attachment only when that join is unambiguous.
///
/// This is the positive gate `TerminalScreenRawAttachmentPolicy` was written to
/// wait for. Every arm below is the same shape, and the shape is what makes it
/// a gate rather than a guess:
///
/// 1. A session was authenticated by its TRANSPORT — peer credentials for a
///    local one (`ClaudeTransportOrigin`), an enrolled host's token for a
///    remote one — so a candidate existing at all means someone we trust
///    reported it.
/// 2. That session's own hooks published a HANDLE to where it lives: a
///    controlling TTY, a herdr pane id, a cmux surface id, a Remote Control
///    bridge session id.
/// 3. We read the SAME KIND of handle off the surface the user is actually
///    looking at, from the PID we captured — never system-wide focus.
/// 4. The two are compared for exact equality, and the registry still resolves
///    the match to ONE live session.
///
/// Every link abstains rather than guesses, because the failure modes are not
/// symmetric: a wrong `true` renders an unrelated terminal's scrollback into
/// someone's prompt, while a wrong `false` costs only an excerpt whose terms the
/// vocabulary matcher already extracted. So a surface that publishes no handle
/// we can read (a plain shell, an editor, a terminal the user opened
/// themselves) joins nothing, and so does `unknown`, `stale` (past TTL, or the
/// agent process is gone) or `ambiguous` (more than one live session matches).
///
/// Note what is NOT here: any inference from the cwd, the window title, or
/// "there is only one live session so it must be that one". No window title is
/// read for a join at all — it is a fought-over channel that every party in the
/// stack rewrites. A sole-session heuristic is wrong precisely when it matters
/// — the user has one Claude session open and is dictating into an unrelated
/// shell — and it would attach that session's repo to a prompt that has nothing
/// to do with it.
@MainActor
struct ClaudeSessionJoinResolver {
    let registry: ClaudeSessionRegistry
    private let focusedTerminalTTY: (String) async -> String?
    let focusedBrowserTabURL: (String) async -> String?
    let focusedDesktopSessionURL: (pid_t) async -> String?
    let focusedWindowID: (pid_t) -> CGWindowID?
    private let herdrClientProbe: @Sendable (String) -> Bool
    let herdrFederation: @Sendable () -> HerdrMachineFederation
    let herdrClientSurfaceCount: @Sendable () -> Int?
    let herdrPanes: HerdrPaneQuerying?
    let cmuxSurfaces: CmuxSurfaceQuerying?
    let cmuxJoinEnabled: @MainActor () -> Bool
    let reportCmuxStatus: @MainActor (CmuxSocketStatus) -> Void
    private let sshDestinationProbe: @Sendable (String) -> SSHDestinationTTYProbeResult
    let enrolledHosts: @MainActor (String) -> [ClaudeRemoteHost]
    let canonicalizedEnrolledHosts: @MainActor (String) async -> [ClaudeRemoteHost]
    let proxyJumpShape: @MainActor (String) async -> SSHProxyJumpShape?
    let speculativeHosts: @MainActor () -> [ClaudeRemoteHost]
    let remoteHerdrForwards: (any ClaudeRemoteHerdrForwarding)?
    let herdrPanelMetadata: (any HerdrPanelMetadataReporting)?
    let readFocusedGrid: HerdrPanelBindingProbe.GridRead
    let panelNow: HerdrPanelBindingProbe.Now
    let panelSleepFor: HerdrPanelBindingProbe.SleepFor
    let panelRandomBits: HerdrPanelBindingProbe.RandomBits
    let indicatorSleepFor: HerdrPanelMicIndicator.SleepFor
    let reportPanelStatus: @MainActor (HerdrPanelConfigurationStatus) -> Void

    /// - Parameters:
    ///   - focusedTerminalTTY: reads the focused pane's controlling TTY for a
    ///     bundle id over AppleScript (Ghostty ≥ 1.4's focused terminal,
    ///     iTerm2's current session, Terminal.app's selected tab). Unlike the
    ///     AX seam this
    ///     DEFAULTS TO ABSTAIN, not to the live reader: an Apple event is not
    ///     an AX read — the first one triggers the Automation consent prompt,
    ///     and a defaulted live reader would send real events (and hang the
    ///     suite on that prompt) from any test that forgets to inject. The app
    ///     wires `AppleScriptTerminalTTYReader` explicitly.
    ///   - focusedBrowserTabURL: reads the focused window's active-tab URL for
    ///     an allowlisted browser over AppleScript. DEFAULTS TO ABSTAIN for the
    ///     same reason `focusedTerminalTTY` does — it sends a real Apple event
    ///     and can raise the Automation consent sheet — and additionally
    ///     because a browser tab URL is user CONTENT: no test may reach the
    ///     live reader by forgetting an injection. The app wires
    ///     `AppleScriptFocusedBrowserTabURLReader` explicitly.
    ///   - focusedDesktopSessionURL: reads the address of the Claude Desktop
    ///     web view holding keyboard focus, for that app's pid. DEFAULTS TO
    ///     ABSTAIN: it is an Accessibility read of another process and flips
    ///     Electron's accessibility tree on, so no test may reach the live
    ///     reader by forgetting an injection. The app wires
    ///     `AXClaudeDesktopSessionURLReader` explicitly.
    ///   - focusedWindowID: the join's window identity, from its own
    ///     PID-pinned AX read. It exists to pair a screen capture with the
    ///     join that authorized it; nil means unknown, which the authorizer
    ///     refuses rather than treats as a match (review F2).
    ///   - herdrClientProbe: reads the local process table to bind the focused
    ///     Ghostty surface to a herdr client. It DEFAULTS TO ABSTAIN: a test
    ///     that forgets to inject must never consult the live process table.
    ///     The app wires the live probe explicitly.
    ///   - herdrFederation: reads herdr's saved-machine state, which decides
    ///     whether the local socket's focused pane still describes what the
    ///     surface displays (issue #286). It defaults to `.notFederated`, the
    ///     state of every herdr before 0.9 and of every 0.9 user who saved no
    ///     machine, so a test that does not care about federation keeps the
    ///     pre-0.9 arm. The two abstaining values are what a test injects.
    ///   - herdrClientSurfaceCount: how many surfaces this user has a herdr
    ///     client on, consulted only once machines are saved. DEFAULTS TO
    ///     ABSTAIN (nil, unknown) so a federated case cannot silently pass by
    ///     reaching the live process table.
    ///   - herdrPanes: queries herdr's local JSON socket after that surface
    ///     binding succeeds. It likewise DEFAULTS TO ABSTAIN so a test that
    ///     forgets to inject cannot connect to a real user socket. The app is
    ///     the only place that installs the live client.
    ///   - cmuxSurfaces: queries cmux's control socket for the focused surface
    ///     and its text. DEFAULTS TO ABSTAIN (nil) for the same reason as
    ///     `herdrPanes`: no test may dial a real user's socket.
    ///   - cmuxJoinEnabled: the user's cmux opt-in, read live so turning the
    ///     toggle off stops the next dictation from dialing. DEFAULTS TO
    ///     ABSTAIN — a second, independent reason a forgetful test cannot reach
    ///     that socket.
    ///   - reportCmuxStatus: one short sentence for the Settings row when the
    ///     socket refuses us (details go to the log, never the popover).
    ///   - sshDestinationProbe: reads the local process table for an ssh client
    ///     on the focused surface's TTY and reports where it is going. Defaults
    ///     to `.undeterminable`, which disables the remote herdr arm entirely
    ///     — an un-injected resolver behaves exactly as it did before that arm
    ///     existed.
    ///   - enrolledHosts: the enrolled remote hosts whose ssh alias IS that
    ///     destination. Defaults to none, for the same reason: no enrollment
    ///     lookup, no remote arm. Passed as a closure rather than the registry
    ///     because the host list is built later in launch than this resolver.
    ///   - canonicalizedEnrolledHosts: the `ssh -G` fallback, consulted only
    ///     when exact alias matching found nothing. Defaults to none so a test
    ///     that forgets to inject never spawns a process.
    ///   - remoteHerdrForwards: opens the app-managed `ssh -L`. Nil means the
    ///     arm can never spawn anything, which is what a test that forgets to
    ///     inject must get.
    init(
        registry: ClaudeSessionRegistry,
        focusedTerminalTTY: @escaping (String) async -> String? = { _ in nil },
        focusedBrowserTabURL: @escaping (String) async -> String? = { _ in nil },
        focusedDesktopSessionURL: @escaping (pid_t) async -> String? = { _ in nil },
        focusedWindowID: @escaping (pid_t) -> CGWindowID? = {
            TerminalScreenAXReader.focusedWindowIdentity(applicationPID: $0)
        },
        herdrClientProbe: @escaping @Sendable (String) -> Bool = { _ in false },
        herdrFederation: @escaping @Sendable () -> HerdrMachineFederation = { .notFederated },
        herdrClientSurfaceCount: @escaping @Sendable () -> Int? = { nil },
        herdrPanes: HerdrPaneQuerying? = nil,
        cmuxSurfaces: CmuxSurfaceQuerying? = nil,
        cmuxJoinEnabled: @escaping @MainActor () -> Bool = { false },
        reportCmuxStatus: @escaping @MainActor (CmuxSocketStatus) -> Void = { _ in },
        sshDestinationProbe: @escaping @Sendable (String) -> SSHDestinationTTYProbeResult = { _ in
            .undeterminable(.probeUnavailable)
        },
        enrolledHosts: @escaping @MainActor (String) -> [ClaudeRemoteHost] = { _ in [] },
        canonicalizedEnrolledHosts: @escaping @MainActor (String) async -> [ClaudeRemoteHost] = {
            _ in []
        },
        proxyJumpShape: @escaping @MainActor (String) async -> SSHProxyJumpShape? = { _ in nil },
        speculativeHosts: @escaping @MainActor () -> [ClaudeRemoteHost] = { [] },
        remoteHerdrForwards: (any ClaudeRemoteHerdrForwarding)? = nil,
        herdrPanelMetadata: (any HerdrPanelMetadataReporting)? = nil,
        readFocusedGrid: @escaping HerdrPanelBindingProbe.GridRead = { _ in nil },
        panelNow: @escaping HerdrPanelBindingProbe.Now = Date.init,
        panelSleepFor: @escaping HerdrPanelBindingProbe.SleepFor = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        panelRandomBits: @escaping HerdrPanelBindingProbe.RandomBits = {
            var generator = SystemRandomNumberGenerator()
            return generator.next()
        },
        indicatorSleepFor: @escaping HerdrPanelMicIndicator.SleepFor = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        reportPanelStatus: @escaping @MainActor (HerdrPanelConfigurationStatus) -> Void = { _ in }
    ) {
        self.registry = registry
        self.focusedTerminalTTY = focusedTerminalTTY
        self.focusedBrowserTabURL = focusedBrowserTabURL
        self.focusedDesktopSessionURL = focusedDesktopSessionURL
        self.focusedWindowID = focusedWindowID
        self.herdrClientProbe = herdrClientProbe
        self.herdrFederation = herdrFederation
        self.herdrClientSurfaceCount = herdrClientSurfaceCount
        self.herdrPanes = herdrPanes
        self.cmuxSurfaces = cmuxSurfaces
        self.cmuxJoinEnabled = cmuxJoinEnabled
        self.reportCmuxStatus = reportCmuxStatus
        self.sshDestinationProbe = sshDestinationProbe
        self.enrolledHosts = enrolledHosts
        self.canonicalizedEnrolledHosts = canonicalizedEnrolledHosts
        self.proxyJumpShape = proxyJumpShape
        self.speculativeHosts = speculativeHosts
        self.remoteHerdrForwards = remoteHerdrForwards
        self.herdrPanelMetadata = herdrPanelMetadata
        self.readFocusedGrid = readFocusedGrid
        self.panelNow = panelNow
        self.panelSleepFor = panelSleepFor
        self.panelRandomBits = panelRandomBits
        self.indicatorSleepFor = indicatorSleepFor
        self.reportPanelStatus = reportPanelStatus
    }

    /// The join for `target`, or nil on any abstention.
    ///
    /// TTY first, then — on that same surface TTY — herdr when a herdr client
    /// holds it, and otherwise the remote-herdr arm. The TTY arm compares the
    /// focused pane's device against what the hook publisher reported from
    /// inside the session; the process table cannot be clobbered by whoever
    /// wrote the window title last, which is exactly why it, and not a title,
    /// is the primary evidence. A TTY non-answer does not fall through to some
    /// weaker reading of the same surface — there is no such reading — so the
    /// arms below it are the ones that ask a DIFFERENT question (an inner
    /// herdr pane, a cmux surface, a browser tab), and when none of them
    /// answers, the dictation gets no join.
    ///
    /// LOCAL sessions only, for every terminal arm: a remote session's TTY,
    /// pane id, or surface id names something on another machine, and
    /// `resolve(tty:)` refuses remote candidates outright so an SSH host can
    /// never claim a local pane by echoing its device. A remote session joins
    /// only through an arm that proves the remote binding itself — the
    /// remote-herdr pane arm, `cmux ssh`'s round-tripped surface id, or the
    /// bridge-allocated Remote Control session id.
    ///
    /// Whether the registry currently holds ANY live session.
    ///
    /// Not a join and not a step toward one: the overlay's join badge asks it
    /// to tell "nothing attached" apart from "there was nothing to attach", so
    /// a Mac that simply is not running Claude Code shows no badge instead of a
    /// permanent complaint. It reads no title, no TTY, no socket and no
    /// process table — it cannot influence, or be influenced by, what `resolve`
    /// decides.
    func hasLiveSessions() -> Bool {
        registry.hasLiveSessions()
    }

    /// This remains the only place a join is resolved, once per dictation, at
    /// start — whichever mechanism answers.
    func resolve(target: TerminalScreenTarget) async -> ClaudeSessionJoin? {
        // A browser is a different kind of target with a different capability:
        // one short URL string, no screen, no pane. The two allowlists are
        // disjoint (pinned by a test), so this branch and the terminal path
        // below can never both apply to one app.
        if BrowserTabAllowlist.isSupported(target.bundleID) {
            return await resolveViaBrowserTab(target: target)
        }
        // Claude Desktop is the third kind of target: one address, read over
        // Accessibility, no screen. Its allowlist is disjoint from the other
        // two (pinned by a test).
        if ClaudeDesktopAllowlist.isSupported(target.bundleID) {
            return await resolveViaDesktopSession(target: target)
        }
        // The allowlist is re-checked here even though the capture gate already
        // enforced it. This object is reachable independently of that gate, and
        // "only a terminal with a verified focused-pane surface" (Ghostty's
        // single-AXTextArea grid, iTerm2's current session, Terminal.app's
        // selected tab) is a precondition of reading this app at all — not
        // something to inherit on trust from a caller.
        guard TerminalScreenAllowlist.isSupported(target.bundleID) else { return nil }

        if let tty = await focusedTerminalTTY(target.bundleID) {
            switch registry.resolve(tty: tty) {
            case .resolved(let snapshot):
                Log.claudeContext.info(
                    "Terminal pane joined to a live Claude session via focused-pane tty"
                )
                // Without a window identity the authorizer cannot tell two
                // windows of one Ghostty process apart and must refuse raw
                // attachment (review F2). Read here, once, at join time.
                return ClaudeSessionJoin(
                    target: target,
                    snapshot: snapshot,
                    windowID: focusedWindowID(target.pid),
                    mechanism: .ttyDevice
                )
            case .unknown:
                abstainedTTYJoin(outcome: "no live session on this device")
            case .stale:
                abstainedTTYJoin(outcome: "stale")
            case .ambiguous:
                abstainedTTYJoin(outcome: "ambiguous")
            }

            // A focused surface positively bound to herdr describes an inner
            // pane, so only herdr can say which one: the arms below ask about
            // the outer surface and would answer about the wrong thing.
            if herdrClientProbe(tty) {
                return await resolveViaHerdr(target: target)
            }

            // The surface is not a local herdr client. It may still be an ssh
            // session into an enrolled host. ONE process-table scan answers for
            // both remote arms below — it is the same question ("what ssh is in
            // this tty's foreground, and where does it go"), and scanning twice
            // could answer it differently for two arms of one dictation.
            let sshResult = sshDestinationProbe(tty)

            switch await resolveViaRemoteHerdr(target: target, sshResult: sshResult) {
            case .joined(let join):
                return join
            case .declined:
                break
            }

            // The local-tty echo first of the two plain-ssh arms: it is the
            // one that works through ProxyJump and ControlMaster, and it costs
            // nothing when the user has not set it up (no header, no match, a
            // named abstention).
            if let join = await resolveViaRemoteLocalTTY(
                target: target, tty: tty, sshResult: sshResult
            ) {
                return join
            }

            // Then the connection binding, for the zero-setup case. Last,
            // because it is the weakest surface claim: the herdr arms prove
            // what the terminal DISPLAYS (a nonce rendered in the grid, or an
            // argv naming herdr as the remote command), while this one proves
            // only which connection the terminal holds. A herdr-hosted session
            // never gets here anyway — it carries a herdr label and both plain
            // arms refuse those outright.
            if let join = await resolveViaPlainSSHConnection(
                target: target, sshResult: sshResult
            ) {
                return join
            }
        }

        // cmux has no AppleScript TTY reader, so the block above never answers
        // for it and this is where its surface arm runs.
        if TerminalScreenAllowlist.isSocketCaptureSupported(target.bundleID),
           let join = await resolveViaCmux(target: target) {
            return join
        }

        // Nothing identified the surface. There is no weaker reading to fall
        // back to, and that is the design: the alternative was a marker in the
        // window title, which every party in the stack (Claude Code, herdr,
        // cmux, the user) rewrites at will, so a lingering one could only
        // describe a session other than the one on screen.
        return nil
    }

    /// Outcome only, never the device path. A silent abstention here made a
    /// broken hook-side tty capture indistinguishable from a failed pane read
    /// in the field (2026-07-20): later arms may still answer, but the
    /// non-answer must say which side of the join went missing.
    private func abstainedTTYJoin(outcome: String) {
        Log.claudeContext.info(
            "Focused-pane tty matched no session (\(outcome, privacy: .public))"
        )
        Self.noteAbstention("tty: \(outcome)")
    }

    /// Where an abstention cause leaves this resolver as a value rather than as
    /// a log line (`HerdrPanelBindingProbe` has the one other such point).
    ///
    /// Both consumers are diagnostics — the dogfood capture record and
    /// `--probe-surface` — and both need the SAME string, so they read it from
    /// here rather than each deriving one. `cause` is already the content-free
    /// category the log line above carries; nothing else may be passed in.
    static func noteAbstention(_ cause: String) {
        ClaudeJoinAbstentionTap.note(cause)
        #if LOCALVOXTRAL_DOGFOOD
        DogfoodCaptureTap.shared.noteJoinAbstention(cause)
        #endif
    }

    /// Re-checks at commit that the join resolved at start still names one live
    /// session, WITHOUT asking any surface a second question.
    ///
    /// The SESSION is fixed by the start resolution — that is the point of
    /// resolving once. What can still change between start and stop is that
    /// session: it can end, its process can die, or the registry can evict it.
    /// Those make the join stale, and a stale join must not attach. So this
    /// asks the registry about the SAME session id (`snapshot(sessionID:)`,
    /// the same TTL-plus-pid-liveness answer every arm resolves through)
    /// rather than re-reading a surface, which would let the answer drift to a
    /// different pane.
    /// A `.browserTab` join additionally re-checks its BINDING: the session
    /// must still report the bridge session id the tab named at start.
    ///
    /// This is what makes a Remote Control disconnect age the join out without
    /// a timer of ours. `CLAUDE_CODE_BRIDGE_SESSION_ID` is REMOVED from the
    /// hook environment when the browser connection ends, and the reducer
    /// replaces a session's reported metadata on the next non-focus record —
    /// `process` for a local session, `remoteEnvironment` for a remote one — so
    /// that record carries no bridge id and this check fails on the session's
    /// own activity, with no clock of ours involved.
    ///
    /// Two exactness caveats, both deliberate and both pinned by tests:
    /// * A record with NO process block (local) or NO allowlisted env header at
    ///   all (remote) is not a retraction — the reducer keeps the last report
    ///   (#216: "an empty report is not a retraction"). Such a session keeps its
    ///   binding until TTL. The bundled shim always reports `$PPID`, so an
    ///   honest disconnect never takes that path, and a host that strips its
    ///   headers could just as well keep sending the id.
    /// * A session that stops reporting entirely is covered by the registry's
    ///   existing freshness (TTL plus, locally, process liveness), exactly like
    ///   every other arm — on the registry's injected clock.
    func isStillLive(_ join: ClaudeSessionJoin) -> Bool {
        guard registry.snapshot(sessionID: join.snapshot.sessionID) != nil else { return false }
        if join.mechanism == .desktopSession {
            return desktopSessionStillResolves(join)
        }
        guard join.mechanism == .browserTab else { return true }
        guard let binding = join.browserTab else {
            // Unreachable through `resolveViaBrowserTab`, which always binds.
            // Fail closed anyway: a browser join with nothing to re-check is
            // not a join we can still vouch for.
            Log.claudeContext.info(
                "Browser tab join carries no bridge binding; treating it as ended"
            )
            return false
        }
        // Re-ASK the registry rather than re-check the session we already
        // picked (review finding, codex on PR #218). Asking only "does my
        // session still report this id" answers a question that was already
        // settled at start; what can change afterwards is who ELSE reports it.
        // A second reporter arriving mid-dictation is exactly the case the
        // start-time arm abstains on — and a hostile enrolled remote host can
        // publish any label it likes, so "I was the sole reporter when we
        // resolved" must not be a permanent claim. Re-resolving makes the
        // abstention rules identical at both ends: unique fresh reporter, or no
        // join. It subsumes the identity check too — `.resolved` can only name
        // a session that still reports the bound id.
        guard case .resolved(let current) =
            registry.resolve(bridgeSessionID: binding.bridgeSessionID),
            current.sessionID == join.snapshot.sessionID
        else {
            Log.claudeContext.info(
                "Remote Control bridge session no longer resolves to this session alone; Claude context withheld"
            )
            return false
        }
        return true
    }

    /// The `.desktopSession` half of `isStillLive`: the bound id must still
    /// resolve to THIS session alone, re-asked for the browser arm's reason —
    /// a second reporter arriving mid-dictation is the ambiguity the start-time
    /// arm abstains on, and an enrolled host can publish any label it likes.
    /// Unlike the bridge id the desktop id never goes away while the session
    /// runs, so this adds no disconnect signal; the registry's freshness still
    /// covers a session that ended.
    private func desktopSessionStillResolves(_ join: ClaudeSessionJoin) -> Bool {
        guard let binding = join.desktopSession else {
            // Unreachable through `resolveViaDesktopSession`, which always
            // binds. Fail closed anyway.
            Log.claudeContext.info(
                "Claude Desktop join carries no session binding; treating it as ended"
            )
            return false
        }
        guard case .resolved(let current) =
            registry.resolve(desktopSessionID: binding.desktopSessionID),
            current.sessionID == join.snapshot.sessionID
        else {
            Log.claudeContext.info(
                "Claude Desktop session no longer resolves to this session alone; Claude context withheld"
            )
            return false
        }
        return true
    }
}
