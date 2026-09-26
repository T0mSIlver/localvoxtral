# Architecture map

`DictationViewModel` (`@MainActor`) is the facade the views bind to. It builds
the parts below from the collaborators the app shares, and forwards the
session state the views read. The dictation itself lives in
`DictationSessionController` (#432 step 8c):

- `DictationSessionController.swift`: session state, start and stop, the
  realtime clients, the stop's inputs to the commit
- `DictationSessionController+Session.swift`: managed-backend wait, connect
  and its timeout, stop-finalization, connection-failure handling
- `DictationSessionController+StopCommit.swift`: the stop-commit, meaning each
  output path's finish, the overlay commit and its polish task (driving
  `StopCommitCoordinator`), and the session record
- `DictationSessionController+RealtimeEvents.swift`: realtime event routing
- `DictationSessionController+Reconnect.swift`: the bounded retry run behind a
  socket that drops mid-dictation

These jobs moved out of the view model (#432 steps 1–8). Each is reached
through it or called as a pure step:

- `EnginesModel.swift`: the Engines pane behind `viewModel.engines`. Backend
  modes, the Mistral key check and model catalog, managed warmup/shutdown,
  download controls (no session path)
- `ShortcutController.swift`: `viewModel.shortcuts`, hotkey registration and
  the push-to-talk gesture
- `PermissionsCoordinator.swift`: `viewModel.permissions`, accessibility and
  microphone authorization, and the startup probe
- `SessionContextResolver.swift`: `viewModel.context`, what the session may
  capture (screen, Claude join, socket pane) and the gates on each
- `PolishContextGatherer.swift` + `RepoVocabularyGrounding.swift`: everything
  the commit gathers before it builds the request. Budgets, preparations, the
  repository vocabulary and the cross-source merge
- `PolishRequestAssembler.swift`: the request itself. Sections,
  pre-application, prompts, context blocks, provenance
- `PolishOutcomeClassifier.swift` (in `localvoxtralCore`): what a reply
  means for the commit. Placeholder integrity, and the failure copy for each
  error
- `StopCommitCoordinator.swift`: everything in the stop-commit that decides
  what reaches the polisher. The transcript's preparation, the profile and
  templates, the pre-task sample (clipboard, screen, join, pane), the
  gather-assemble-send step, the overlay commit, the dogfood capture record
- `TranscriptAccumulator.swift` (in `localvoxtralCore`): the transcript the
  realtime events build. Partials, finals, the live insertion a final still
  owes, promotion
- `SessionAudioPipeline.swift`: `viewModel.audio`, meaning capture, the send and
  commit loops, ducking, the input device selection

`Sources/localvoxtralCore` (#432 step 9) holds what the app computes without
AppKit:

- `TranscriptAccumulator`, `TextMergingAlgorithms`, the overlay text
  assembler, `PolishTokenGuard`, `ClipboardPayloadMacro`,
  `PolishOutcomeClassifier`, the connection-failure classifier, `SessionClock`
- the vocabulary matching: `RepoVocabulary`, `RepoIndexing`,
  `RepoVocabularyMatcher`, `ClipboardVocabulary`, `DoubleMetaphone`
- `MistralStreamHealth`, `AudioChunkBuffer`, `ClaudeStatuslineCombine`,
  `FirstChunkPreprocessor`, `LaunchWindowPolicy`, `AppWindowOpener`, `POSIXPipeRead`,
  `PipeLineReader`, `OverlayStableLineWrapper`, `PolishContextExcerptSelector`,
  `PolishContextPreparation`
- the clipboard reader's rules (`PolishContextClipboardReader`; its
  pasteboard half stays in the app)
- the model catalogs (`BackendCatalog`, `SpeechModelCatalog`, `PolishModelCatalog`)
- the Claude session snapshot and its reducer (`ClaudeSessionState`)
- the config store (`AppConfigStore`, `BundledConfigDefaultHistory`,
  `SpeakerTerms`). The app hands it the resource bundle, and on Linux it
  hashes with `PortableSHA256` instead of CryptoKit
- the live replacement rewriters (`LiveReplacementCorrector`,
  `LiveHoldBackReplacementStream`)
- the Claude socket guard (`ClaudeSocketGuard`: `getpeereid` and
  `LOCAL_PEERPID` on Darwin, `SO_PEERCRED` on Linux), with the SHA-256 and
  HMAC helpers the Claude code hashes through
- the realtime clients: the `RealtimeClient` protocol, its event types and
  both websocket clients (#637). On Linux they speak through
  `FoundationNetworking`, whose upgrade and cancel differ from Apple's; the
  base client's comments say how. The Mistral client reports usage through
  `MistralRealtimeUsageRecording`, so the ledger and its price table stay in
  the app.

`Sources/localvoxtralCore/ClaudeContext` holds the part of the Claude context
path that needs no AppKit (#591): the join resolver and its arms, the session
registry and store, the broker and the remote listener, the herdr and cmux
clients, the ssh forward and enrollment, the repository collector and its
selection, the context blocks, and the plugin, statusline, opencode, Vibe and
Codex installers. The settings model, the forward coordinator and supervisor
(`@Observable`) and the `--probe-surface` command stay in
`Sources/localvoxtral/ClaudeContext`.

The core builds and tests on Linux (`scripts/core-tests-linux.sh`), and the
app re-exports it. Test doubles that need only the core live in
`Tests/localvoxtralTestSupport`, a library both test targets depend on. A
Linux test process that links it ignores SIGPIPE; Darwin suppresses SIGPIPE
per descriptor instead.

Key subsystems:

- Audio: `MicrophoneCaptureService` (raw CoreAudio AUHAL → 16kHz PCM16),
  `AudioChunkBuffer` (Mutex), `AudioCaptureHealthMonitor` (device changes),
  `AudioDuckingController` + `SystemOutputVolumeControl` (fades other audio
  down for the session and back up on every path that ends it)
- Realtime clients: `RealtimeClient` protocol; `RealtimeAPIWebSocketClient`
  (managed speechd / vLLM / any OpenAI-Realtime server) and
  `MistralRealtimeWebSocketClient` (Mistral API mode), both over
  `BaseRealtimeWebSocketClient`. `DictationSessionController.activeRealtimeClient`
  latches one of them per session from `settings.dictationBackendMode`. When a
  socket drops on its own mid-dictation, the session retries it on a bounded
  backoff (`RealtimeReconnectPolicy`) against the endpoint/key/model snapshot
  it started on, and holds the gap's audio in `AudioChunkBuffer` for replay.
  [agent/invariants.md](agent/invariants.md) lists what the retry may and may
  not touch
- Text merge: `TextMergingAlgorithms` (pure functions: overlap merge,
  word-boundary stabilization, punctuation spacing), `FirstChunkPreprocessor`
- Insertion: `TextInsertionService` (AX replace, falling back to Unicode
  CGEvents, then Cmd+V). Live Auto-Paste replacements run through
  `LiveHoldBackReplacementStream` before typing;
  [agent/invariants.md](agent/invariants.md) gives the latency it costs
- Overlay: `OverlayBufferSessionCoordinator` (session + hold-before-dismiss
  timing), `OverlayBufferStateMachine`, `DictationOverlayController` (NSPanel),
  `OverlayManualPlacement` (the dragged position, stored per display and
  re-validated against the attached ones before use)
- Backend modes: `BackendMode` is per engine: `managedLocal`, `externalURL`,
  `mistralAPI`. Only the managed mode runs a supervised helper. The two hosted
  modes are pure configuration (`SettingsStore.resolvedWebSocketURL` /
  `llmPolishingConfiguration` resolve endpoint, model, key and request shape)
- Backends: `BackendManager` lazily prepares pinned Hugging Face snapshots and
  starts the bundled Swift helpers: `localvoxtral-speechd` for ASR on port
  8471 and `localvoxtral-polishd` for polishing on port 8472. Supervisors
  spawn, health-check, and stop both managed processes. At launch, a cleanup
  removes retired app-managed backend artifacts from existing installs. The
  user-facing backend copy (pinned models, fork optimizations, vLLM example)
  lives in [under-the-hood.md](under-the-hood.md); keep it in sync when pins
  change.
- Settings/config: `SettingsStore` (UserDefaults, plus a `SecretStoring` seam,
  `KeychainSecretStore`, that keeps the three API keys out of the plist and in
  the login Keychain), `AppConfigStore` (TOML at
  `~/Library/Application Support/localvoxtral/config`)
- Hotkey: `HotKeyManager` (Carbon, single global hotkey)
- Claude Code session context (`Sources/ClaudeContext*`, `Sources/localvoxtral*/ClaudeContext/`,
  `integrations/claude-code/`): off-screen context for dictation into Claude
  Code. One marketplace holds two plugins. They are structurally separate,
  never modes of each other. Both declare hooks only (no
  skill/command/agent/statusLine, nothing that spends the user's tokens). The
  OPT-IN connection indicator for Claude Code's status line is user-wired,
  never plugin-declared. Locally, the user points their own `statusLine`
  setting at the publisher binary's `--statusline` mode. Remotely, they point
  it at a copy of the remote plugin's `statusline.sh`, which renders the
  outcome post.sh stamped for the last hook dial and never dials anything
  itself.
  - **Local** (`localvoxtral`): each hook runs `localvoxtral-claude-hook` as a
    CHILD, never through `exec`. The shim must outlive a publisher that cannot
    start; with `exec`, the failure would become the hook's exit code and
    fail-open would stop being open. The hook publishes one bounded NDJSON
    line to a private AF_UNIX socket and fails open (silent exit 0) whenever
    the app is absent. In the app, `ClaudeContextBroker` verifies the peer UID
    *before reading*. It only ever unlinks a socket it has PROVED stale by
    connect-probe, because a second live instance owns its socket legitimately.
    The `localvoxtral` command (`Sources/localvoxtral-cli`, #721) asks on the
    same socket; `AgentCLIService` answers from the history store, the
    learned terms and Settings (`AgentCLIAppDataSource`).
  - **Remote** (`localvoxtral-remote`, installed on the REMOTE host): command
    hooks run the bundled POSIX-sh shim `hooks/post.sh`, which curls the
    event JSON to `127.0.0.1:<port>/v1/hook/<Event>` through an OpenSSH
    `RemoteForward`. That host needs no localvoxtral binary and no
    `jq`/`nc`/Node, but it does need `sh` and `curl` (fail-open when absent).

    The remote port is PER-MAC (`ClaudeRemoteForwardPort`: 28473–30472). It
    derives from a per-install identity persisted in a 0600 file beside the
    host registry, not in UserDefaults, so a preferences reset cannot move an
    enrolled host's port. The shim reads the port from
    `CLAUDE_PLUGIN_OPTION_PORT`, validates it, and falls back to the legacy
    8473 so pre-existing enrollments keep working. Two Macs asking one host
    for the same bind is not a tie. The FIRST connection keeps the forward,
    and the second silently delivers that host's events, and its bearer
    token, to the first Mac. The first Mac 401s them, and the shim reads that
    as a completed exchange (issue #215). Distinct ports make that state
    unreachable. What remains, stated in the enrollment notes, is that one
    host stores ONE `port`, so it talks to exactly one Mac. The Mac-side
    listener stays on 8473.

    The body stays Claude's verbatim JSON (there is no `jq` to rewrite it
    with), so the allowlisted env enrichment rides as `X-Lvx-Env-*` HEADERS.
    It carries herdr/cmux/tmux/screen/zellij/bridge handles; `SSH_TTY`;
    `SSH_CONNECTION` (re-joined with commas, since space is outside the
    charset); `LC_LVX_TTY`; the shim's `$PPID`; and the basename of the
    session's repository's main checkout (the learned-terms key, #652).
    `LC_LVX_TTY` is the CLIENT's tty, which the user's shell exports and ssh's
    `SendEnv`/`AcceptEnv LC_*` carries. It is the one value here that
    describes the Mac.

    The shim writes them into the same 0600 header file as the token, and
    charset-whitelists them (`[A-Za-z0-9._:/@+,=%-]`, ≤200 bytes) before a
    byte is written, so CR/LF injection is impossible by construction. The
    listener re-validates them and stores them as
    `ClaudeRemoteSessionEnvironment`, NEVER in `ClaudeSessionSnapshot.process`.
    [agent/invariants.md](agent/invariants.md) explains the remote-opacity
    tradeoff.

    A remote project's terms (#641) are the one thing the Mac asks a host
    to run. `RemoteProjectTermRequests` marks a joined session, the next
    hook's reply carries `X-Lvx-Terms: wanted`, and the shim starts
    `hooks/terms.sh` detached. Its answer comes back on `POST /v1/terms` and
    is filed under the project the Mac recorded.

    A per-host opt-in (`ClaudeRemoteForwardSupervisor` +
    `ClaudeRemoteForwardCoordinator`, default off) lets the app hold that
    forward itself with a supervised `ssh -N -R`. It serves sessions a harness
    spawns on the host (t3 code, `claude remote-control`) and Claude Desktop,
    whose ssh clears every forward; none of these has an interactive terminal
    to hold the forward. That process uses `ExitOnForwardFailure=no`, like the
    user's config block, and acts only on a refusal that names its own port.
    It inherits every `RemoteForward` the alias declares, and a refusal of
    another one must not cost its own tunnel. It never sets
    `ClearAllForwardings`: that clears the command-line `-R` too, so the
    tunnel is never created (measured with `ssh -G`). It forces
    `ForkAfterAuthentication=no`, `ControlPath=none` and
    `PermitLocalCommand=no` so the user's own ssh config cannot detach,
    multiplex, or run a local command underneath it.

    A refused bind never enters the restart backoff, so there is no retry
    storm against a port somebody else holds. The forward parks and re-dials
    every 5 minutes, and first asks whether the port is OURS. A refused bind
    means only "somebody holds it". On a host the user actually ssh's to, that
    somebody is normally their own session carrying the same `RemoteForward`
    out of `~/.ssh/config`, which is the working tunnel.
    `ClaudeRemoteForwardOwnershipCheck` tells the two apart. It sends a fresh
    nonce down the disputed port from the remote host and asks whether this
    Mac's own listener saw it arrive (`ClaudeRemoteForwardProbeWitness`). A
    status code would prove nothing, since a stranger can reproduce ours and a
    SECOND Mac answers an honest 401 of its own. Proof gives
    `externallyForwarded`, which is not a failure; it is re-proved on a long
    park so a session that ends is noticed. Anything unproved is
    `portUnavailable`, on the same park. An ordinary drop backs off
    exponentially, and a run that stays up long enough to settle clears the
    failure count. On wake and on a network-path change
    (`ClaudeRemoteForwardRecoveryTriggers`) every failed or parked forward
    starts over. The listener always binds first and the forwards start
    second; stopping runs in the reverse order.

    After a transport-level failure the shim backs off for 5 minutes (epoch
    stamp under `$XDG_RUNTIME_DIR`/`~/.cache`) for every event except
    `UserPromptSubmit`, `SessionStart` and `SessionEnd`. Each dial against a
    live forward with no app behind it makes the Mac-side ssh client print
    `connect_to …: failed.` onto the user's terminal, as stderr the remote
    side can never redirect. Any completed HTTP exchange (even a 401) clears
    the backoff.

    The hooks were `type: "http"` until 2026-07-27. Claude Code expands
    http-hook header `${VAR}`s from the process environment only and never
    injects plugin userConfig options there (verified on 2.1.220), so every
    hook authenticated as `Bearer ` and was 401'd. Command hooks are the only
    hook type that receives `CLAUDE_PLUGIN_OPTION_TOKEN`. The shim keeps the
    token out of every argv (`curl --header @tempfile`, 0600,
    heredoc-written).

    The shim's stdout FAILS CLOSED, the mirror image of delivery failing open.
    It prints a 200 body only when it matches exactly the one body the
    listener can emit (`hookResponseBody`, the constant
    `{"suppressOutput":true}`), on one line, size-capped. Anything else prints
    nothing. Claude Code appends command-hook stdout to the user's prompt when
    it is not control JSON (and to `additionalContext` when it is), so
    whatever answers on 8473 must never be able to put a byte into the prompt
    (owner rule 2026-07-27).

    `ClaudeRemoteContextListener` (loopback-bound POSIX, dedicated port 8473;
    8471/8472 remain the managed backends) authenticates the Bearer token
    *before retaining a body* against `ClaudeRemoteHostRegistry` (0600 atomic
    file, token hashes only, constant-time compare, immediate revoke/rotate).
    With no enrolled host, no port is bound. `ClaudeRemoteEnrollmentService`
    generates the ssh-config snippet and the `claude plugin` commands.
    Settings can apply either only after a second, explicit confirmation that
    repeats the exact text.
  - Shared: `ClaudeSessionRegistry` (Mutex, injected clock) holds the prior
    prompt, cwd, recent files and remote snippets, keyed by session id, which
    is the only handle there is. A hook reply is a RECEIPT (`v` + `accepted`)
    and the remote listener's body is a constant, so neither can put a byte on
    a terminal. The window-title marker that used to travel over the PTY back
    into Ghostty was removed on 2026-09-05 (see
    [agent/invariants.md](agent/invariants.md)).

    The plain-ssh join arm (`ClaudeSessionJoinMechanism.remoteSSHConnection`)
    replaced the one session shape that marker alone served. The focused
    surface's foreground ssh process has an established TCP socket
    (`SSHProcessSocketReader` reads it out of this Mac's own kernel). That
    socket must name the same client port, server address and server port
    that the remote session reports through `$SSH_CONNECTION`. The session
    must also have been registered by a hook authenticated from the very host
    that ssh goes to. The arm authorizes session and repo context, never a
    screen read. It abstains on `-J`, on any multiplexer label (a
    tmux/screen/zellij/herdr server keeps the FIRST connection's
    `$SSH_CONNECTION`), on a ControlMaster-shaped neighbour, and on any
    ambiguity.

    `.remoteLocalTTY` is tried BEFORE it and is the arm that serves the
    configs people have. The surface's tty must equal the `$LC_LVX_TTY` the
    session reports. That value travels in ssh per SESSION CHANNEL, so it passes
    through ProxyJump and ControlMaster alike, and the arm needs no socket at
    all. [agent/invariants.md](agent/invariants.md) lists what is deliberately
    not wired up yet.
- LLM polish: `LLMPolishingService` (chat/completions client). In managed
  mode it talks to the bundled `localvoxtral-polishd` helper (`PolishHelper/`
  package: MLX Swift inference + a minimal loopback OpenAI server +
  parent-pid watchdog), supervised like any managed backend on port 8472. It
  replaced the former mlx-lm helper after upstream became unmaintained
  (2026-07).
