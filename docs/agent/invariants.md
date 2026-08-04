# Known tradeoffs & invariants — deliberate, not bugs

Read this in full before changing text insertion, LLM polishing, or anything
in the Claude Code context path (`Sources/ClaudeContext*`,
`Sources/localvoxtral/ClaudeContext/`, `integrations/claude-code/`, the
remote listener/enrollment/forward code). The trust boundaries here are
load-bearing and non-obvious; several of them are the residue of measured
failures, with the evidence cited inline.

This file is loaded on demand (a router pointer in the root `AGENTS.md`), not
always-loaded agent context, so it carries no size cap — only the root
`AGENTS.md` does (`AgentsGuideSizeTests`). Growth here is by design; growth
there is not.

- **The TUI trailing-space policy judges this dictation's text only.** The
  terminal stop-flush verdict (`TUIAutocompleteTrailingSpace`, applied in
  `TextInsertionService`) cannot see text the field already held before
  dictation started, so dictating a lone command shape (`/compact `) into a
  prompt line pre-populated by hand withholds a trailing space no popup
  consumed. Accepted: the insertion path has no field-read capability and no
  popup-state signal exists, mid-line command-shaped dictation is rare, and
  the dismissed-popup case the policy exists for is the common one (pinned by
  `testPrePopulatedFieldTextCannotRescueTheTrailingSpace`). Single-component
  tokens naming an EXISTING absolute path (`/tmp `) abstain via a
  filesystem-existence seam; non-existing ones (`/compact`) stay commands.
