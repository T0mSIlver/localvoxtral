# Remote herdr join: agents-panel binding (design)

Status: approved by owner 2026-08-09 (token UX = live mic indicator; enrollment
= enroll-time offer; fallback = argv path with the title-marker arm suppressed
on unreadable-ssh abstentions). Supersedes the argv invocation signal as the
PRIMARY binding for `.remoteHerdrPane` joins; the argv path (#228/#229)
remains as fallback.

## Problem

The remote herdr join must prove that the FOCUSED LOCAL terminal surface is
displaying a whole-view client of a specific remote herdr server before
grounding a dictation in that server's focused pane. Until now the only
evidence was the local ssh process table: argv classification of the surface's
ssh, a machine-wide competing-view scan, and a trusted-executable list. That
inference fails closed in many innocent configurations (Ghostty's
shell-integration ssh wrapper injects `-o` options; the manual flow — `ssh
host`, then typing `herdr` — carries no argv signal at all; cross-uid ssh
processes are unreadable and abstain everything).

A window-title nonce probe was considered and REJECTED by the owner: title
flicker is unacceptable UX.

## Mechanism

herdr (verified in source at v0.8.x, checkout `../herdr`) provides everything
needed with no upstream change:

1. **Write channel** — `pane.report_metadata` (handler
   `src/app/api/panes.rs:1260`) sets arbitrary custom tokens on a pane:
   `{"method":"pane.report_metadata","params":{"pane_id":"…",
   "source":"localvoxtral","tokens":{"lvmark":"<token>"},"ttl_ms":8000}}`.
   Constraints (`src/app/api_helpers.rs:205-282`): key
   `^[A-Za-z0-9_-]{1,32}$`, value ≤80 chars with control chars stripped,
   TTL 1..86_400_000 ms, self-clearing on expiry; empty or null value clears
   (verified: `normalize_metadata_tokens` treats both as a clear).
   Token patches ignore agent guards; no official herdr integration writes
   custom tokens, so a private key is uncontested.
2. **Render** — the bottom-left agents panel (`src/ui/sidebar.rs:1423`)
   renders configured rows per agent-bearing pane. Custom tokens render ONLY
   when the user's herdr config adds a row for them:

   ```toml
   [ui.sidebar.agents]
   rows = [["state_icon", "workspace", "tab"], ["agent"], [{ token = "$lvmark", dim = true }]]
   ```

   A row whose tokens are all absent is elided entirely
   (`src/ui/sidebar/tokens.rs:84-86`), so the row is invisible except while we
   set it. Applied live via `herdr server reload-config`.
3. **Read channel** — the existing local screen capture route
   (`TerminalScreenAXReader`; Ghostty's single-AXTextArea grid, iTerm2 /
   Terminal.app capture equivalents) reads the rendered TUI text of the
   focused surface, agents panel included. This is a one-shot read at join
   time to locate the token — NOT a screen-context attachment; the existing
   refusal of raw AX attachment for `.remoteHerdrPane` joins stands.

## The trust argument

Why a grid match is sufficient evidence, to the standard of review rounds 1–7:

- **App-mode discriminator.** The server's render loop
  (`src/server/headless.rs:4074-4190`) paints the full UI (sidebar included)
  for every App-mode client and ONLY the raw terminal for
  `terminal_attach`/`terminal_observe` clients. A surface whose grid shows the
  panel token is therefore a WHOLE-VIEW client of the server that owns the
  socket we stamped — single-pane attaches and observers structurally cannot
  match. This is the discriminator #229 approximated with argv
  classification, obtained directly.
- **Server-global focus makes client identity irrelevant.** All App-mode
  clients mirror one shared `AppState`; per-client divergence is size and
  scroll only (`tests/multi_client.rs`). Two local surfaces showing the same
  server would render the same token, and joining either is the same join —
  the #229 insight, unchanged. We read only the FOCUSED surface's grid, so
  the dictation grounds where the user is looking.
- **Nonce freshness bounds forgery.** The token value is a fresh random nonce
  per join attempt (≥40 bits, ASCII `[a-z0-9]`, full rendered string ≤20
  chars including a fixed `lv-` prefix), transmitted only over the forwarded
  unix socket (mode-checked, owner-checked — existing `HerdrSocketClient`
  guards). A process that merely prints plausible-looking panel text cannot
  know the nonce. An observer who CAN see the nonce is an attached client of
  that server or a reader of its socket — already inside the trust boundary
  this join accepts (it is about to ground dictation in that server's focused
  pane). Remote-influenceable grid text is therefore not a forgeable
  authorization input: matching requires knowledge only trusted parties have,
  within an ~8 s TTL window.
- **Failure direction.** Every failure mode is a NO-MATCH → abstain → argv
  fallback: sidebar collapsed (collapsed-compact renders 4 cols, no text),
  client width ≤ 64 (mobile layout, no sidebar), panel row not configured,
  entry scrolled out of the panel body, modal overlay painted over the
  sidebar, AX read unavailable. The probe can only fail to join; it can never
  join a surface that is not displaying the stamped server.

## Join-time sequence (replaces argv classification + competing-view for the primary path)

1. Determine candidate hosts. If the surface's ssh argv is readable, its
   destination selects the enrolled host as today — this includes the manual
   flow (`ssh host`, then typing `herdr`: the argv is a plain readable ssh).
   If an ssh IS present but unreadable (a wrapper the parser refuses), fall
   back to SPECULATIVE candidates: every enrolled host that has live remote
   sessions reporting a herdr pane (registry), bounded to ≤3 hosts, tried
   sequentially. This bound is a guideline the implementer may tighten,
   never widen. A surface with NO ssh at all NEVER probes (amended
   2026-08-09 over the original draft): a local shell is the overwhelmingly
   common dictation target, and probing it would pay cold-forward latency
   per candidate and flash nonces in remote panels the user is not looking
   at. The accepted cost: an inner ssh on another pty (tmux nesting) stays
   unjoinable until a warm-forward-only speculative mode exists (recorded
   follow-up).
2. Per candidate host (existing machinery): open the forward, apply the
   single-socket rule (unchanged in this PR; per-socket distinct nonces can
   lift it later — noted as follow-up, out of scope), query `pane_current`,
   find the unique candidate session claiming the focused pane (existing
   logic, unchanged).
3. Stamp: `pane.report_metadata` on that pane with `tokens:{lvmark:
   "lv-<nonce>"}`, `source:"localvoxtral"`, `ttl_ms:8000`.
4. Read the focused surface's grid once; require the exact rendered token as
   a contiguous string. Allow a short bounded settle (herdr must paint, the
   terminal must render; ≤2 polls with injected clock — NO wall-clock sleeps
   in tests, use the `now:`/`sleepFor:` seam pattern of
   `OverlayBufferSessionCoordinator`).
5. On match: proceed with the UNCHANGED downstream confirmations — broker
   marker in the pane's `terminal_title`, `agent_session` claim agreement,
   foreground process check. The panel token AUTHORIZES the surface binding;
   it does not replace pane-level session confirmation.
6. Two candidate hosts matching in one grid (distinct nonces both present):
   abstain. Should be impossible; abstention is the correct posture.
7. On no-match after the bounded settle: fall through to the argv path with
   #228/#229 semantics exactly.

## Live mic indicator (owner decision)

After a successful join, keep the token alive for the dictation as a visible
mic indicator: refresh `pane.report_metadata` with the SAME token every ~4 s
(`ttl_ms:8000` — TTL is the backstop, refresh keeps it lit), and clear
explicitly (empty or null value) on dictation stop, session end, or join teardown.
The rendered value may carry a short static prefix so the row reads as a mic
indicator rather than line noise (e.g. `lv-mic-<nonce>` if ≤20 chars renders
intact at herdr's default sidebar width 26 — verify against the row budget:
24/22 cols first/continuation row, prefix-truncation only). Refresh timers
must be injected-clock, never wall-clock, and must not outlive the session
(see PR #66 timer debt — do not add more armed wall-clock timers).

## Title-marker arm suppression (owner decision)

When the ssh probe returns `.undeterminable` with a category that means "an
ssh session is present on the surface but cannot be read" —
`multipleForegroundClients`, `untrustedExecutable`, `unreadableArguments`,
`refusedArguments` — the title-marker fallback arm is SKIPPED for that
dictation. Rationale: an unreadable ssh means the surface may be a remote
session, and the outer title marker may be stale from an earlier session on
that host (the documented mis-join residual). `deviceUnreadable` /
`tableUnreadable` / `probeUnavailable` do NOT suppress the marker arm: they
mean we could not look at all, and suppressing there would break local marker
joins on machines where the probe itself is unavailable. This needs a
red/green regression test pair: stale-marker mis-join reproduced under an
unreadable-ssh probe result before the change, refused after.

## Enrollment-time config offer (owner decision)

- Enrollment (and a re-check offered when a join fails with "panel row not
  configured" symptoms — i.e. stamp succeeded, everything else healthy, grid
  shows no token) detects the missing row and OFFERS to patch the remote
  herdr config over the enrollment ssh channel, with explicit user consent in
  Settings — never silently.
- Patch rule, conservative: if the remote config has NO `[ui.sidebar.agents]`
  table, append the three-row block above verbatim, then
  `herdr server reload-config`. If the table (or a `rows` key) EXISTS, do NOT
  edit it — show the snippet and instructions instead (Settings detail +
  log; popover gets one short sentence per the owner rule, never config
  text).
- Detection of "row missing" from the Mac side is inferential (no config-read
  API): treat stamp-succeeded + grid-no-match as "likely not configured" in
  the diagnostics string, not as a proven fact — and only for
  DESTINATION-KNOWN probes. A speculative candidate's token not rendering
  usually means the user is not looking at that server; diagnosing the row
  from it would nag correctly configured hosts.

## Diagnosability

Every abstention names its cause in `Log.claudeContext` and the dogfood
join-abstention string, following #228's `SSHProbeIndeterminacy` pattern:
distinct content-free categories for at least — row-not-rendered (no token in
grid), AX-read-unavailable, forward-unavailable-for-speculative-candidate,
stamp-refused (API error), multi-host-double-match, settle-timeout. Backend
paths stay loud (`Log.backends` convention).

## Invariants doc duties (same PR)

- `docs/agent/invariants.md`: state the panel binding as the primary surface
  authorization for `.remoteHerdrPane`, with the App-mode-render and
  nonce-freshness arguments and their EXTERNAL-ASSUMPTION bounds (herdr
  upgrade obligation: re-verify that attach/observe clients still render no
  sidebar and that the panel renders identically on all App clients —
  `src/server/headless.rs` render loop, `tests/multi_client.rs`).
- Update the "manual flow gets no herdr join" accepted-cost paragraph: it is
  now closed by the panel binding when the panel is visible; the residual is
  restated (collapsed sidebar / narrow client / unconfigured row fall back to
  argv, where the manual flow still gets no join).
- The marker-arm suppression rule and its exact category set.

## Out of scope (recorded follow-ups)

- Per-socket distinct nonces to lift the single-socket-per-host abstention.
- Persistent per-host forwards (separate PR, in flight).
- Any upstream herdr change (`client.list` branch stays parked;
  Discussions-only upstream).
