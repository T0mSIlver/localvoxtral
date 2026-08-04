# Architecture map

Everything routes through `DictationViewModel` (`@MainActor`, split across
three files totaling ~2.3k lines — the main refactor target):

- `DictationViewModel.swift` — state, wiring, hotkey press/release dispatch
- `DictationViewModel+Session.swift` — session lifecycle, stop-finalization
  state machine, LLM polishing + commit path
- `DictationViewModel+RealtimeEvents.swift` — transcript event routing/merge

Key subsystems:

- Audio: `MicrophoneCaptureService` (raw CoreAudio AUHAL → 16kHz PCM16),
  `AudioChunkBuffer` (Mutex), `AudioCaptureHealthMonitor` (device changes)
- Realtime clients: `RealtimeClient` protocol; `RealtimeAPIWebSocketClient`
  (vLLM/voxmlx) over `BaseRealtimeWebSocketClient`
- Text merge: `TextMergingAlgorithms` (pure functions — overlap merge,
  word-boundary stabilization, punctuation spacing), `FirstChunkPreprocessor`
- Insertion: `TextInsertionService` (AX replace → Unicode CGEvents → Cmd+V);
  Live Auto-Paste replacements run through `LiveHoldBackReplacementStream`
  before typing — see [agent/invariants.md](agent/invariants.md) for the
  latency it costs
- Overlay: `OverlayBufferSessionCoordinator` (session + hold-before-dismiss
  timing), `OverlayBufferStateMachine`, `DictationOverlayController` (NSPanel)
- Backends: `BackendManager` lazily prepares pinned Hugging Face snapshots and
  starts the bundled Swift helpers: `localvoxtral-speechd` for ASR on port
  8471 and `localvoxtral-polishd` for polishing on port 8472. Supervisors
  spawn, health-check, and stop both managed processes; launch cleanup removes
  retired app-managed backend artifacts from existing installs. User-facing
  backend copy (pinned models, fork optimizations, vLLM example) lives in
  [under-the-hood.md](under-the-hood.md); keep it in sync when pins change.
- Settings/config: `SettingsStore` (UserDefaults), `AppConfigStore` (TOML at
  `~/Library/Application Support/localvoxtral/config`)
