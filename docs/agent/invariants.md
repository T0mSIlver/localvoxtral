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

- **Claude Code context reaches the prompt only through a positive join.**
  The joined session's repository (status, uncommitted diffs, contents
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
    hook-reported session TTY, LOCAL sessions only. A TTY non-answer does not
    fall through to a weaker reading of the same surface; the arms after it
    (herdr pane, remote herdr, cmux surface, browser tab) each ask a DIFFERENT
    question, and when none answers, the dictation gets no join.
  - **NO JOIN EVER READS A WINDOW TITLE** (owner decision 2026-09-05). Until
    then the broker allocated an `lvx-…` marker per session, returned it in
    the hook reply, and Claude Code wrote it into the window title over OSC 2;
    a PID-pinned `AXTitle` read joined on it. All of it is gone — the marker,
    the reply field, the `terminalSequence` the local and remote hooks
    printed, the opt-in "Local Claude title fallback" setting, and the
    title-arm suppression rules that had accreted around it. The reason is one
    sentence: a window title is a channel every party in the stack rewrites at
    will — Claude Code its conversation titles (which clobbered the marker
    mid-turn, field finding 2026-07-17), herdr and cmux their pane titles, the
    user their own — so a marker sitting in one is evidence about the past,
    not about what the surface displays now, and every arm it fell through
    from had already refused for a reason.
    That was MEASURED on the owner's setup before this removal shipped
    (2026-09-05): polling a herdr pane's captured `terminal_title` at ~325 Hz
    for 69.4 s across a hook event, the broker marker was the title for 0.88 s
    in total — **1.26 % of the window**. The other 98.74 % it was Claude
    Code's own conversation title. The numbers and what they cost the remote
    arm are in the remote-herdr bullet below. `TerminalScreenAXReader` retains
    only `focusedWindowIdentity`, which reads no title: it exists so the
    authorizer can pair a screen capture with the join that authorized it.
    Precision matters in that sentence: no JOIN reads a title. One title read
    survives elsewhere in the app and is deliberately untouched —
    `TerminalWorkingDirectoryResolver.windowTitle(forApplicationPID:)` mines
    the commit target's title for a git root, behind `repoVocabularyEnabled`,
    to extract local vocabulary. It selects no session, authorizes no capture,
    and reaches no `ClaudeSessionJoin`; a wrong answer there costs a few
    unhelpful vocabulary terms rather than another session's repository.
    The one session shape the title marker uniquely served — a PLAIN ssh remote
    session, Claude Code in `ssh host` with no herdr, no cmux, no Remote
    Control — went armless for the length of one PR and is served again by the
    CONNECTION arm below. Nothing else ever lost an arm: a remote session also
    joins through `cmux ssh`'s round-tripped surface id, the remote-herdr pane
    arm, or the bridge-allocated Remote Control session id.
    A remote TTY names another machine's device, and `resolve(tty:)` refuses
    remote candidates so an SSH host can never claim a local pane by echoing
    its TTY.
  - herdr (the tmux-like agent multiplexer) is a first-class join target with
    its own arm. It was the first arm to be marker-free (owner decision
    2026-07-21, for the reason the whole mechanism was later removed for:
    herdr intercepts OSC 2 per pane, so a title marker could neither reach
    Ghostty's title nor describe an inner pane). The arm runs
    only after the surface TTY positively binds to herdr (a `herdr` client
    process on the focused terminal surface's TTY, `HerdrClientTTYProbe` —
    herdr's socket has no client introspection, so the process table is the
    only binding; the probe needs only the surface TTY string, so the herdr
    arm works on all three supported terminals), and from that point the join
    is herdr-or-nothing: a surface showing an inner pane is a surface no other
    arm can describe.
    The same property binds anything OUTSIDE the app that tries to identify a
    herdr-hosted window by its title: the UI gate's `term open` did exactly
    that and could never see the window it opened (field failure 2026-08-30),
    so it now identifies a window by a CGWindowID diff taken before the window
    exists (`scripts/mac/localvoxtral-ui-gate.sh`).
    The hook publishes `HERDR_PANE_ID`/`HERDR_SOCKET_PATH` from the pane env;
    `HerdrSocketClient` (hand-written and capability-bounded — reads are only
    `pane.current`, `pane.process_info`, and `pane.read`; its sole mutation is
    the remote panel probe's short-lived `lvmark` through
    `pane.report_metadata`. herdr was AGPL when this
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
    Both origins join here: cmux's ssh relay puts the surface id into a
    `cmux ssh` shell's environment, so the id is ours travelling out and back
    (`resolveRemote(cmuxSurfaceID:)`). But a remembered label is NOT evidence
    that the session still holds the surface — a compromised enrolled host can
    replay an id from an earlier `cmux ssh` session after that surface returned
    to a local shell, and as sole remote candidate it would join, pairing
    attacker-chosen context with the user's current local screen. So a remote
    claim additionally requires FRESH evidence from cmux that the focused surface is currently
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
    design), so opencode inside cmux gets no join at all.
    Ambiguity on EITHER origin abstains: exactly one side may resolve, and the
    other must have no candidate at all. Rejecting only resolved/resolved made
    it asymmetric — two local claimants plus one remote used to join the
    remote, and the mirror case joined the local. `CMUX_WORKSPACE_ID` is never
    consulted (regenerated on restore), and `CMUX_SURFACE_ID` is itself
    session-scoped — cmux re-mints it on restore, which is safe here only
    because both sides of the match come from the same cmux run and stale
    UUIDs cannot collide. A cmux abstention used to fall through to the
    window-title marker arm — cmux forwards an inner OSC 2 to its window title
    — and since that arm was removed (2026-09-05) an abstention here is the
    dictation's answer. The title was never reliable anyway: a custom
    workspace name or cmux's AI auto-naming replaces it, which is why the
    surface arm exists.
    cmux exposes no AX text at all, so the join never authorizes raw AX
    attachment and its screen context is `surface.read_text` through the same
    `SocketPaneScreenContext` gate as herdr's `pane.read`.
  - A herdr running on an ENROLLED REMOTE host is its own arm
    (`.remoteHerdrPane`), tried only after every local arm declined, and it
    reaches that herdr over an app-managed, supervised `ssh -L`
    (`ClaudeRemoteHerdrForward`). An authenticated hook carrying a usable herdr
    socket label starts it off the dictation path; a successful cold join also
    retains it. Dictations lease the local socket, and the app keeps the process
    through a bounded injected-clock idle window so later dictations reuse the
    completed SSH/ProxyJump handshake. Its PRIMARY surface authorization is the
    herdr agents-panel binding, not ssh argv. For each plausible enrolled host
    (the readable ssh destination when available; when an ssh is PRESENT but
    unreadable, at most three enrolled hosts with live herdr-bearing
    sessions; a surface with NO ssh at all never probes — a local shell must
    not pay cold-forward latency or flash nonces in panels the user is not
    looking at), the resolver preserves the
    single-socket rule, opens the forward, reads `pane.current`, and identifies
    the unique live session claiming that pane. It then stamps that pane through
    `pane.report_metadata` with a fresh `lv-mic-…` nonce (more than 40 random
    bits, 8 s TTL) and requires that token in the focused terminal's
    existing visible-grid route within a bounded injected-clock settle window.
    Not the WHOLE token: herdr truncates an agents-panel row to the sidebar's
    column budget, which the user's own sidebar width decides, so the match is
    the longest rendered prefix with a FLOOR of 8 nonce digits
    (log2(36^8) ~= 41.4 bits — the "more than 40 bits" bound is what the floor
    exists to hold, and a shorter run is refused as `row-truncated`, never
    accepted as weaker evidence). Field measurement 2026-09-05 is why: at
    `sidebar_width = 20` the 17-column token rendered as `lv-mic-<8 digits>…`
    and an exact match could never succeed while the row was visibly there.
    A whole-view
    App client renders the agents sidebar; `terminal_attach` and
    `terminal_observe` render only the raw pane and cannot render this token.
    The nonce travels only over the owner/mode-checked forwarded socket and is
    unguessable inside its short lease, so remote-influenceable terminal text
    cannot manufacture the match without already observing that herdr server.
    Two hosts whose distinct nonces both appear abstain. A matched token stays
    alive as the dictation's visible mic indicator (refresh about every 4 s,
    TTL 8 s) and is explicitly cleared before its forward closes.
    EXTERNAL ASSUMPTION: herdr upgrades must re-verify BOTH that attach/observe
    clients still omit the sidebar (`src/server/headless.rs` render loop) and
    that all App clients still render one server-global panel/focus
    (`tests/multi_client.rs`). Per-client focus or a sidebar in attach mode
    invalidates this authorization argument. The first half is now MEASURED
    rather than assumed: the `integration-herdr` lane stamps a nonce through a
    real forward and asserts that a whole-view client renders it while a
    `terminal attach` client of the same pane does not
    (`HerdrIntegrationTests`, `docs/agent/test-tiers.md`). The server-global
    focus half remains unmeasured — see the panel-binding doc's "Pinned against
    a live server" section for exactly which assumptions are covered and which
    are still documented hopes.

    Any stamp refusal, unavailable grid, hidden/unconfigured/scrolled panel row,
    a row cut below the entropy floor, or a bounded settle timeout can only
    produce NO MATCH. It closes that attempt
    and falls through to the pre-existing argv authorization below; it never
    weakens the pane-level confirmations. The fallback first requires that the
    focused surface's own TTY host EXACTLY ONE FOREGROUND `ssh`
    session, whose destination identifies exactly one enrolled host. Exact
    alias matching wins without spawning anything; only when it finds no host,
    the app resolves the operand and each active enrolled alias through the
    user's effective `ssh -G` config and compares `(hostname, port)` — never
    `user`, which `ssh -G` always emits and which is always the local default
    on the operand side because the probe strips `user@` upstream; comparing
    it would reject an alias that sets `User`, the common build-host shape,
    while two same-box enrollments still land in the multiple-match
    abstention. Any refused operand, spawn/timeout
    failure, or unparseable output discards the whole fallback; two canonical
    matches remain ambiguous. Results are briefly TTL-cached because ssh config
    can change on disk. One,
    because several in a group cannot be told apart from here, and unioning
    them let a plain connection borrow a sibling's herdr signal. `SSHDestinationTTYProbe`
    is deliberately paranoid here, because every way an argv can name one host
    while the connection goes elsewhere is a mis-join — and since 2026-09-05
    it answers for the plain-ssh arm too, so a refusal here costs both: it
    verifies the EXECUTABLE against three EXACT absolute paths (`/usr/bin/ssh` and
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
    `builder`. The exact, case-insensitive `SetEnv=` and `SendEnv=` `-o` keys
    are the only exception: they can neither move the destination nor change
    the session's interactivity, and accepting them keeps terminal wrappers
    such as Ghostty's from making every probe abstain. ssh MACHINERY is
    invisible to this count and to the uniqueness
    competing-view scan below: an ssh that is a direct CHILD of another scanned
    ssh — a ProxyJump's `ssh -W` hop, which OpenSSH spawns on the same tty in
    the same foreground process group (field abstention 2026-08-06) — is its
    root connection's transport, not a second connection. The partition rides
    kernel ppid, which no launcher gets to write, so it cannot hide a
    connection (the demoting parent is itself counted); sibling ssh processes
    in one group have no ssh parent and stay refused, and a shell-mediated
    ProxyCommand's grandchild stays a root and abstains — conservative on
    purpose. Probe abstentions carry a content-free cause category
    (`SSHProbeIndeterminacy` — never a host, path, or option letter) into the
    log and the dogfood record, because three field dictations were diagnosed
    blind without one;
    It then requires that ssh session to BE a plain whole-view herdr client — classified, not
    boolean (`HerdrInvocation`): the remote command's first argv token has
    basename `herdr` and the rest is empty or `--session <name>`. Every other
    herdr shape is REFUSED because it displays something other than the
    server-global focus the join reads: `herdr terminal attach <id>` renders
    ONE pane, and a `--session` we cannot normalize may be a DIFFERENT server
    (named sessions have separate sockets) — both were mis-joins reachable
    with a single connection while the signal was a boolean. AND no OTHER
    tty-holding ssh root on the machine may be a COMPETING herdr view of that
    destination (a `KERN_PROC_ALL` scan, including suspended ones on this same
    device): a client with a different session selector, a herdr subcommand
    shape, an argv that was refused and mentions `herdr` (substring,
    one-sided), or anything unreadable. What deliberately does NOT compete
    (2026-08-06, replacing blanket machine-wide uniqueness): ANOTHER USER's
    ssh (kernel `e_ucred.cr_uid`, never self-reported) — their herdr view
    lives in their own login session, not on a surface this user dictates
    into, and their metadata is never read; a cross-uid ssh ON the focused
    surface itself (`sudo ssh`) still abstains as an unreadable client rather
    than vanishing; a plain shell or
    non-herdr ssh to the same host — it is on another tty and the probe only
    reads the FOCUSED surface's tty — and a second whole-view client with a
    byte-identical selector, because herdr focus is SERVER-GLOBAL and
    multi-client attach is a mirror (verified in herdr source at v0.8.0 /
    protocol 19: `src/app/api/panes.rs::handle_pane_current` resolves the
    app's single active pane; `tests/multi_client.rs` proves frames broadcast
    to all clients), so both clients display the same focused pane and the
    join is correct for either. EXTERNAL ASSUMPTION: that focus model. If
    herdr ever grows per-client views, same-selector coexistence becomes a
    mis-join — re-verify `handle_pane_current` + the multi-client tests on
    herdr upgrades before trusting this paragraph. A SECOND external
    assumption rides with it: "byte-identical selector ⇒ same server" holds
    only while the remote side derives the socket from the selector alone —
    a shell with `HERDR_SOCKET_PATH` or a different `XDG_RUNTIME_DIR`
    exported can attach two bare `herdr` invocations to DIFFERENT servers,
    which this rule cannot see from the Mac (the argv is all it has). The
    residual is bounded downstream — candidates spanning two sockets abstain
    at the single-socket rule, and the pane-level confirmations still have to
    agree — but a candidate set living entirely on the OTHER
    server confirms against that server, so the honest statement is: env
    divergence on the remote defeats the selector comparison, and we accept
    that because the divergence is the user's own deliberate configuration.
    The argv signal is trustworthy here in a way the old comments undersold:
    it is the EXEC-TIME vector of a VERIFIED OpenSSH binary (kernel
    `KERN_PROCARGS2`), i.e. the command ssh actually ran, not a self-report —
    but it is still matched on the FIRST command token only (`ssh host sh -lc
    'printf herdr; exec claude'` mentions herdr and is not it), because what a
    shell wrapper goes on to run is not something any argv can promise. The
    invocation requirement exists because being the sole connection proves
    nothing about what the terminal DISPLAYS: a herdr whose client detached,
    or whose pane still runs an agent inside the registry TTL, keeps answering
    `pane.current`, so a plain `ssh builder` must never reach the join no
    matter how alone it is.
    The argv fallback remains necessary when the direct panel proof cannot
    render. Its historical limitation is:
    herdr exposes NO read-only attachment signal — re-verified at v0.8.0 /
    protocol 19 (2026-08-06), the only `client.*` methods are
    `window_title.set`/`clear`, both MUTATIONS (so `no_foreground_client` is not
    an acceptable probe), `session.snapshot` carries no client records, and
    the event stream has no client lifecycle events.
    The manual flow — `ssh host`, then typing `herdr` — now joins through the
    panel binding whenever the agents sidebar and configured token row are
    visible. Its residual is narrow/collapsed/covered sidebar or an unconfigured
    row: panel authorization fails closed, then argv still cannot identify the
    manually launched herdr, and there is nothing under it — the dictation gets
    no join. The plain-ssh arm does NOT rescue that flow and must not be made
    to: those sessions carry `HERDR_PANE_ID`, so they are refused there by the
    multiplexer rule (a herdr server keeps the FIRST connection's
    `$SSH_CONNECTION`, exactly as tmux does), and joining them on a connection
    would bind a pane's session to whichever window started the server. The whole "title-marker arm suppression" rule
    that used to live here (the exact `SSHProbeIndeterminacy` categories that
    did and did not suppress an outer title) is gone with the arm it protected;
    `SSHProbeIndeterminacy` remains as a content-free diagnostic category only.

    Both surface-authorization paths retain the remaining bounds: the host has
    live remote sessions reporting a herdr pane, all from ONE
    herdr socket (`liveRemoteHerdrSessions(hostID:)`, the mirror of the local
    single-socket rule). The count that matters is SOCKETS, not sessions:
    several live sessions on one herdr are expected and fine — panes are what a
    multiplexer is for, and serving that workflow is the point of this arm — so
    only two herdr SERVERS leave the surface ambiguous;
    over the forward, exactly ONE of those candidates claims that herdr's
    FOCUSED pane id (two candidates claiming the same pane id abstain);
    herdr's own `agent_session` claim for the pane does not disagree; and the
    pane is running that session's agent. Registry candidates existing on the
    host is NOT itself a binding for this connection — a detached herdr, or one
    whose sessions are merely still inside their TTL, keeps answering
    `pane.current` — which is why the surface authorization above (panel nonce,
    or argv classification) has to come first.

    **The pane confirmation used to have a fourth member. Losing it is the one
    place this removal costs security rather than only reach — but the field
    measurement below is why it had to go anyway. Read both halves before
    touching the arm.**

    MEASURED on the owner's setup, 2026-09-05, with the panel nonce matching
    and everything else healthy: the join ended at `remote-herdr: panel-bound
    pane marker confirmation failed`. Polling that pane's `terminal_title` at
    ~325 Hz for 69.4 s across a hook event, the broker marker was the title
    for **0.88 s total — 1.26 % of the window**; the rest of the time it was
    Claude Code's own conversation title (`✳ …`), which clobbers the OSC 2
    write. Restarting the same session with
    `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` left the marker standing and the
    join succeeded immediately. So the "fought-over channel" hazard this file
    documents for LOCAL titles applies to a herdr PANE title too — herdr
    captures whatever the inner program last wrote, and the inner program is
    the one rewriting it. The confirmation was not a second binding in
    practice; it was a ~1 % lottery that blocked the shipped feature for any
    user who had not exported that variable. Removing it is the fix, not a
    weakening of a working check. What follows is the honest accounting of
    what the check would have bought had it fired. herdr captures an inner pane's OSC 2 into
    `PaneInfo.terminal_title`, and the remote listener returned a
    broker-allocated marker to every remote session, so the marker was sitting
    in the joined pane's captured title where the arm could require it. Its
    value was that a pane id is a LABEL THE ENROLLED HOST CHOSE, while a marker
    is a value WE minted and handed to exactly one authenticated session: a
    compromised enrolled host could publish another session's `HERDR_PANE_ID`,
    but it could not make that pane's title carry its own marker.

    What a compromised enrolled host could do BEFORE: publish a pane id it does
    not own, and be refused at the marker check (unless it could also write
    that other session's marker into the pane title — which it could, since
    both sessions run on the host it controls and OSC 2 is just bytes on a pty.
    So the marker was never a boundary against a host that had ALREADY been
    compromised; it was a boundary against a host that was merely CONFUSED, and
    against a session lying about a pane it never occupied).
    AFTER: the same host publishes the same forged pane id and is refused by
    herdr's own `agent_session` claim when herdr has one, and by the pane's
    foreground process list when it does not.

    **Read the strength of those two carefully; they are not equal, and the
    second is weaker than it looks.** The `agent_session` claim is an answer
    from herdr — the party that actually watches the pane — and a forger cannot
    produce it. The foreground check is not: `remoteAgentIsForeground` is
    satisfied by EITHER the session's own published `hookParentPID` (the remote
    shim's `$PPID`, an `X-Lvx-Env-Hook-Parent-Pid` header the CLAIMANT wrote)
    appearing in herdr's list, OR any foreground process merely NAMED for the
    agent. So it asks "is an agent running in that pane", not "is THIS session
    running in that pane" — and both satisfiers are things a claimant on the
    host can arrange without occupying the pane: same-uid code can read the
    victim pane's foreground pid and publish it, and any pane running `claude`
    at all satisfies the name check.

    Which makes the residual wider than a forgery story, and it has an innocent
    form that matters more: an ordinary session carrying a STALE
    `HERDR_PANE_ID` — inherited by an exec, or left over after herdr moved
    panes — joins onto whichever session is actually in that pane, whenever
    herdr reports no `agent_session` for it and an agent is running there. And
    the lane measured that absence as the COMMON case
    (`remote-herdr-panel-binding.md`, "Pinned against a live server":
    `pane.current` did NOT carry `agent_session` for a pane whose agent session
    id had been reported through `herdr pane report-agent-session`). The marker
    was the check that told two sessions in one pane apart, and nothing
    replaces it; what bounds this now is that the candidate set is scoped to
    ONE enrolled host, that only ONE candidate may claim the focused pane id at
    all, and that enrollment is revocable. Do not build a new argument on the
    foreground check without re-reading this paragraph.
    The refusals that DO hold are pinned by
    `testASessionForgingAnotherPaneIDIsRefusedByHerdrsOwnClaim` and its
    foreground sibling; the residual above is deliberately not pinned by a test
    that would assert a mis-join is possible.

    What the panel nonce still proves, and it is the load-bearing half: that
    the FOCUSED LOCAL SURFACE — the window the user is looking at, read through
    our own AX capture — is displaying a whole-view client of the specific
    herdr server we just stamped, within an ~8 s TTL, with a token of more than
    40 random bits that travelled only over an owner- and mode-checked
    forwarded socket. That is a statement about THIS Mac's screen, which no
    remote host can forge and which the marker never made: the marker said
    "this pane belongs to this session", never "this window shows this
    server". Surface authorization and pane confirmation answer different
    questions, and removing the marker removed a second answer to the second
    question, not the first.
    The `agent_session` cross-check is fail-closed exactly like the
    local arm's and is what catches a REUSED pane (a session that died without
    a SessionEnd leaves a live entry and its pane id behind).
    The foreground check takes EITHER a `hookParentPID` (the shim's `$PPID`,
    compared as a STRING — a remote pid is another machine's number) or a
    process named for the agent; requiring both would fail closed forever on
    two ordinary installs (Claude Code spawns hooks through a shell, so `$PPID`
    is often that shell, and an npm install appears as `node`).
    The process is owned by the app-level `ClaudeRemoteHerdrForwardService`,
    never by the join value that travels: the commit path CONSUMES the join, so
    an owner reaching the child through `claudeSessionJoin` was nil at exactly
    the moments that mattered (quit during polish, an aborted connect) and the
    ssh outlived the app. `DictationViewModel` owns only leases, releasing every
    one on its existing session-exit paths; the service owns idle, revoke, quit,
    supervision, pid-ledger and next-launch orphan-reap lifecycles.
  - **The remote herdr forward is a trust inversion, and it is bounded by what
    we SEND, not by what the socket allows.** herdr's JSON socket is
    full-control: over that same forwarded stream one could create panes, write
    keystrokes into them, kill them. We dial OUT to it and send only
    `pane.current` / `pane.process_info` / `pane.read`, plus only the bounded
    `pane.report_metadata` `lvmark` lease described above, and that restraint —
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
    budget as much as a correctness one and is UNCHANGED for a cold dictation.
    Before reuse, BOTH the supervised process and a fresh connect to the local
    socket must be healthy; either failure tears the entry down and returns to
    that cold path. Activity-driven preparation does not block a dictation, so
    a slow ProxyJump may finish before the next one. The RESIDUAL of dropping
    the two options: this retained connection still requests whatever forwards the alias's own
    `Host` block declares, including the enrollment `RemoteForward` — since
    #217 that is this Mac's own port, so a collision with the user's live
    session is a warning on a stderr we send to `/dev/null`, not a failure.
    Three options ARE forced, because the alias's config would otherwise reach
    into this child: `ControlPath=none` (so the forward belongs to our own
    process and killing it IS the teardown; persistence amortizes the handshake
    without borrowing the user's master), `ForkAfterAuthentication=no` (a detached ssh is an orphan we
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
    that exits by itself is finalized by the supervisor before restart, which
    is exactly when a reused pid could otherwise be someone else's). Cost: one
    zombie per supervised forward between leader exit and teardown — and that
    bound
    only holds because the reap COMMITS only on a definitive answer (the child
    collected, or `ECHILD`), retrying `EINTR` and leaving anything else
    unreaped for the next teardown. Claiming the reap before calling `waitpid`
    turned an interrupted collection into a permanent lie about a zombie that
    was still there, i.e. one leaked per restart without bound. The collect
    is also NON-BLOCKING first (`WNOHANG`, bounded poll, then handed to a
    background queue): every caller is a user-visible path — idle, health
    replacement, revoke, app quit, all on the main actor — and a child wedged in an
    uninterruptible wait must cost a background thread, never the UI.
    A remote herdr join authorizes no more than a local one: never the raw AX
    capture (that grid is the composite herdr TUI, on someone else's machine),
    and never local repo collection — the origin is remote, so
    `localWorkspacePath` is nil by type.
  - **The `--probe-surface` diagnostic verb runs the real resolver, so its
    read-only-ness is enforced by what it is HANDED, not by what it chooses to
    do.** A one-shot process is the worst possible owner for the two arms that
    write anything: an `ssh -L` it opens has no supervisor and no idle window,
    and a `pane.report_metadata` `lv-mic-…` stamp it leaves behind has nobody
    left to clear it if the process is killed between stamping and clearing. So
    `ClaudeSurfaceProbeCommand` passes `remoteHerdrForwards` and
    `herdrPanelMetadata` as `nil` — the resolver's own documented "this arm can
    never spawn anything" configuration — and the arm reaches `forward
    capability unavailable` and stops. There is no flag that re-enables them,
    which is the point: an opt-in would be a cleanup obligation, and this is the
    absence of the capability. The arm's read-only halves (the process-table
    ssh probe, enrolled-host matching including `ssh -G`, which resolves config
    and opens no connection) DO run, because they are what the field questions
    are about. Withheld for their own reasons and by the same construction:
    `cmuxSurfaces`/`cmuxJoinEnabled` (the arm reads a Keychain password — a
    diagnostic must not raise that prompt), `focusedBrowserTabURL` (a tab URL
    is a page the user is looking at), and `readFocusedGrid` (screen text; only
    the panel-nonce match ever needed it, and that match cannot happen here).
    What the verb PRINTS is bounded by `ClaudeSessionJoinSummary`, the single
    mapper the dogfood record also uses: an arm name, the resolver's own
    content-free abstention categories, an origin CLASS, a terminal NAME, and
    two Bools — never a session id, pane id, socket path, host, nonce, or
    workspace path. The registry is per-process and therefore empty in that
    process; the verb says so as its first cause rather than letting the arms'
    resulting declines read as a surface failure.
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
  - **The local-tty echo arm (`.remoteLocalTTY`, 2026-09-06).** The tty arm,
    with the identifier taking one extra trip — and the arm that actually
    serves the configs people have. `resolve(tty:)` compares the focused
    pane's device against a device a LOCAL session's hooks read from `/dev`
    here; this compares it against a device name that came FROM here, carried
    into the remote session by ssh itself.

    The carrier is `$LC_LVX_TTY`: the user's own shell exports it, ssh's
    `SendEnv` sends it, sshd's stock `AcceptEnv LANG LC_*` accepts it, and
    libc ignores locale names it does not know — the mechanism iTerm2 ships
    `LC_TERMINAL` on. Tried BEFORE `.remoteSSHConnection`, because it is the
    one that works through the two things that defeat a TCP-level match, and
    both were MEASURED on a live OpenSSH pair (2026-09-06): the value arrives
    unchanged through a `ProxyCommand`/`-W` jump — where the connection
    binding has no chain it can follow at all, see the ProxyJump paragraph
    above — and two sessions multiplexed over ONE ControlMaster connection
    each receive their OWN value, because ssh carries environment per SESSION
    CHANNEL rather than per connection. The Mac-side setup is one rc line
    plus a `SendEnv` in the enrollment-written `Host` block (most ssh_configs
    already send `LC_*`; the line is what makes it true on the rest).

    Requirements: the focused surface's tty, read through the terminal's own
    scripting interface — never anything the remote host said; exactly one
    foreground ssh on that surface whose destination resolves to exactly one
    enrolled host (ProxyJump does not change the destination OPERAND, so a
    jumped connection resolves like any other); the candidate registered by a
    hook AUTHENTICATED FROM THAT HOST; the candidate a plain ssh shell
    (`$SSH_TTY`, and none of `multiplexerLabels` — a multiplexer server keeps
    the FIRST client's environment, so a pane's `$LC_LVX_TTY` names whichever
    window started the server, the same inheritance the connection arm
    refuses); its reported tty well-formed
    (`ClaudeRemoteLocalTTYPath.isAcceptable` — under `/dev`, no traversal,
    bounded) and EQUAL to the surface's; and exactly one live session claiming
    it. The surface ssh's SOCKET is deliberately not consulted — the socket is
    precisely what ProxyJump and ControlMaster take away.

    **Trust.** The value is chosen by the user's own shell on this Mac and
    carried by the SSH session itself; the remote host receives it rather than
    inventing it. A COMPROMISED enrolled host can of course claim any tty name
    — it can write whatever it likes into that header — but the origin-host
    check bounds it to windows whose ssh actually goes to IT, so it can only
    choose among its own windows. That is the same bound the window-title
    marker had, and the marker additionally depended on a channel Claude Code
    clobbered 98.7 % of the time; this one does not. What it does NOT prove is
    which PROGRAM is drawing in that window — same as every other arm — and it
    authorizes no screen read for that reason
    (`TerminalScreenClaudeJoinAuthorizer`).

    A stale local export is not a hazard worth guarding: a shell's controlling
    tty is fixed for its lifetime, so `LC_LVX_TTY` cannot go stale within the
    shell that set it. The one real footgun is the opposite direction — the
    same rc line running on the REMOTE host re-exports the REMOTE pts and
    hides the Mac's value — which is why the documented line only exports when
    `$SSH_TTY` is unset and the variable is not already set. Getting that
    wrong costs a non-join with a named cause (`no live session reports this
    terminal's tty`), never a mis-join.

    **What IS a hazard, and the reason rules 6 and 7 exist: the tty NAME is
    recycled and the registry entry is not.** macOS hands out pty minors
    first-free (XNU `bsd/kern/tty_ptmx.c`: `ptmx_clone` scans for the first
    free slot, `ptmx_free_ioctl` returns the minor on last close), so closing
    a window gives its `/dev/ttysNNN` to the next window opened — while a
    REMOTE session's registry entry survives for the full session TTL with no
    liveness check available (its pid is another machine's). Without a gate:
    close a Claude-over-ssh window, open a new one to the same host, dictate,
    and the dead session's repository and prior prompt attach to it. That is
    the cardinal failure, and it was found by review (2026-09-06) rather than
    in the field. The connection arm was immune by accident — a new window's
    ssh has a new ephemeral port.

    The gate is kernel truth on both sides: an ssh that STARTED after a
    session was first seen cannot be the ssh that session was created in, so
    the candidate must satisfy `firstSeen >= surfaceProcessStartTime`
    (`p_starttime`, from the same `KERN_PROC` scan). An unreadable start time
    refuses rather than skipping the check. Where the surface's ssh DOES hold
    sockets — the direct shape, where this arm and the connection arm overlap
    — the candidate's `$SSH_CONNECTION` must additionally match one of them; a
    pure negative check that makes this arm strictly stronger than the
    connection arm wherever both can run, and that has nothing to say in the
    ProxyJump/ControlMaster shapes this arm exists for. Which is exactly why
    the start-time gate is not optional.

    Residual, shared with the connection arm and unchanged by this: a session
    that DIED without a `SessionEnd` in a window whose ssh is still alive is
    still joinable until its TTL. And a terminal multiplexer that publishes no
    label the shim carries — `abduco` and `dtach` are the known ones — keeps
    the first client's environment exactly as tmux does, and neither arm can
    see it. `multiplexerLabels` covers what is on the wire; adding a
    multiplexer means adding its label.

  - **The plain-ssh arm (`.remoteSSHConnection`, 2026-09-05).** A Claude Code
    session in `ssh host` on an ENROLLED host, with no multiplexer and no
    browser, joins on the TCP CONNECTION its surface holds. sshd sets
    `$SSH_CONNECTION` in every session it spawns
    (`"<client-ip> <client-port> <server-ip> <server-port>"`); the remote shim
    publishes it as `X-Lvx-Env-Ssh-Connection`, with the four fields re-joined
    by COMMAS because space is outside the env-header charset and that charset
    is the whole header-injection defence — widening it for one field was
    refused. `ClaudeRemoteSSHConnectionReport.parse` validates the shape on
    arrival (exactly four fields, canonical decimal ports in 1…65535, addresses
    in `[0-9a-fA-F.:]` within 45 bytes) and trusts nothing beyond it.

    The confirmation set, ALL of it required: (1) the focused surface's tty
    hosts exactly one foreground ssh with a verified OpenSSH executable and an
    argv the parser accepts (`SSHDestinationTTYProbe`, unchanged); (2) that
    argv carries no `-J`; (3) its destination resolves to exactly one enrolled
    host (exact alias, then `ssh -G`); (4) no OTHER same-uid ssh to that
    destination is socketless (the ControlMaster mux-client shape — see the
    residuals); (5) the candidate was registered by a hook AUTHENTICATED FROM
    THAT HOST (`liveRemoteSessions(hostID:)` is scoped to its channel); (6) the
    candidate reports `$SSH_TTY` and NO multiplexer label
    (`ClaudeSessionJoinResolver.multiplexerLabels` — herdr, cmux, tmux, screen
    and zellij, walked over the wire allowlist so a label added there and
    forgotten here is a visible omission); (7) exactly one established TCP
    socket of that ssh PROCESS — read
    from this Mac's own kernel via `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`,
    same-uid, no privileges — has `localPort == client_port`,
    `peerPort == server_port` and a peer address equal to `server_ip`
    (compared as BYTES through `inet_pton`, since a dual-stack socket says
    `::ffff:a.b.c.d` where sshd says `a.b.c.d`); and (8) exactly one live
    session matches at all.

    **The trust argument, and what it does not cover.** The marker was a value
    we minted and handed back through a channel the remote host fully
    controlled and Claude Code clobbered — measured present 1.26 % of the time
    (above). This asks the remote host to name a 16-bit ephemeral port that
    only the two kernels on the ends of ONE connection know, for a connection
    whose local end this process reads out of its own kernel, and pins the
    answer to the host the hook authenticated from. A compromised enrolled host
    can still mis-describe its OWN connection — publish a second session under
    the ports of the connection the user is really looking at, and join that
    surface. It cannot claim a surface connected to a DIFFERENT host: it does
    not know that connection's client port, and the origin-host filter rejects
    it before the ports are ever compared. That is strictly more than the
    marker had, which was no boundary at all against a host that had already
    been compromised.

    UNPROVED, say it plainly: this proves which CONNECTION the focused surface
    holds, never what the remote program drew into it. A second Mac enrolled
    on the same host, dictating into its own ssh to that host, is a different
    connection with different ports and is not confused with this one — but two
    agents inside ONE ssh session share its `$SSH_CONNECTION` and are refused
    as ambiguous rather than told apart. Nothing here reads or authorizes a
    screen: `TerminalScreenClaudeJoinAuthorizer` refuses raw AX attachment for
    this mechanism (a plain ssh shell's grid is the user's whole remote
    session), `SocketPaneScreenContext` has no route for it, and a remote
    origin can never carry a `LocalWorkspacePath`. The join buys the session
    block and repo context — exactly what the marker join bought.

    RESIDUALS, none of them silent — every one has its own abstention cause:
    ProxyJump (see the next paragraph — it has three causes of its own); a host
    whose remote plugin predates 1.6.0 (it publishes no connection at all, and
    the cause names exactly that); and an unreadable fd table, which is
    UNREADABLE rather than "no sockets" —
    `SSHSurfaceConnection.sockets` is optional for that one reason.

    **ProxyJump cannot be supported by transport matching, and the reason is a
    property of unprivileged Unix rather than a gap in this code. Do not
    re-attempt the design below without reading this paragraph.**
    `ProxyJump` lives in `~/.ssh/config`, is invisible in argv, and OpenSSH
    carries it with an `ssh -W` CHILD: the surface's own ssh holds NO TCP
    socket, the child holds `mac:P1 -> J:22`, and the destination's sshd sees
    `J:P2`. Nothing on the Mac relates P1 to P2 — only the jump host J does,
    and the linkage lives in which of J's processes owns both sockets.
    MEASURED on a live Linux host, 2026-09-06: that linkage is unreachable to
    an unprivileged user. `sshd` drops to the user after auth, which makes the
    session process NON-DUMPABLE, so `/proc/<pid>/fd` is root-owned even for
    the user who owns the process (`ls /proc/<sshd-session pid>/fd` →
    `Permission denied` for 3 of 3 tried, with 6 such processes owned by that
    very user; independently replicated at 7 of 7 on OpenSSH 10.0p2 by an
    adversarial review), and `ss -tnpH state established` therefore attributes
    ZERO sshd sockets to a pid.

    The cgroup escape fails for a subtler reason than "cgroups do not work",
    and the distinction matters to anyone re-attempting this: `ss --cgroup`
    DOES attribute OUTBOUND sockets to a per-session scope
    (`/user.slice/user-N.slice/session-cNN.scope`), tty-less sshd sessions
    included. What cannot be tied to a session is the INBOUND half: an
    accepted socket carries the LISTENER's cgroup (`/init.scope`), and
    `loginctl show-session` exposes `RemoteHost` but no remote PORT — so
    `(mac, P1)`, the only handle the Mac has, reaches no session scope, and
    two windows from one Mac stay indistinguishable.

    One conditional escape exists and is deliberately not built on: on a host
    whose auth journal is user-readable, sshd logs the peer PORT together with
    the session pid (`sshd-session[NNN]: Disconnected from user dev
    192.168.1.101 port 43286`), and an auth-time `Accepted … port P1` line
    would tie `(mac, P1)` → pid → logind Leader → session scope → the
    outbound socket's local port. It is not a foundation for a trust
    boundary: journald readability and retention are per-host accidents, and
    on the very host where the review confirmed the disconnect-time lines the
    auth-time lines needed for a LIVE pairing were absent from a 496 MB,
    7-day journal.

    Without pid or cgroup linkage the only remaining rule is "J holds exactly
    one connection to the destination", which abstains for precisely the user
    who has several terminals open — the case this would exist to serve. It
    would also be sound only under conditions worth writing down before
    anyone reaches for it: scoped by UID (`/proc/net/tcp`'s uid column —
    inbound accepted sockets read uid 0, outbound read the session uid) and
    counted across EVERY address J may resolve the destination to, since a
    dual-stack or multi-A-record destination with one connection per address
    leaves each per-address count at one and lets the rule pick another
    terminal's socket. Single hop only, too: for a chain, the last hop's
    inventory is behind the same non-dumpable wall.
    So the arm NAMES the shape and declines: `ssh -G` (already cached for the
    enrolled-host fallback, and consulted ONLY on the branch that is about to
    abstain, so a joining dictation spawns nothing extra) yields
    `SSHProxyJumpShape`, and the causes are `this connection goes through a
    jump host (ProxyJump)` and `this connection goes through a chain of jump
    hosts`. The shape is a SHAPE and never the jump host's name — it reaches
    the log. `ssh -G` evaluates the user's `Match exec` blocks, so this can
    run a user-configured command, once per operand per TTL and bounded by the
    same 2 s timeout as the identity lookup — the price of asking ssh what ssh
    would do instead of reimplementing its config resolution. What would
    change the verdict: root (or a privileged helper) on the jump host, or a
    dependable auth journal there — both deployment decisions, and not
    something this app may assume.

    Two more, and both are MIS-joins rather than missed ones, which is why
    each has a positive check rather than a note:

    * **Multiplexers.** A multiplexer SERVER outlives the connection that
      started it and its panes keep that FIRST connection's `$SSH_CONNECTION`.
      MEASURED on the dev box 2026-09-05, tmux 3.x: connection A (client port
      36878) created the session, connection B (36886) attached, and a process
      inside the pane still read `SSH_CONNECTION=127.0.0.1 36878 …`, so a
      later attach would otherwise mis-join onto A's surface. The refusal is a
      property of the ARCHITECTURE, not of tmux: `screen` (`$STY`, screen(1)
      ENVIRONMENT) and `zellij` (`$ZELLIJ`) are servers in exactly the same
      shape. The first version of this arm checked herdr/cmux/tmux only and
      screen was not on the wire at all — a silent mis-join, found by review
      (2026-09-05) and closed by publishing both labels in plugin 1.6.0.
      Anything that multiplexes a terminal and does NOT publish a label the
      shim carries is still a hole; adding a multiplexer means adding its
      label, and `PlainSSHConnectionJoinTests` fails if the list and the wire
      disagree.
    * **OpenSSH ControlMaster.** `ControlMaster auto` in `~/.ssh/config` is
      invisible in argv (the probe refuses `-M`/`-S` but does not read
      config). Terminal A's ssh owns the TCP connection; terminal B's
      `ssh host` is a mux CLIENT over an AF_UNIX control path with no TCP
      socket. sshd derives `$SSH_CONNECTION` from the underlying CONNECTION,
      so B's Claude session truthfully reports A's ports — and a dictation
      into A, a plain shell with no agent in it, would join B's session. The
      check is `SSHSiblingSurvey`, carried on `SSHSurfaceConnection.siblings`:
      the other same-uid ssh CONNECTIONS to the same destination are counted
      by what the kernel could say about each, and any that is
      readable-and-socketless, or unreadable at all, abstains the arm. It
      costs the ordinary two-terminals-two-connections case nothing — those
      each hold a socket and are told apart by their ports. Found by review
      (2026-09-05).

      The survey is COUNTED rather than a boolean because the first field run
      of this arm (2026-09-06) abstained on it and the abstention could not
      say why: "a real ControlMaster client is open in another window" and
      "some ssh's fd table could not be read" are the same non-join and
      opposite fixes. They are now separate causes carrying `n of m`. ONE
      process is excluded from the survey and only one, so the abstention
      cannot be manufactured against the app itself: an ssh whose kernel
      PARENT is this app (its `RemoteForward` supervisor, its herdr `ssh -L`
      — ours, and never somebody's terminal).

      A second exclusion, for ssh processes with no controlling terminal, was
      added and REMOVED by review (2026-09-06) because it reopened the very
      mis-join the survey exists to block. `ssh -tt D claude -p …` launched by
      launchd, cron or an orchestrator has no LOCAL tty and a REMOTE pty, so
      the session it starts reports `$SSH_TTY`, carries no multiplexer label,
      and is a joinable candidate — under ControlMaster it is socketless and
      reports the master's `$SSH_CONNECTION`, so skipping it let a dictation
      into the master's window join it. The parent check already covered
      everything that exclusion was written for.

      The surface's OWN two refusals are named the same way and for the same
      reason: `this ssh holds no connection of its own (a ControlMaster client
      or a ProxyCommand)` is the readable-and-empty case — which the field
      also hit — and `this ssh's socket table is unreadable` means a syscall
      failed, which
      `SSHProcessSocketReaderCrossProcessTests` says should not happen for a
      same-user process. That test exists because the original reader tests
      only ever read `getpid()`: a reader that works on its own process alone
      passes all of them and then sees nothing for every real `ssh` on the
      machine. MEASURED on the build host 2026-09-06:
      `proc_pidinfo(PROC_PIDLISTFDS)` + `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`
      answer for a same-uid process this one did NOT spawn (`rc=792`,
      `kind=SOCKINFO_TCP`, `state=TSI_S_ESTABLISHED`), so the API is not the
      constraint and the app needs no entitlement for it.

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
  - The overlay's join badge (`OverlayClaudeJoinBadge`) DESCRIBES the resolved
    join; it never resolves one. It reads `claudeSessionJoin` after the single
    start-time resolution and nothing else — a badge that asked again could name
    a different session than the context actually attached, which is the exact
    failure the once-per-dictation rule exists to prevent. Its one extra read is
    `registry.hasLiveSessions()`, which touches no title, TTY, socket, or process
    table and only chooses between "nothing attached" and showing nothing at all.
    What it renders is a length-capped workspace `displayName` with control
    characters neutralized: a LOCAL name is the last component of a real
    directory, where a newline is legal and the panel is measured from the body
    text alone. Cc (newline, tab) becomes a space — deleting it would glue two
    runs into a directory name the user does not have — while Cf (bidi
    overrides, zero-width joiners) is dropped, being zero-width already.
    It names the joined workspace rather than showing a checkmark because a
    mis-join — the residuals documented on the cmux and remote-herdr arms — is
    invisible to a boolean and obvious next to the wrong repo's name.
    The badge travels as a PARAMETER of `startSession`, never a later setter:
    starting a session resets the panel, so a badge pushed before it was wiped
    and one pushed after depended on an order nothing enforced. It is always
    already known there — the join resolves before the realtime socket connects,
    and the panel opens after it.
  - Lookups abstain rather than guess: no match, unknown, stale, or ambiguous
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
- **A rejection's remedy is earned by its wire shape, and only one shape earns
  the plugin remedy.** `ClaudeRemoteRejectionCategory` exists because one
  undifferentiated "rejected unauthenticated connection" line cost a dispatched
  log-collection workflow to diagnose (field report, 2026-07-26). Two of its
  cases turn on a distinction that looks cosmetic and is not: a header that
  ARRIVED carrying no credential (`Bearer `, from a `${…}` Claude Code never
  expanded into an http hook) is the pre-1.1.0 plugin's exact signature and
  keeps the full "update the plugin on the host" clause; NO `Authorization`
  header at all cannot come from any plugin generation — the pre-1.1.0 manifest
  declared the header statically, and the command shim that replaced it writes
  the header before it dials and fails open without dialing when the token is
  unset — so it is an unauthenticated caller, gets its own line with no host
  remedy, logs at `.notice` rather than `.error`, and is excluded from
  `Snapshot.isEmpty` so it raises no Settings hint. That last part is not
  tidiness: the enrollment verify probe posts here WITHOUT a credential on
  purpose and reads the 401 as its success signal, so collapsing the two shapes
  made every setup check write a line accusing a healthy host — a phantom for
  the next person reading this log, in the one subsystem whose documented
  diagnostic route is reading the log later. Do not re-collapse them, and do not
  soften the `.emptyCredential` clause into vagueness to cover both: losing the
  pre-1.1.0 diagnosis is the worse failure of the two, which is why the split is
  decided by the request's own bytes rather than by any state this app keeps —
  there is no window to be outside of and nothing a caller can assert to land in
  the quieter category that it could not already assert to land in another.
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
- **A refused `RemoteForward` bind is not a diagnosis, and only a nonce
  round-trip may upgrade it to one.** OpenSSH's `remote port forwarding failed`
  says a port is held, never by whom, and the two holders want opposite things
  from the user: a stranger is a failure they must clear, while their own ssh
  session carrying the enrollment block's `RemoteForward` IS the working
  channel — the normal state for anyone who ssh's to the host they enrolled.
  Reporting the second as contention told them to close the session providing
  the tunnel (field report, 2026-08-29). `ClaudeRemoteForwardOwnershipCheck`
  separates them, and the rule about HOW is load-bearing:
  - **The remote host's answer is never the evidence.** Our 401 (and the 411 an
    empty POST gets) is public in this repository, so any process that binds
    that port can reproduce it byte for byte; and a SECOND Mac enrolled against
    the same host returns a genuine 401 of its own, which is exactly the
    contention `ClaudeRemoteForwardPort` exists to surface. A status-code probe
    would adopt both.
  - **The evidence is arrival.** The probe posts a fresh 128-bit nonce into the
    disputed port FROM the remote host (`ssh -o BatchMode=yes -o
    ClearAllForwardings=yes`, bounded timeout, the script on stdin so the nonce
    is never in the ssh argv on THIS Mac — which is also the CI runner — and no
    token, since the request is expected to be refused), and the verdict is
    whether THIS process's own listener saw that nonce
    (`ClaudeRemoteForwardProbeWitness`). A stranger receives the nonce and can
    do nothing with it: the listener binds `127.0.0.1` on the Mac and the only
    route to it from that host is a `RemoteForward` terminating here — and the
    disputed one is the forward the stranger is the reason we do not have.
    Another Mac's listener has never heard of it. The probe's exit status is
    deliberately not consulted in either direction.
  - **Two residuals, stated because the next reader will otherwise assume they
    are not there.** (1) Arrival identifies the LISTENER, not the port that
    carried the nonce: every supervised `-R` ends at the same local listener, so
    where a host has a SECOND live forward to this Mac (a legacy
    `RemoteForward 8473` left in the user's own config block and carried by an
    interactive session), a hostile holder of the disputed port can replay our
    request down that other forward and forge a match. (2) The nonce is out of
    the ssh argv but is in `curl`'s argv on the REMOTE host for the `--max-time`
    window; `--header @file` would fix that and is not used because it needs
    curl >= 7.55 on an arbitrary host and would fail silently below it. Both
    residuals require code execution on the enrolled host, which already implies
    possession of the plugin's bearer token — so `.ourListener` is a DIAGNOSIS
    and never an authorization. Do not restate either claim absolutely.
  - **Every other outcome is `portUnavailable`.** No probe wired in, no `curl`
    on the host, ssh refused, a timeout, an unparseable anything — all
    `.unproved`, which is also the default when the seam is nil. Fail closed is
    not a branch here, it is the absence of one, because the alternative is
    telling the user everything is fine while a stranger collects the remote
    plugin's bearer token from every hook.
  - **The listener's one pre-auth look is not an oracle.** The nonce check runs
    before the token because a self-probe must not land in the rejection tally
    the user reads for "which of three fixes do I need". It compares only a
    value this process minted and is still waiting for, it returns the same 401
    with the same headers and the same empty body either way, and a match
    short-circuits — so a matching nonce cannot carry a payload past
    authentication even when a valid token rides with it.
  - **A proved channel is a claim with an expiry.** `externallyForwarded` is
    held by a session the app does not own and cannot be notified about, so the
    supervisor re-attempts its own `-R` on a long injected-clock park
    (5 minutes): the session ending means the bind now succeeds and the app
    takes the tunnel over, and a holder that stops proving ownership drops back
    to `portUnavailable`. This is the ONE relaxation of "a refused bind is
    terminal" and it is bounded by that interval; a state that claims a channel
    must be able to stop claiming it.

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
  200 body that is not exactly the listener's one control JSON body — which
  since 2026-09-05 is a CONSTANT (`{"suppressOutput":true}`) carrying no field
  that could put a byte on a terminal, so there is no variable part left for a
  squatter to aim at. Note also what is NOT defensible: a
  malicious process running as the user on the REMOTE host can still read
  `~/.claude/` and therefore the plugin's token no matter what we do. Say so
  rather than implying the token bounds it.
- **The dogfood control socket is an accepted tradeoff, and the acceptance was
  bounded.** An instrumented build can expose a local AF_UNIX socket that
  starts dictations and reports what the context pipeline resolved
  (`DogfoodControlSocket`), because two things are unobservable from outside
  the process: a dictation has no deterministic trigger, and
  `ClaudeSessionRegistry` is per-process, so `--probe-surface` can only ever
  resolve against an empty registry. What makes that acceptable is a set of
  bounds, each of which is the whole argument for the one above it:
  - **`#if LOCALVOXTRAL_DOGFOOD` and nothing else.** A shipped build compiles
    none of it — no listener, no path, no code that could create one, and no
    setting or argument that turns it on.
    `DogfoodControlBuildBoundaryTests` runs in BOTH configurations (it is
    deliberately not itself gated) and fails when any reference escapes the
    flag; that is the only kind of test that can notice this leaking into a
    release. Within an instrumented build there is a SECOND runtime gate,
    `debug.dogfood_control_socket_enabled`, kept separate from the capture's:
    writing records and accepting commands are different consents.
  - **0700 directory, 0600 socket, and `getpeereid` before the first read.**
    The permissions should already make another uid unable to reach the path.
    The credential check is there because "should" is a claim about the
    filesystem, not about this process.
  - **Every value that crosses is a bool, a count, or a closed enum name.**
    `ClaudeSessionJoinSummary` is reused rather than re-mapped (its third
    consumer, after the dogfood record and `--probe-surface`), abstention
    causes are the resolver's own content-free categories, and `registry list`
    reports session SHAPES — never a session id, marker, workspace, tty, pane
    id, socket path or host. Replies pass through `DogfoodCaptureRedaction` as
    a backstop, not as the strategy.
  - **`session start` reaches `handleModifierOnlyTap`, the gesture's own
    handler.** It is subject to the Secure Keyboard Entry refusal, the
    Accessibility state, the microphone gate and backend readiness exactly as a
    real trigger is; a refusal is REPORTED, never overridden. The only thing
    added on top is another refusal (a start while dictating would toggle the
    session off). It is also CAPPED — auto-stopped after a bounded window on an
    injected clock — so a client that disconnects mid-dictation cannot leave
    the app recording, and every exit path releases the cap.
  - **Nothing can be injected.** No command carries a surface, a session, a tty
    or a join. Every verb observes real resolution; a socket that could
    fabricate one would answer questions about itself.
  - Unlike `--probe-surface`, `surface probe` wires the app's FULL-capability
    resolver. That is deliberate and is the reason the socket exists: the
    withholding in the one-shot verb is about a process that is a bad owner for
    a supervised `ssh -L` and a nonce lease, and the app is the good one. A
    probe that withheld them would answer a different question from the one a
    dictation asks.
