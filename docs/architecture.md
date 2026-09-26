# Architecture map

`DictationViewModel` (`@MainActor`) is the facade the views bind to: it builds
the parts below from the collaborators the app shares, and forwards the
session state the views read. The dictation itself lives in
`DictationSessionController` (#432 step 8c):

- `DictationSessionController.swift` — session state, start and stop, the
  realtime clients, the stop's inputs to the commit
- `DictationSessionController+Session.swift` — managed-backend wait, connect
  and its timeout, stop-finalization, connection-failure handling
- `DictationSessionController+StopCommit.swift` — the stop-commit: each
  output path's finish, the overlay commit and its polish task (driving
  `StopCommitCoordinator`), the session record
- `DictationSessionController+RealtimeEvents.swift` — realtime event routing
- `DictationSessionController+Reconnect.swift` — the bounded retry run behind a
  socket that drops mid-dictation

Jobs lifted out of the view model, each reached through it or called as a
pure step (#432 steps 1–8):

- `EnginesModel.swift` — the Engines pane behind `viewModel.engines`: backend
  modes, the Mistral key check and model catalog, managed warmup/shutdown,
  download controls (no session path)
- `ShortcutController.swift` — `viewModel.shortcuts`: hotkey registration and
  the push-to-talk gesture
- `PermissionsCoordinator.swift` — `viewModel.permissions`: accessibility and
  microphone authorization, and the startup probe
- `SessionContextResolver.swift` — `viewModel.context`: what the session may
  capture (screen, Claude join, socket pane) and the gates on each
- `PolishContextGatherer.swift` + `RepoVocabularyGrounding.swift` — everything
  the commit gathers before it builds the request: budgets, preparations, the
  repository vocabulary and the cross-source merge
- `PolishRequestAssembler.swift` — the request itself: sections,
  pre-application, prompts, context blocks, provenance
- `PolishOutcomeClassifier.swift` (in `localvoxtralCore`) — what a reply
  means for the commit: placeholder integrity, and the failure copy for each
  error
- `StopCommitCoordinator.swift` — everything in the stop-commit that decides
  what reaches the polisher: the transcript's preparation, the profile and
  templates, the pre-task sample (clipboard, screen, join, pane), the
  gather-assemble-send step, the overlay commit, the dogfood capture record
- `TranscriptAccumulator.swift` (in `localvoxtralCore`) — the transcript the
  realtime events build: partials, finals, the live insertion a final still
  owes, promotion
- `SessionAudioPipeline.swift` — `viewModel.audio`: capture, the send and
  commit loops, ducking, the input device selection

`Sources/localvoxtralCore` (#432 step 9) holds what the app computes without
AppKit: `TranscriptAccumulator`, `TextMergingAlgorithms`, the overlay text
assembler, `PolishTokenGuard`, `ClipboardPayloadMacro`,
`PolishOutcomeClassifier`, the connection-failure classifier, `SessionClock`,
and the vocabulary matching: `RepoVocabulary`, `RepoIndexing`,
`RepoVocabularyMatcher`, `ClipboardVocabulary`, `DoubleMetaphone`. Also
`MistralStreamHealth`, `AudioChunkBuffer`, `ClaudeStatuslineCombine`,
`FirstChunkPreprocessor`, `LaunchWindowPolicy`, `AppWindowOpener`, `POSIXPipeRead`,
`PipeLineReader`, `OverlayStableLineWrapper`, `PolishContextExcerptSelector`,
`PolishContextPreparation`, and the clipboard reader's rules
(`PolishContextClipboardReader`; its pasteboard half stays in the app), and the model
catalogs (`BackendCatalog`, `SpeechModelCatalog`, `PolishModelCatalog`), and the
Claude session snapshot and its reducer (`ClaudeSessionState`), and the
config store (`AppConfigStore`, `BundledConfigDefaultHistory`, `SpeakerTerms`;
the app hands it the resource bundle, and on Linux it hashes with
`PortableSHA256` instead of CryptoKit), and the live replacement rewriters
(`LiveReplacementCorrector`, `LiveHoldBackReplacementStream`), and the Claude
socket guard (`ClaudeSocketGuard`: `getpeereid` and `LOCAL_PEERPID` on Darwin,
`SO_PEERCRED` on Linux), with the SHA-256 and HMAC helpers the Claude code
hashes through, and the `RealtimeClient` protocol and its event types.
`Sources/localvoxtralCore/ClaudeContext` holds the part of the Claude context
path that needs no AppKit (#591): the join resolver and its arms, the session
registry and store, the broker and the remote listener, the herdr and cmux
clients, the ssh forward and enrollment, the repository collector and its
selection, the context blocks, and the plugin, statusline, opencode and Vibe
installers. The settings model, the forward coordinator and supervisor
(`@Observable`) and the `--probe-surface` command stay in
`Sources/localvoxtral/ClaudeContext`.
It builds and tests on Linux (`scripts/core-tests-linux.sh`); the app
re-exports it. Test doubles that need only the core live in
`Tests/localvoxtralTestSupport`, a library both test targets depend on; a
Linux test process that links it ignores SIGPIPE, which Darwin suppresses per
descriptor instead.

Key subsystems:

- Audio: `MicrophoneCaptureService` (raw CoreAudio AUHAL → 16kHz PCM16),
  `AudioChunkBuffer` (Mutex), `AudioCaptureHealthMonitor` (device changes),
  `AudioDuckingController` + `SystemOutputVolumeControl` (fades other audio
  down for the session and back at every end path)
- Realtime clients: `RealtimeClient` protocol; `RealtimeAPIWebSocketClient`
  (managed speechd / vLLM / any OpenAI-Realtime server) and
  `MistralRealtimeWebSocketClient` (Mistral API mode), both over
  `BaseRealtimeWebSocketClient`. `DictationSessionController.activeRealtimeClient`
  latches one of them per session from `settings.dictationBackendMode`. A
  socket that drops on its own mid-dictation is retried on a bounded backoff
  (`RealtimeReconnectPolicy`) against the endpoint/key/model snapshot the
  session started on, with the gap's audio held in `AudioChunkBuffer` for
  replay — see [agent/invariants.md](agent/invariants.md) for what the retry
  may and may not touch
- Text merge: `TextMergingAlgorithms` (pure functions — overlap merge,
  word-boundary stabilization, punctuation spacing), `FirstChunkPreprocessor`
- Insertion: `TextInsertionService` (AX replace → Unicode CGEvents → Cmd+V);
  Live Auto-Paste replacements run through `LiveHoldBackReplacementStream`
  before typing — see [agent/invariants.md](agent/invariants.md) for the
  latency it costs
- Overlay: `OverlayBufferSessionCoordinator` (session + hold-before-dismiss
  timing), `OverlayBufferStateMachine`, `DictationOverlayController` (NSPanel),
  `OverlayManualPlacement` (the dragged position, stored per display and
  re-validated against the attached ones before use)
- Backend modes: `BackendMode` is per engine — `managedLocal`, `externalURL`,
  `mistralAPI`. Only the managed mode runs a supervised helper; the two hosted
  modes are pure configuration (`SettingsStore.resolvedWebSocketURL` /
  `llmPolishingConfiguration` resolve endpoint, model, key and request shape)
- Backends: `BackendManager` lazily prepares pinned Hugging Face snapshots and
  starts the bundled Swift helpers: `localvoxtral-speechd` for ASR on port
  8471 and `localvoxtral-polishd` for polishing on port 8472. Supervisors
  spawn, health-check, and stop both managed processes; launch cleanup removes
  retired app-managed backend artifacts from existing installs. User-facing
  backend copy (pinned models, fork optimizations, vLLM example) lives in
  [under-the-hood.md](under-the-hood.md); keep it in sync when pins change.
- Settings/config: `SettingsStore` (UserDefaults, plus a `SecretStoring` seam —
  `KeychainSecretStore` — that keeps the three API keys out of the plist and in
  the login Keychain), `AppConfigStore` (TOML at
  `~/Library/Application Support/localvoxtral/config`)
- Hotkey: `HotKeyManager` (Carbon, single global hotkey)
- Claude Code session context (`Sources/ClaudeContext*`, `Sources/localvoxtral*/ClaudeContext/`,
  `integrations/claude-code/`): off-screen context for dictation into Claude
  Code. Two plugins in one marketplace, structurally separate — never modes of
  each other. Both declare hooks only (no skill/command/agent/statusLine —
  nothing that spends the user's tokens). The OPT-IN connection indicator for
  Claude Code's status line is user-wired, never plugin-declared: locally the
  user points their own `statusLine` setting at the publisher binary's
  `--statusline` mode; remotely at a copy of the remote plugin's
  `statusline.sh`, which renders the outcome post.sh stamped for the last hook
  dial and never dials anything itself.
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
    allowlisted env enrichment — herdr/cmux/tmux/screen/zellij/bridge handles,
    `SSH_TTY`, `SSH_CONNECTION` (re-joined with commas, since space is outside
    the charset), `LC_LVX_TTY` (the CLIENT's tty, exported by the user's shell
    and carried by ssh's `SendEnv`/`AcceptEnv LC_*` — the one value here that
    describes the Mac), the shim's `$PPID` — rides as `X-Lvx-Env-*` HEADERS, written into the same
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
    TERMINAL (no retry storm against a port somebody else holds) — unless the
    port turns out to be OURS. A refused bind means only "somebody holds it",
    and on a host the user actually ssh's to, that somebody is normally their
    own session carrying the same `RemoteForward` out of `~/.ssh/config` — the
    working tunnel. `ClaudeRemoteForwardOwnershipCheck` tells the two apart by
    sending a fresh nonce down the disputed port from the remote host and
    asking whether this Mac's own listener saw it arrive
    (`ClaudeRemoteForwardProbeWitness`); a status code would prove nothing,
    since a stranger can reproduce ours and a SECOND Mac answers an honest 401
    of its own. Proof gives `externallyForwarded` — not a failure, re-proved on
    a long park so a session that ends is noticed; anything unproved stays
    `portUnavailable`. An ordinary
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
    it prints a 200 body only when it matches exactly the one body the
    listener can emit (`hookResponseBody` — the constant
    `{"suppressOutput":true}`), one line, size-capped; anything
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
    prompt, cwd, recent files and remote snippets, keyed by session id — which
    is the only handle there is. A hook reply is a RECEIPT (`v` + `accepted`)
    and the remote listener's body is a constant, so neither can put a byte on
    a terminal; the window-title marker that used to ride the PTY back into
    Ghostty was removed on 2026-09-05 (see
    [agent/invariants.md](agent/invariants.md)). The plain-ssh join arm
    (`ClaudeSessionJoinMechanism.remoteSSHConnection`) is what replaced the one
    session shape that marker uniquely served: the focused surface's foreground
    ssh process's established TCP socket (`SSHProcessSocketReader`, read out of
    this Mac's own kernel) must name the same client port, server address and
    server port that the remote session reports through `$SSH_CONNECTION`, and
    the session must have been registered by a hook authenticated from the very
    host that ssh goes to. It authorizes session and repo context, never a
    screen read, and abstains on `-J`, on any multiplexer label (a
    tmux/screen/zellij/herdr server keeps the FIRST connection's
    `$SSH_CONNECTION`), on a ControlMaster-shaped neighbour, and on any
    ambiguity. `.remoteLocalTTY` is tried BEFORE it and is the arm that serves
    the configs people have: the surface's tty must equal the `$LC_LVX_TTY`
    the session reports, which ssh carries per SESSION CHANNEL and therefore
    through ProxyJump and ControlMaster alike. It needs no socket at all.
    See [agent/invariants.md](agent/invariants.md) for what is deliberately
    not wired up yet.
- LLM polish: `LLMPolishingService` (chat/completions client) → in managed
  mode, the bundled `localvoxtral-polishd` helper (`PolishHelper/` package:
  MLX Swift inference + a minimal loopback OpenAI server + parent-pid
  watchdog), supervised like any managed backend on port 8472. It replaced the
  former mlx-lm helper after upstream became unmaintained (2026-07).