- Hotkey: `HotKeyManager` (Carbon, single global hotkey)
- Claude Code session context (`Sources/ClaudeContext*`, `Sources/localvoxtral/ClaudeContext/`,
  `integrations/claude-code/`): off-screen context for dictation into Claude
  Code. Two plugins in one marketplace, structurally separate — never modes of
  each other. Both declare hooks only (no skill/command/agent/statusLine —
  nothing that spends the user's tokens).
  - **Local** (`localvoxtral`): each hook runs `localvoxtral-claude-hook` as a
    CHILD (never `exec` — the shim must outlive a publisher that cannot start,
    or the exec failure becomes the hook's exit code and fail-open stops being
    open). It publishes one bounded NDJSON line to a private AF_UNIX socket and
    fails open (silent exit 0) whenever the app is absent. In-app,
    `ClaudeContextBroker` verifies peer UID *before reading*, and only ever
    unlinks a socket it has PROVED stale by connect-probe — a second live
    instance owns its socket legitimately.
  - **Remote** (`localvoxtral-remote`, installed on the REMOTE host): command
    hooks running the bundled POSIX-sh shim `hooks/post.sh`, which curls the
    event JSON to `127.0.0.1:<port>/v1/hook/<Event>` through an OpenSSH
    `RemoteForward` — no localvoxtral binary and no `jq`/`nc`/Node on that
    host, but it does need `sh` and `curl` (fail-open when absent). That
    remote port is PER-MAC (`ClaudeRemoteForwardPort`: 28473–30472, derived
    from a per-install identity persisted in a 0600 file beside the host
    registry — not in UserDefaults, so a preferences reset cannot move an
    enrolled host's port; the shim reads it from
    `CLAUDE_PLUGIN_OPTION_PORT`, validates it, and falls back to the legacy
    8473 so pre-existing enrollments keep working). Two Macs asking one host
    for the same bind is not a tie: the FIRST connection keeps the forward and
    the second silently delivers that host's events — and its bearer token —
    to the first Mac, which 401s them, which the shim reads as a completed
    exchange (issue #215). Distinct ports make that state unreachable; what
    remains, stated in the enrollment notes, is that one host stores ONE
    `port`, so it talks to exactly one Mac. The Mac-side listener stays on
    8473. The body
    stays Claude's verbatim JSON (no `jq` to rewrite it with), so the
    allowlisted env enrichment — herdr/cmux/tmux/bridge handles, `SSH_TTY`,
    the shim's `$PPID` — rides as `X-Lvx-Env-*` HEADERS, written into the same
    0600 header file as the token and charset-whitelisted
    (`[A-Za-z0-9._:/@+,=%-]`, ≤200 bytes) before a byte is written so CR/LF
    injection is impossible by construction; the listener re-validates and
    stores them as `ClaudeRemoteSessionEnvironment`, NEVER in
    `ClaudeSessionSnapshot.process` — see the remote-opacity tradeoff in
    [agent/invariants.md](agent/invariants.md).
    A per-host opt-in (`ClaudeRemoteForwardSupervisor` +
    `ClaudeRemoteForwardCoordinator`, default off) lets the app hold that
    forward itself with a supervised `ssh -N -R`, for sessions a harness
    spawns on the host (t3 code, `claude remote-control`) that have no
    interactive terminal to hold it. That process uses
    `ExitOnForwardFailure=yes` — the opposite of the user's config block, on
    purpose: it IS the nicety, so a bind it cannot get is the detection
    signal. It never sets `ClearAllForwardings` (that clears the command-line
    `-R` too, so the tunnel is never created — measured with `ssh -G`), and it
    forces `ForkAfterAuthentication=no`, `ControlPath=none` and
    `PermitLocalCommand=no` so the user's own ssh config cannot detach,
    multiplex, or run a local command underneath it. A refused bind is
    TERMINAL (no retry storm against a port somebody else holds); an ordinary
    drop backs off exponentially, and a run that stays up long enough to
    settle clears the failure count. Listener binds first, forwards start
    second — always; stopping is the mirror. After a
    transport-level failure the shim backs off for 5 minutes (epoch stamp
    under `$XDG_RUNTIME_DIR`/`~/.cache`) for every event except
    `UserPromptSubmit`: each dial against a live forward with no app behind
    it makes the Mac-side ssh client print `connect_to …: failed.` onto the
    user's terminal — stderr the remote side can never redirect — and any
    completed HTTP exchange (even a 401) clears the backoff. It was
    `type: "http"` hooks until 2026-07-27: Claude Code expands http-hook
    header `${VAR}`s from the process environment only and never injects
    plugin userConfig options there (verified on 2.1.220), so every hook
    authenticated as `Bearer ` and was 401'd — command hooks are the only
    surface that receives `CLAUDE_PLUGIN_OPTION_TOKEN`. The shim keeps the
    token out of every argv (`curl --header @tempfile`, 0600, heredoc-written),
    and its stdout FAILS CLOSED — the mirror image of delivery failing open:
    it prints a 200 body only when it matches exactly the one grammar the
    listener can emit (`markerResponseBody` — `suppressOutput:true` plus an
    optional lvx-marker `terminalSequence`), one line, size-capped; anything
    else prints nothing. Command-hook stdout is appended to the user's prompt
    when it is not control JSON (and `additionalContext` when it is), so
    whatever answers on 8473 must never be able to put a byte into the prompt
    (owner rule 2026-07-27). `ClaudeRemoteContextListener`
    (loopback-bound POSIX, dedicated port 8473; 8471/8472 remain the managed
    backends) authenticates the Bearer token *before retaining a body* against
    `ClaudeRemoteHostRegistry` (0600 atomic file, token hashes only,
    constant-time compare, immediate revoke/rotate). No enrolled host ⇒ no port
    bound. `ClaudeRemoteEnrollmentService` generates the ssh-config snippet and
    the `claude plugin` commands; Settings can apply either only after a second,
    explicit confirmation that repeats the exact text.
  - Shared: `ClaudeSessionRegistry` (Mutex, injected clock) holds the prior
    prompt, cwd, recent files, remote snippets, and a broker-allocated marker,
    returned to the hook as an OSC 2 `terminalSequence` so the marker rides the
    PTY back into Ghostty. Response keys are allowlisted to
    `terminalSequence`/`suppressOutput` by `ClaudeHookOutput`'s shape.
    See [agent/invariants.md](agent/invariants.md) for what is deliberately
    not wired up yet.
- LLM polish: `LLMPolishingService` (chat/completions client) → in managed
  mode, the bundled `localvoxtral-polishd` helper (`PolishHelper/` package:
  MLX Swift inference + a minimal loopback OpenAI server + parent-pid
  watchdog), supervised like any managed backend on port 8472. It replaced the
  former mlx-lm helper after upstream became unmaintained (2026-07).