- **Live Auto-Paste holds back the tail of the transcript.** Replacements are
  applied before typing (nothing is ever un-typed — there are no backspaces in
  the insertion path, and terminals can't support them: field bug 2026-07-06),
  so `LiveHoldBackReplacementStream` withholds the trailing partial word plus
  any suffix that is still a live prefix of a dictionary rule. Nothing is lost
  (`flushRemainder()` releases it at stop) but it costs latency of appearance.
- **LLM polishing trusts the model's text in both profiles.** Human dictation
  evaluation found that `PolishTokenGuard` could reduce fidelity by undoing
  useful formatting and reconstructed identifiers, so it is not in the commit
  path. Repo/clipboard vocabulary is an INPUT-side exception: matcher-approved
  `(heard span, exact local term)` pairs are boundary-checked and pre-applied
  before the single polish call. When the existing exact/edit-distance-one
  matcher finds nothing, a bounded aligned fallback may emit at most one pair;
  it score/margin-gates, abstains on ambiguity/glued prose, and will not add an
  unspoken filename extension without a nearby file cue. This is grounding,
  not an output guard. No content-based leak detector scans or rejects model
  output. Only explicit clipboard-paste payload-placeholder count integrity
  remains active for both profiles. The token guard type remains as a recognizer
  used by clipboard vocabulary and by focused unit coverage; do not infer that
  it runs at commit.

- **Claude Code context reaches the prompt only through a positive marker
  join.** The joined session's repository (status, uncommitted diffs, contents
  of files the agent just touched) and its prior user prompt are attached as
  untrusted reference blocks, behind `claudeRepoContextEnabled` (default off)
  and loopback endpoints only. Invariants to keep:
  - Trust is transport-derived. The wire has no origin field, and
    `LocalWorkspacePath` has no public initializer, so "remote cwd reaches the
    filesystem" is a compile error — do not add one. Its only derivations
    (`ancestor`, `descendant`) preserve that, and `ClaudeRepoCollecting` takes
    it rather than a `String` for exactly this reason.
  - The join is resolved ONCE per dictation, at start
    (`ClaudeSessionJoinResolver`), and every consumer — raw screen attachment,
    the session block, repo collection — shares that one answer. Three
    resolutions could each answer honestly about a different moment; that is
    how one session's screen ends up next to another's repo. Joins support
    four terminals (`TerminalScreenAllowlist`, owner decision 2026-07-22):
    Ghostty, iTerm2, Terminal.app, and cmux (whose arm is its own — see the
    cmux bullet). Resolution is
    TTY-first: the focused pane's controlling TTY, read per terminal over
    AppleScript (`AppleScriptTerminalTTYReader` — Ghostty ≥ 1.4's focused
    terminal, iTerm2's current session, Terminal.app's selected tab; sdef- or
    docs-confirmed, any error abstains) matched exactly against the
    hook-reported session TTY,
    LOCAL sessions only — the title is a fought-over channel (Claude Code's
    own conversation titles clobber the marker mid-turn), the process table is
    not. Any TTY non-answer falls through to the marker in the PID-pinned
    window title — but LOCAL sessions only carry that marker when the user
    enabled the opt-in title fallback (default off; the broker still allocates
    markers either way, it just withholds them from local hook responses). The
    title marker remains the ONLY join for SSH-remote sessions, emitted for
    them unconditionally: a remote TTY names another machine's device, and
    `resolve(tty:)` refuses remote candidates so an SSH host can never claim a
    local pane by echoing its TTY.
  - herdr (the tmux-like agent multiplexer) is a first-class join target with
    its own arm, and it is MARKER-FREE by design (owner decision 2026-07-21):
    herdr intercepts OSC 2 per pane, so a title marker can neither reach
    Ghostty's title nor describe an inner pane — the broker never emits one to
    a herdr-hosted session, even under the title-fallback opt-in. The arm runs
    only after the surface TTY positively binds to herdr (a `herdr` client
    process on the focused terminal surface's TTY, `HerdrClientTTYProbe` —
    herdr's socket has no client introspection, so the process table is the
    only binding; the probe needs only the surface TTY string, so the herdr
    arm works on all three supported terminals), and from that point the join
    is herdr-or-nothing: no
    marker fallback, because a lingering title marker could only mis-join.
    The hook publishes `HERDR_PANE_ID`/`HERDR_SOCKET_PATH` from the pane env;
    `HerdrSocketClient` (hand-written and READ-ONLY — only `pane.current`,
    `pane.process_info`, `pane.read` are ever sent. herdr was AGPL when this
    was written and is Apache-2.0 since v0.8.0, repo `herdrdev/herdr`, so its
    docs and source are freely readable; the client stays hand-written anyway,
    because a vendored dependency would be a second implementation of the trust
    rules) asks that one socket for the focused pane and the join is exact
    pane-id equality (`resolve(herdrPaneID:)`, local sessions only), guarded
    by two fail-closed cross-checks: herdr's own `agent_session` claim must
    not disagree, and the registered Claude pid must be in the pane's
    foreground process list (catches a suspended Claude with the user at the
    shell). Two live herdr sessions (distinct sockets) abstain — there is no
    way to tell which one the surface displays. A herdr join never authorizes
    raw screen attachment of the AX capture: that is the composite herdr TUI,
    and neighboring panes must not ride into this session's prompt. Instead,
    a herdr join's screen context is a clean `pane.read` excerpt of EXACTLY
    the joined pane (`SocketPaneScreenContext`, shared with cmux), fetched at
    start and stop
    behind the same consent gate and sanitize/cap pipeline as an AX read;
    `pane.read` fires only after a herdr join (local or remote) resolved, and
    only ever for THAT join's pane — the request is keyed by the binding the
    arm captured at resolution, so no other pane and no other mechanism can
    reach a herdr socket through it. On any pane.read failure the session falls
    back to the pre-existing behavior — composite AX text, vocabulary-only,
    nothing attached.
  - cmux (github.com/manaflow-ai/cmux — a native Swift/AppKit terminal on
    libghostty) is a join target with its OWN arm, keyed on the surface id
    cmux injects into the session environment. It is opt-in
    (`cmuxSurfaceJoinEnabled`, default off) because the arm talks to ANOTHER
    app's automation socket, which the user must first switch to `password`
    mode with a password (cmux's default `cmuxOnly` mode does a peer-ancestry
    check we cannot pass — we are not a cmux child). The password lives in the
    Keychain (`CmuxSocketPasswordStore`); the socket is dialed by
    `CmuxSocketClient` (hand-written, read-only — cmux is GPL-3, never vendor
    its code), which asks `system.tree` for the focused surface (and its tty)
    and `surface.read_text` for that one surface's VIEWPORT (never
    `scrollback`, and never `lines` — in cmux that parameter implies
    scrollback). Auth is per CONNECTION, not per message: `auth.login` is the
    first line and the query follows on the same connection.
    **The password never leaves the process until the CONNECTED PEER is
    proved.** A same-UID path check cannot do that job — it is TOCTOU by
    construction, and any process running as the user can bind one of the
    candidate paths (the legacy `/tmp` ones especially), pass an owner check
    trivially, and harvest the credential. So the authoritative gate is
    `LOCAL_PEERPID` on the established connection: the peer must BE the
    frontmost cmux app's pid (the same target the join is about), and
    LaunchServices must still report that pid as the cmux bundle. A candidate
    that connects but fails this is dropped, not counted, so an impostor cannot
    manufacture ambiguity either. Deliberately not a code-signature check:
    `SecCode`'s signing identifier is not guaranteed to equal the bundle id, so
    requiring equality could kill the feature against a legitimately signed
    cmux, and the pid binding is the stronger claim anyway.
    Both origins join here, and only here does a REMOTE session join by
    something other than a marker: cmux's ssh relay puts the surface id into a
    `cmux ssh` shell's environment, so the id is ours travelling out and back
    (`resolveRemote(cmuxSurfaceID:)`). But a remembered label is NOT evidence
    that the session still holds the surface — a compromised enrolled host can
    replay an id from an earlier `cmux ssh` session after that surface returned
    to a local shell, and as sole remote candidate it would join, pairing
    attacker-chosen context with the user's current local screen. That is
    strictly weaker than the marker fallback, which at least has to ride the
    PTY the session presently controls. So a remote claim additionally requires
    FRESH evidence from cmux that the focused surface is currently
    remote-hosted. cmux exposes none of that on the surface (a `cmux ssh`
    surface is an ordinary `type: "terminal"`; remoteness lives on the
    WORKSPACE), so the client reads `workspace.remote.status` for the focused
    surface's workspace on the same connection and requires `enabled` AND
    `connected`; unknown fails closed. What remains unproved, and is stated in
    the code: with two enrolled hosts, a compromised one can still claim a
    surface hosted by the other.
    Local matches use `resolve(cmuxSurfaceID:)` (`process`-backed, local-only,
    like the herdr arm) plus a tty cross-check that is MANDATORY on both sides:
    absent tty evidence abstains rather than waiving the check, because a
    process that inherited a stale surface id and moved panes publishes no tty
    to contradict. The cost is stated where it is paid — an opencode session
    inside cmux never joins over this arm (its server half publishes no tty by
    design, and opencode receives no title marker either).
    Ambiguity on EITHER origin abstains: exactly one side may resolve, and the
    other must have no candidate at all. Rejecting only resolved/resolved made
    it asymmetric — two local claimants plus one remote used to join the
    remote, and the mirror case joined the local. `CMUX_WORKSPACE_ID` is never
    consulted (regenerated on restore), and `CMUX_SURFACE_ID` is itself
    session-scoped — cmux re-mints it on restore, which is safe here only
    because both sides of the match come from the same cmux run and stale
    UUIDs cannot collide. Unlike herdr's, a cmux abstention DOES fall through
    to the marker arm: cmux forwards inner OSC 2 to the window title (defeated
    by custom names and AI auto-naming, which is why the surface arm exists).
    cmux exposes no AX text at all, so the join never authorizes raw AX
    attachment and its screen context is `surface.read_text` through the same
    `SocketPaneScreenContext` gate as herdr's `pane.read`.
  - A herdr running on an ENROLLED REMOTE host is its own arm
    (`.remoteHerdrPane`), tried only after every local arm declined, and it
    reaches that herdr over an app-managed, on-demand `ssh -L`
    (`ClaudeRemoteHerdrForward`) opened at dictation start and closed when the
    dictation is done with it. The bindings, ALL required, in cost order so an
    ordinary ssh session never pays for a tunnel:
    (1) the focused surface's own TTY hosts EXACTLY ONE FOREGROUND `ssh`
    session, whose destination is exactly one enrolled host's alias. One,
    because several in a group cannot be told apart from here, and unioning
    them let a plain connection borrow a sibling's herdr signal. `SSHDestinationTTYProbe`
    is deliberately paranoid here, because every way an argv can name one host
    while the connection goes elsewhere is a mis-join: it verifies the
    EXECUTABLE against three EXACT absolute paths (`/usr/bin/ssh` and
    Homebrew's two `bin/ssh`, via `proc_pidpath` — not `p_comm`, not argv[0],
    and never by directory prefix, since `/opt/homebrew` and `/usr/local` are
    user-writable and a prefix rule trusted `/opt/homebrew/tmp/ssh`; a symlink
    target is accepted only when resolving a canonical path produces exactly
    it, its basename is `ssh`, and it stays inside that canonical path's own
    installation root — anyone who can repoint that symlink already controls
    what the user's own `ssh` runs, so this is defense-in-depth, not a
    privilege boundary), requires the
    process to be in its terminal's foreground process group (so a stopped ssh,
    a background one, or `scp`/`rsync`'s helper is not mistaken for the screen),
    and ABSTAINS on `-o`/`-F`/`-O`/`-S`/`-N`/`-f`/`-M`/`-D`/`-W`/`-w` rather
    than skipping them — `ssh -o HostName=other builder` must never answer
    `builder`;
    (2) that ssh session IS herdr — its remote command's first argv token has
    basename `herdr` — AND this terminal holds the ONLY ssh connection to that
    destination on the machine (a `KERN_PROC_ALL` scan counting every other ssh
    with a controlling terminal, including suspended ones on this same device).
    BOTH, because each covers what the other cannot. Uniqueness alone does not
    prove what the terminal DISPLAYS: a herdr whose client detached, or whose
    pane still carries a marker and a running agent inside the registry TTL,
    keeps answering `pane.current` with that pane, so a later sole `ssh builder`
    would join a session the user cannot see. The argv signal alone is not
    enough either — argv is written by whoever launched the process, which is
    why it is matched on the FIRST command token only (`ssh host sh -lc 'printf
    herdr; exec claude'` mentions herdr and is not it).
    Requiring the argv signal is what the absence of a better one forces:
    herdr exposes NO read-only attachment signal — verified against the 0.7.5
    socket schema and the 0.8.0 docs, the only `client.*` methods are
    `window_title.set`/`clear`, both MUTATIONS (so `no_foreground_client` is not
    an acceptable probe), and `session.snapshot` carries no attachment field.
    The accepted cost, stated accurately: the manual flow — `ssh host`, then
    typing `herdr` — gets no HERDR join. It does NOT get "no context": the arm
    returns `.notApplicable`, so the title-marker arm still runs, and a marker
    an earlier session on that host left in the OUTER title can still win. That
    residual is pre-existing (it is what remote sessions have always done) and
    cannot be closed from here, because nothing on the surface reveals a remote
    herdr running inside it — e.g. run Claude in a plain ssh so its marker sits
    in the title, suspend it, then start herdr by hand: dictation joins the
    suspended session. What this arm refuses is a wrong HERDR join. It also
    makes the arm free for everyone else: a plain ssh to an enrolled host no
    longer spawns a forward before falling through;
    (3) that host has live remote sessions reporting a herdr pane, all from ONE
    herdr socket (`liveRemoteHerdrSessions(hostID:)`, the mirror of the local
    single-socket rule). The count that matters is SOCKETS, not sessions:
    several live sessions on one herdr are expected and fine — panes are what a
    multiplexer is for, and serving that workflow is the point of this arm — so
    only two herdr SERVERS leave the surface ambiguous;
    (4) over the forward, exactly ONE of those candidates claims that herdr's
    FOCUSED pane id (two candidates claiming the same pane id abstain), and that
    pane's captured `terminal_title` carries exactly that session's
    broker-allocated marker;
    (5) herdr's own `agent_session` claim for the pane does not disagree, and
    the pane is running that session's agent.
    Herdr-or-nothing begins at CONFIRMATION, not before: everything up to and
    including step 4 falls THROUGH to the title marker on failure, and only
    steps after it abstain. Registry candidates existing on the host is not a
    binding for this connection — a detached herdr, or one whose sessions are
    merely still inside their TTL, would otherwise cost a sole plain ssh session
    the outer marker join it has always had. Once the pane id AND our own
    broker-allocated marker both match, the connection IS displaying that
    session, and from there a marker in the outer window could only describe
    something else, so a later fail-closed refusal joins nothing at all. The
    residual: while the arm has not confirmed, a marker left in the outer title
    by a pre-herdr session on the same host can still win — exactly the behavior
    that predates this arm.
    Note WHY the marker works here and not locally: herdr captures an inner
    pane's OSC 2 into `PaneInfo.terminal_title`, and the remote listener
    already returns a marker to every remote session unconditionally — so the
    marker is sitting in the joined pane's title, invisible to the outer
    terminal. The `agent_session` cross-check is fail-closed exactly like the
    local arm's and is what catches a REUSED pane (a session that died without
    a SessionEnd leaves a live entry, its marker and its pane id behind).
    The foreground check takes EITHER a `hookParentPID` (the shim's `$PPID`,
    compared as a STRING — a remote pid is another machine's number) or a
    process named for the agent; requiring both would fail closed forever on
    two ordinary installs (Claude Code spawns hooks through a shell, so `$PPID`
    is often that shell, and an npm install appears as `node`).
    The tunnel is owned by `DictationViewModel`, never by the join value that
    travels: the commit path CONSUMES the join, so an owner reaching the child
    through `claudeSessionJoin` was nil at exactly the moments that mattered
    (quit during polish, an aborted connect) and the ssh outlived the app.
  - **The remote herdr forward is a trust inversion, and it is bounded by what
    we SEND, not by what the socket allows.** herdr's JSON socket is
    full-control: over that same forwarded stream one could create panes, write
    keystrokes into them, kill them. We dial OUT to it and send only
    `pane.current` / `pane.process_info` / `pane.read`, and that restraint —
    plus the one client in the codebase being hand-written — is the whole
    boundary. In exchange, `ClaudeRemoteSessionEnvironment.herdrSocketPath`
    stays what PR #216 made it: a label that is NEVER handed to `FileManager`,
    never `stat`ed, never dialed locally. Its one and only use is as an argv
    token for `ssh`, resolved on the host that named it, after re-validation
    (absolute, no `:` — that would re-split the `-L` spec — and PR #216's
    header charset). The argv deliberately omits two options an earlier design
    called for, both falsified against OpenSSH 10.0: `ClearAllForwardings=yes`
    clears command-line forwardings too and deletes the very `-L` (measured: no
    socket ever appears), and `ExitOnForwardFailure=yes` turns the enrolled
    host's own `RemoteForward` — normally already held by the user's live
    session — into a fatal error for this connection (measured: ssh exits).
    Readiness is a bounded connect-poll of the local socket instead, on an
    injected clock, with a ~2 s ceiling that is a dictation-start latency
    budget as much as a correctness one. The RESIDUAL of dropping them: this
    short-lived connection still requests whatever forwards the alias's own
    `Host` block declares, including the enrollment `RemoteForward` — since
    #217 that is this Mac's own port, so a collision with the user's live
    session is a warning on a stderr we send to `/dev/null`, not a failure.
    Three options ARE forced, because the alias's config would otherwise reach
    into this child: `ControlPath=none` (so the forward belongs to our own
    process and killing it IS the teardown, at the cost of one handshake per
    dictation), `ForkAfterAuthentication=no` (a detached ssh is an orphan we
    can neither observe nor kill), and `PermitLocalCommand=no` (a dictation
    must not be able to trigger `LocalCommand` on this machine). Teardown
    signals the process GROUP — the child is spawned as its own group leader
    via `posix_spawn`'s `POSIX_SPAWN_SETPGROUP` — whose return value is
    CHECKED, since a silently failed one would leave the child in our own group
    and turn every teardown into an orphan — so `kill(-pgid)` can only ever
    reach our own ssh and its descendants — and it ends with an UNCONDITIONAL
    group SIGKILL. We observe only the leader, so its exit satisfies the
    bounded wait while a descendant that ignored SIGTERM is still holding the
    tunnel; gating that final kill on leader liveness (as the first version
    did) suppressed exactly the signal that clears it. The pairing rule that
    makes "unconditional" safe: the exit handler does NOT reap. A pid — and
    with it the pgid — is reserved only while the child is unreaped, so the
    zombie is what keeps `-pid` meaning OUR group; teardown signals first and
    reaps last, and once reaped NOTHING may signal that group again (a tunnel
    that exits by itself mid-dictation is closed at stop time seconds later,
    which is exactly when a reused pid would be someone else's). Cost: one
    zombie per open forward, for the life of one dictation — and that bound
    only holds because the reap COMMITS only on a definitive answer (the child
    collected, or `ECHILD`), retrying `EINTR` and leaving anything else
    unreaped for the next teardown. Claiming the reap before calling `waitpid`
    turned an interrupted collection into a permanent lie about a zombie that
    was still there, i.e. one leaked per dictation without bound. The collect
    is also NON-BLOCKING first (`WNOHANG`, bounded poll, then handed to a
    background queue): every caller is a user-visible path — stop, commit,
    cancel, app quit, all on the main actor — and a child wedged in an
    uninterruptible wait must cost a background thread, never the UI.
    A remote herdr join authorizes no more than a local one: never the raw AX
    capture (that grid is the composite herdr TUI, on someone else's machine),
    and never local repo collection — the origin is remote, so
    `localWorkspacePath` is nil by type.
  - Screen capture is split by ROUTE (`TerminalScreenAllowlist`): raw AX grid
    capture remains Ghostty-only (its single-`AXTextArea` grid is verified;
    iTerm2's AX tree is ambiguous across splits, Terminal.app's unverified).
    iTerm2/Terminal.app screen context comes ONLY from the AppleScript
    `contents` of the focused session/tab (`TerminalScreenAppleScriptReader`
    — visible screen, never `history`/scrollback; answered by the terminal
    process itself, same trust class as the TTY read, per-pane clean). cmux is
    the third route: its control socket, and nothing else — no AX (there is no
    text area), no Apple events (no scripting dictionary, so it is excluded
    from `appleEventBundleIDs` and from the Automation consent pre-warm). Every
    supported bundle has EXACTLY one route, asserted by test. All
    routes share one downstream pipeline (sanitization, caps, start/stop
    reconcile, vocab-always / raw-excerpt-only-after-authorized-join). A TTY
    join in iTerm2/Terminal.app authorizes attaching that focused pane's
    contents; herdr and cmux joins never attach AX surface text on any
    terminal.
  - A Claude Code "Remote Control" session (the agent runs on a machine of the
    user's, `claude.ai/code` in a browser is the UI) has no pane, no TTY, and no
    title, so it joins from the FOCUSED BROWSER TAB: the tab's
    `https://claude.ai/code/session_…` URL, read over AppleScript behind
    `FocusedBrowserTabURLReading` (Chrome, Brave, Safari —
    `BrowserTabAllowlist`, deliberately a SEPARATE list from
    `TerminalScreenAllowlist`; Firefox has no such AppleScript surface), parsed
    strictly (`ClaudeBridgeSessionURL`: https only, host exactly `claude.ai`,
    no userinfo/port, `session_[A-Za-z0-9_-]+` on the percent-ENCODED path) and
    matched by exact equality against the `CLAUDE_CODE_BRIDGE_SESSION_ID` the
    session's own hooks publish (Claude Code ≥ 2.1.199). This is the ONE arm
    that spans local and remote sessions, because the id is bridge-allocated and
    globally unique — unlike a tty/pane id/pid, which another machine can mirror;
    `ClaudeSessionSnapshot.bridgeSessionID` still routes the read by origin.
    A `.browserTab` join authorizes NO screen capture of any kind (the
    authorizer's mechanism switch is exhaustive, so a new arm must decide), and
    carries no window identity because there is no capture to pair one with.
    Liveness RE-RESOLVES the bridge id at commit (not just "does my session
    still report it"): a second reporter arriving mid-dictation is the same
    ambiguity the start-time arm abstains on, and an enrolled remote host can
    publish any label it likes, so the joined session must still be the unique
    fresh reporter or the join is dead. Claude Code REMOVES the variable when
    the connection ends and the reducer replaces the reported metadata on the
    next non-focus record, so a disconnected session ages out on its own next
    hook rather than on a timer of ours — except for a record with no process
    block / no env header at all, which is not a retraction (#216) and holds the
    binding until TTL. The browser is asked ONLY under
    `claudeRepoContextEnabled` (the screen setting alone must not automate a
    browser), and each browser needs its own TCC Automation grant — pre-warmed
    by its own `TerminalAutomationConsentPrewarmSettingsObserver` under that
    same setting, since the consent sheet dies with the 1 s read that raised it.
  - Lookups abstain rather than guess: no marker, unknown, stale, or ambiguous
    means no context. There is deliberately no sole-session or cwd heuristic —
    it is wrong precisely when it matters.
  - Transcripts are never scraped (the publisher drops `transcript_path`), and a
    LOCAL session never attaches hook-quoted tool excerpts: its files are
    readable directly and are the better source. A REMOTE session's bounded,
    sanitized excerpts DO attach (`ClaudeSessionContextText`, gated on the
    origin) — there is no remote collector, so they are the only thing we will
    ever know about that tree.
  - Everything harvested feeds GROUNDING even when the rendered excerpt is cut
    to nothing — matching is input-side and free; only rendering pays the
    budget.
  These paths are in `scripts/ci/llm-lane-filter.sh`: they change what reaches
  the model, so the LLM lanes run on them.
- **Remote Claude context is opaque by construction.** The remote listener tags
  every accepted session `.remote` regardless of its payload; a local process
  connecting to that listener can only downgrade itself. Remote cwd values are
  labels, not `LocalWorkspacePath` values, and can never authorize FileManager
  or git calls. Sessions are namespaced by the host id whose token authenticated
  them, so hosts cannot collide or forge each other's sessions. Bounded,
  sanitized remote prompt/file/tool excerpts may feed the same context budget,
  but there is no remote repository collector. The same rule governs the
  `X-Lvx-Env-*` enrichment: those values live in
  `ClaudeSessionSnapshot.remoteEnvironment`, never in `.process`, so they
  cannot reach `resolve(tty:)`, `resolve(herdrPaneID:)`, or
  `liveLocalHerdrSocketPaths()` — the local-only arms all read `process`. A
  remote `HERDR_SOCKET_PATH` is a label, not a socket `HerdrSocketClient` may
  dial (its guard still requires a local socket owned by `getuid()`) — the
  remote herdr arm reaches it only by handing it to `ssh -L` as a forward
  target, so the path is resolved on the host that named it and the socket the
  client actually dials is the LOCAL end our own child created. And
  `hookParentPID` is a String on purpose: a pid in another host's namespace is
  not a number this process may probe, only a label to compare against another
  label.
- **Remote enrollment execution is opt-in, preview-first, and keeps the token
  out of process arguments.** `ClaudeRemoteEnrollmentService` generates a
  copyable plan (idempotent ssh config block, `claude plugin` commands,
  verify/uninstall steps, caveats), and the Copy buttons remain available.
  One-click actions require a separate confirmation that repeats the exact
  ssh-config block or redacted command list. Local insertion replaces only the
  matching host's marked block, preserves an existing config's permissions, and
  atomically renames a same-directory temporary file; a missing `~/.ssh` and
  config are created as 0700/0600. It refuses (with the copy path as the
  documented out) when `~/.ssh/config` or `~/.ssh` is a symlink — a rename
  would replace the link and desync a dotfiles setup — or when `~/.ssh` is not
  owned by the user or is group/world-writable. Remote execution spawns only `ssh -o
  BatchMode=yes <alias> /bin/sh -s` and sends the generated token-bearing script
  through stdin — the token must never enter an argv. The whole action has a
  finite timeout, and every captured result, thrown error, alert, and log string
  is token-redacted before it leaves the service. Keep the filesystem and
  process runners injected; the no-runner service must continue to throw
  `.executionNotConfigured`.
  `ClaudeIntegrationSettingsModel` (`@MainActor @Observable`, all seams
  injected) owns the pane's logic, and `ClaudeRemoteListenerCoordinator` owns
  the bind/unbind decision — enrolling the first host binds immediately and
  revoking the last one closes the port, with no relaunch. Adding a host to an
  already-bound listener rebinds NOTHING (it authenticates against the registry
  live), so a second enrollment cannot drop the first host's tunnel.
  A bind conflict is reported, never routed around onto another port: a
  squatter on 8473 receives the remote's bearer token before anything rejects
  it, so the user must learn it is there. What the squatter does NOT get is a
  path into the prompt: the remote shim's stdout gate (post.sh) rejects any
  200 body that is not exactly the listener's allowlisted control JSON, and a
  forged well-formed marker is inert because markers are broker-allocated —
  an unknown one joins nothing. Note also what is NOT defensible: a
  malicious process running as the user on the REMOTE host can still read
  `~/.claude/` and therefore the plugin's token no matter what we do. Say so
  rather than implying the token bounds it.
