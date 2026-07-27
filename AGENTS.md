# localvoxtral — agent guide

Native macOS menu bar app for realtime dictation (Swift 6.2 strict concurrency,
SwiftPM, macOS 15+). Streams mic audio to an OpenAI Realtime-compatible backend
(the bundled `localvoxtral-speechd` helper in managed mode; vLLM or any
compatible server in External URL mode), merges partial transcripts, and
inserts text into the focused app — either live ("Live Auto-Paste") or via an
overlay committed on stop ("Overlay Buffer", supports replacement dictionary +
LLM polishing).

## Build & test — read this first on a non-Mac dev box

This repo only compiles on macOS. From a Linux box, the inner loop is the Mac
build host over SSH (no commit needed — it rsyncs the working tree). The host
is machine-local config, set once per clone (never committed):
`git config localvoxtral.buildhost <ssh-destination>`.

```bash
./scripts/remote-build.sh                 # build + unit tests
./scripts/remote-build.sh test --filter TextMergingAlgorithmsTests
./scripts/remote-build.sh integration     # realtime pipeline vs the live speechd STT service
./scripts/remote-build.sh eval-llm        # default polish prompt eval vs a live chat/completions server
./scripts/remote-build.sh package         # build the .app bundle (also builds both MLX helpers)
./scripts/remote-build.sh integration-polishd [hf-repo]  # bundled polish helper vs real model + eval baseline (run package first); optional repo = per-model gate for PolishModelCatalog additions (self-provisions weights)
./scripts/remote-build.sh integration-speechd [hf-repo]  # packaged speech helper vs real audio/model: accuracy + append-only deltas + parent tether (run package first)
./scripts/remote-build.sh eval-e2e [EvalRecordings/agent-dictation/<set>]  # agent-dictation E2E eval: human WAVs (optional) or TTS -> speechd -> polishd (run package first)
./scripts/run-agent-eval-local.sh [EvalRecordings/agent-dictation/<set>]   # same eval directly from a Mac checkout (run package_app.sh first)
./scripts/ablate-agent-eval.py .build/agent-eval-local.log                 # reuse one E2E log to compare pre/post-processing, prompts, and models without rerunning audio
./scripts/remote-build.sh dogfood          # build the instrumented tree + run the context-capture suite
./scripts/remote-build.sh dogfood-package  # package an instrumented .app for hand-dogfooding
./scripts/remote-build.sh build --package-path PolishHelper   # helper package alone
./scripts/remote-build.sh test  --package-path PolishHelper   # helper unit tests (Metal-free)
./scripts/remote-build.sh test  --package-path SpeechHelper   # speech helper unit tests (Metal-free)
```

The MLX helpers (`PolishHelper/` / `SpeechHelper/`, products
`localvoxtral-polishd` / `localvoxtral-speechd`) are SEPARATE SwiftPM packages
so the root build never compiles the MLX C++ core.
Two hard rules learned setting it up: (1) `swift build` of the helper
compiles but CANNOT produce working Metal kernels — only the xcodebuild lane
in `package_app.sh` can (package aggregate schemes `PolishHelper` /
`SpeechHelper`); a swift-build
binary fails at runtime loading the metallib. (2) On Xcode 26+ the Metal
compiler is a separate ~700 MB component — one-time host setup is
`xcodebuild -downloadComponent MetalToolchain` (the catalog fetch fails
transiently sometimes; retry). `xcrun --find metal` succeeding does NOT mean
the toolchain is installed; only invoking `metal` proves it.

On a Mac, just `swift build` / `swift test`.

Before starting long remote work, `./scripts/mac-health.sh` — it fails fast
with an actionable message when the Mac is asleep/unreachable instead of
letting rsync hang or CI queue forever.

Parallel agents are isolated automatically: the remote dir defaults to a
per-worktree name derived from the local checkout path. `LV_BUILD_DIR`
still overrides it when you need a specific dir. Abandoned remote dirs are
garbage-collected by the gate's `gc` verb (fired best-effort after every
run; 14-day unused window, live dirs and `EvalRecordings/` always kept), so
minting a fresh dir is cheap — never hand-clean `~/work` on the Mac.
`./scripts/remote-build.sh disk` shows per-dir sizes and last-used ages.

- An interrupted remote run can leave a stale SwiftPM lock in its remote dir —
  don't debug it, switch to a fresh `LV_BUILD_DIR`.
- Every run's full remote output lands in `.build/last-remote.log`. Never pipe
  the script itself through grep (a crash eats the failing test's name) — let
  it print, then grep the log file.

## Hand-testing & field debugging (the fast loop)

Learned the hard way (2026-07-04) — use these instead of manual steps:

- **Trying a PR build on the Mac**: `./scripts/try-pr.sh <pr-number|main>`
  downloads the exact CI-built artifact and launches it. No checkout, no
  build. Push → CI (~1.5 min) → try-pr.sh is the whole owner iteration loop.
- **Code signing (why TCC used to reset)**: `package_app.sh` signs with
  `$LOCALVOXTRAL_CODESIGN_IDENTITY` when set, else ad-hoc. The owner's Mac
  has a self-signed code-signing cert `localvoxtral-dev`; the identity env
  var is set in the owner's shell AND in the runner's `.env`
  (`~/actions-runner/.env`, restart via `cd ~/actions-runner && ./svc.sh
  stop && ./svc.sh start`). Identity-signed builds keep their Accessibility
  (TCC) grant across rebuilds; ad-hoc builds get a fresh signature each time
  and macOS silently invalidates the old grant (fix: toggle the app off/on in
  System Settings → Accessibility). First codesign with a new key needs one
  GUI "Always Allow" keychain prompt — trigger it with a local
  `package_app.sh` run before relying on CI, or the runner job hangs.
  The same identity-vs-hash rule protects the tier-2 lanes' TCC grants: the
  `com.localvoxtral.runner-node-resign` LaunchAgent re-signs the runner's
  bundled `externals/node*` with `localvoxtral-dev` after every runner
  auto-update so the Accessibility/Screen Recording grants survive
  (`scripts/mac/runner-node-resign.sh`, owner runbook `scripts/mac/README.md`).
- **macOS 26 launch stall**: first launch of a *downloaded* ad-hoc-signed
  bundle stalls forever at `_dyld_start` (Gatekeeper first-exec scan);
  `xattr -cr` does NOT fix it, a LOCAL `codesign --force --deep --sign -`
  does. `install.sh` re-signs unconditionally for end users; `try-pr.sh`
  re-signs only ad-hoc artifacts (never downgrades identity-signed ones).
  Durable fix is Developer ID + notarization (roadmap #1).
- **Field bug on the Mac? Dispatch `mac-crashlog.yml` FIRST, theorize
  second** (`gh workflow run mac-crashlog.yml --ref main`). It reports, all
  redacted for the public Actions log: recent crash summaries (procPath +
  translocation + crashed-thread frames), running localvoxtral instances
  with their binary paths, an allowlisted settings snapshot, the app's
  subsystem-filtered unified log, and an exact reproduction of the model
  pre-download command. Confirm WHICH binary the user is actually running
  (try-pr copy vs /Applications) before debugging its behavior — that
  confusion and theorize-first cost an hour on 2026-07-05. Deeper tools:
  `scripts/mac-diag.sh` on the Mac, Export Diagnostics… in Settings > About,
  and (once the v2 gate is installed — owner runbook: `scripts/mac/README.md`)
  `./scripts/remote-build.sh diag|applog|voxlog|svc-status|disk|gc`.
- **README demo video**: `./scripts/record-demo.sh` on the Mac (GUI session)
  stages the scene, drives the real Right-Command tap/hold gesture with
  synthetic CGEvents, records, and encodes `dist/demo/demo.mp4`; the operator
  speaks the prompted lines. On the self-hosted runner, dispatch
  `record-demo.yml` instead: it runs hands-free (`DEMO_HANDS_FREE=1` — TTS
  through the BlackHole loopback, app mic pinned to it) and uploads the video
  as an artifact; one-time runner setup is `brew install blackhole-2ch
  ffmpeg`. GitHub renders inline video only from user-attachments URLs (no
  API for those), so the owner drag-drops the mp4 into a PR comment and
  pastes the URL into the README by hand.
  `DEMO_TERMINAL_AGENT=herdr` (explicit only, never auto) records the herdr
  pane-join scene — split panes in an isolated named herdr session, dictation
  into the focused Claude pane, log-asserted herdr join + pane.read context.
- **Dogfooding context capture** (`Sources/localvoxtral/Dogfood`): the app logs
  context COUNTS only, on purpose, which also makes a retrieval miss
  unattributable after the fact. The capture is the gated exception — it records
  the join outcome, the screen decision and its cause, each source's harvest and
  proposals, budget demands vs. grants, the rendered prompts, and the model's
  reply, so a wrong term can be blamed on exactly one of four stages
  (retrieval / matcher / conflict / budget). It is behind a COMPILE flag
  (`LOCALVOXTRAL_DOGFOOD`, or the gitignored `.dogfood-capture-enable` marker
  that crosses the build gate) plus a runtime opt-in
  (`defaults write com.localvoxtral.app debug.dogfood_capture_enabled -bool true`).
  Shipped releases do not contain it, and there is deliberately no uploader —
  records are local files under Application Support. Use `dogfood-package` for a
  hand-testable build; it keeps the bundle id so the TCC grant survives and
  stamps `LVXDogfoodCapture` into Info.plist so you can tell which binary you
  are running.
- **Pipes from child processes**: never read with
  `FileHandle.availableData` — it raises an uncatchable ObjC exception on
  descriptor errors and aborts the app (field crash, PR #60). Use
  `POSIXPipeRead.nextChunk(fromDescriptor:)`.

## Proof culture — non-negotiable

This is a real app with daily users. Nothing ships on "it compiles".

- Every PR fills in the Proof section of the PR template with real command
  output. "CI is green" alone is not proof for a behavior change — name the
  test that demonstrates the new/fixed behavior.
- Bug fixes MUST add a regression test. Show it failing before the fix and
  passing after (two runs, both in the PR body).
- Never weaken a test to get green: no raising/lowering accuracy thresholds,
  no deleting assertions, no adding `XCTSkip`, no widening timing tolerances.
  If a test blocks you, it is telling you something — investigate or stop and
  report.
- No wall-clock in tests (`Date()` / real `Task.sleep` polling) — inject
  clocks. `OverlayBufferSessionCoordinator` (`now:` / `sleepFor:` seams) is
  the reference pattern.
- Any test that reaches `beginDictationSession` arms the REAL 10s
  connect-timeout on a process-retained view model and MUST set
  `viewModel.isShowingConnectionFailureAlert = true`, or the timer's alert
  fires inside whatever test runs ~10s later and SIGTRAPs the suite (PR #66).
  Known debt: session code arms wall-clock timers; new code must not add more.
- UI-affecting changes: until the automated UI tier exists, state in the PR
  exactly what was verified by hand and how.

## Test tiers

| Tier | What | When | Cost |
|---|---|---|---|
| 0 | Unit suite (500+ tests) + PolishHelper/SpeechHelper unit suites + packaging + launch smoke | every non-fast-path PR/push, CI (helper unit suites: self-hosted lanes only) | ~1 min |
| 1 | `RealtimeAPIVLLMIntegrationTests` vs the live local speechd STT test service: real inference through the production websocket client, word-accuracy asserted | every non-fast-path PR/push on the self-hosted runner; locally via `remote-build.sh integration` | ~20 s |
| 1 | `PolishHelperIntegrationTests`: the packaged polishing helper vs the real pinned model — production request path, shared eval baseline, parent-pid tether | conditional in CI (self-hosted, after packaging): only when the diff touches LLM-relevant paths or the PR opts in with `[run-llm-eval]` — see "When must the LLM lanes run?"; locally via `remote-build.sh integration-polishd` | minutes (4B weights + live inference) |
| 1 | `SpeechHelperIntegrationTests`: packaged speechd vs real spoken audio/model through the production realtime client — word accuracy, append-only delta/done parity, parent-pid tether | conditional in CI (self-hosted, after packaging): only when the diff touches speechd-relevant paths or the PR opts in with `[run-speechd-integration]`; locally via `remote-build.sh integration-speechd` | minutes (4B weights + live inference) |
| 2 | `ui-smoke.yml` AX smoke drill (status item, settings tabs, lazy managed-backend launch invariant); dictation-with-audio remains future work | evening lock-aware slots (18:00/19:30/21:00 UTC; `ui-smoke-guard.sh` skips green when the Mac is on battery, the screen is locked, or a slot's drill already ran and passed that day — the drill needs an unlocked GUI session) + manual on the self-hosted GUI runner | — |
| 2 | `AgentDictationE2EEvalTests` (`eval-e2e.yml`): wide agent-dictation eval — human WAVs or TTS(`say`) → live speechd ASR → bundled polishd through the production stop-commit path, scored against `EvalCorpus/agent-dictation/` (7 migrated required cases asserted; the rest XFAIL; WER informational; raw-model pre-safety diagnostic column) | nightly (skips green when the Mac is on battery — `ac-power-guard.sh`, owner rule 2026-07-24: scheduled lanes never run unplugged; manual dispatch always runs) + manual, NEVER per-PR (owner decision 2026-07-11); locally via `remote-build.sh eval-e2e [EvalRecordings/agent-dictation/<set>]` (run `package` first) | many minutes (live ASR/4B polish over ~160 cases; TTS WAVs cached on the host) |

Tier 1 details: the suite is env-gated (`VLLM_REALTIME_TEST_ENABLE=1`) and
expects an STT server at `ws://127.0.0.1:8000/v1/realtime` — on the build host it
runs as the launchd test service `com.localvoxtral.testspeechd` (the bundled
`localvoxtral-speechd`; logs: `/Users/Shared/localvoxtral/speechd.log`). Fork PRs
run on GitHub-hosted runners with no backend, where the suite self-skips. The
mic-capture tests (`LOCALVOXTRAL_MIC_CAPTURE_TEST_ENABLE`) stay off in CI until
tier 2.

On-demand test servers: the speechd (8000, STT) and polishd (8080,
chat/completions) launchd test services — the app's OWN bundled Swift helpers,
which replaced the retired Python voxmlx/mlx-lm services in 2026-07 — are
launch-on-demand (a trigger file + idle reaper — `scripts/mac/lv-test-servers.sh`,
owner runbook `scripts/mac/README.md`), so their weights are not resident 24/7.
This is hands-free: CI warms speechd in a step before the integration suite, and
`remote-build.sh integration|eval-llm|eval-e2e` warm the right server through the gate's
`ensure` verb first (names `speechd`/`polishd`, with `voxmlx`/`mlxlm` accepted as
deprecated aliases), blocking until the port is healthy. A burst of runs reuses
one warm process (each `ensure` resets a ~20 min idle window); the reaper frees
the RAM once the machine goes quiet.

LLM polish prompt eval: `LLMPolishPromptEvalTests` scores the bundled default
polishing prompt (punctuation-spacing cases, French vs English) against a live
chat/completions server through the production request path. Run it with
`./scripts/remote-build.sh eval-llm [endpoint]` — default endpoint is the
on-demand `com.localvoxtral.testpolishd` launchd service on port 8080 (the
bundled `localvoxtral-polishd`, running the production default model), which the
lane warms first via the gate's `ensure` verb (owner runbook: `scripts/mac/README.md`);
a custom endpoint is left untouched. Don't point it at the app-managed instance
on 8472, which dies whenever the app quits. Enablement is env
(`LLM_POLISH_EVAL_ENABLE=1`) or the marker file the script writes into the
synced tree (the SSH gate can't pass env vars). Prompt changes MUST re-run
this eval and paste the scoreboard in the PR's Proof section. The corpus +
scorer live in `LLMPolishEvalSupport`, shared with
`PolishHelperIntegrationTests` (`remote-build.sh integration-polishd`), which
holds the bundled MLX Swift polishing helper to the same baseline — engine or
model-pin changes MUST run that one too.

### When must the LLM lanes run?

CI does not run LLM inference on every push (owner decision, 2026-07-11):
the polishd live-model integration step in `ci.yml` runs only when the diff
touches LLM-relevant paths, or when the PR body / head commit message
contains the literal marker `[run-llm-eval]` (the explicit opt-in for
judgment calls). The marker must be present when the run is CREATED: editing
the PR body after a skipped run does not retrigger CI, and rerunning a run
reuses its original event payload — after adding the marker, push (an empty
commit works, or put the marker in the commit message). The exact path list
lives in
`scripts/ci/llm-lane-filter.sh` — PolishHelper/**, the bundled
`llm_*.toml` prompts, model catalog/pins, the polish client, token guard,
prompt warmup, clipboard context/macro, repo vocabulary, the polish-commit
path (`DictationViewModel+Session.swift`), and the eval support/corpus. The
decide step writes "LLM eval lane: RUNNING (…)" or "SKIPPED (…)" to the
run's step summary so a skipped run is self-explanatory. The PolishHelper
UNIT suite (Metal-free) and the tier-1 speechd realtime integration stay
per-push.

The rule behind the list — the LLM lanes are REQUIRED for changes to:
prompts, model pins/catalog, sampling/template kwargs, the polish request
shape or anything that alters what reaches the model (context attachment,
dictionary/vocabulary hints, macro placeholders, token guard repair
semantics), the helper engine, or the eval corpus/scorer. NOT required for
UI, insertion, audio, backend-supervision, or test-only changes elsewhere.
Either way, the PR's Proof section states one of the two: the lane's
scoreboard, or a one-line justification for skipping. If the path filter
misses a change that belongs above, add `[run-llm-eval]` AND extend the
filter list in the same PR. `./scripts/remote-build.sh integration-polishd`
remains the local equivalent. The nightly `eval-e2e.yml` lane is the only
scheduled eval; the per-PR polishd lane skipped by the filter runs again only
when a matching change (or the marker) triggers it.

The speechd live-model lane follows the same owner constraint: it runs only for
`scripts/ci/speechd-lane-filter.sh` matches or `[run-speechd-integration]`.
SpeechHelper engine/pin, packaging, or integration-contract changes must run it;
the Metal-free SpeechHelper unit suite remains per-push on self-hosted CI.

Agent-dictation E2E eval (`AgentDictationE2EEvalTests`, nightly `eval-e2e.yml`
+ `remote-build.sh eval-e2e`): model/prompt/feature-pipeline changes — anything
the rule above marks LLM-relevant, plus the TTS→ASR→polish harness itself —
MUST paste the eval-e2e scoreboard in the PR's Proof section, or explicitly
justify skipping it in one line. Only the 7 migrated punctuation cases are
`required` today; Phase 3 calibration will promote cases that prove stable
across server states (restarts / prompt-cache configurations) to `required` —
promotion PRs must carry that cross-state evidence.

### Human agent-eval recordings and ablations

On the Mac in a GUI terminal, `./scripts/record-agent-eval.sh --set owner`
starts or resumes the private, gitignored human set. Return starts recording,
Return stops, and Return accepts; playback is optional (`p`). `q` saves and
quits. Accepted WAVs are installed atomically and journaled first, so a crash or
interrupted Swift invocation does not lose prior takes. Do not use `--redo`
unless intentionally replacing accepted audio. The complete operator guide and
data-safety details live in `EvalCorpus/agent-dictation/README.md`.
For a focused retry, repeat `--case <id>` in one invocation; the recorder
replaces only those selected takes and preserves the rest of the manifest.

While the set is incomplete, run `scripts/run-agent-eval-local.sh --subset ...`;
this selects recorded speech rows but still runs every polish-only required
case. After it reaches 146/146, omit `--subset` for the strict baseline. The run writes
`.build/agent-eval-local.log` and opens the per-case HTML report beside the WAVs.
Repeat `--case <id>` on `run-agent-eval-local.sh` for an exact focused E2E slice;
unlike `--subset`, this does not add every polish-only case.
Use `scripts/ablate-agent-eval.py` on that log to compare stages/prompts/models
without transcribing again. Ablation responses append immediately to a resumable
JSONL file and its aggregate score is Markdown-neutral. Cache identity includes
the endpoint and complete request payload. For technical-term iteration, use
`--variants current-production,current-production-oracle --model qwen35-4b
--ceiling-model qwen36dense-27b`; the report attributes ASR preservation, 4B
recovery, exact-evidence recovery, 27B-only recovery, and misses by both. Model
arms are intentionally sequential to prevent a llama.cpp router from unloading
one beneath the other. Keep comparisons paired on the same case IDs and preserve
the explicit Qwen sampling parameters. Technique trials print paired term/case
gains AND losses plus large word-accuracy regressions; never promote a variant
from token recall alone, because exact-term recovery can still damage the user's
surrounding instruction. XCTest
can occasionally splice a status line into the sentinel-delimited JSONL report;
the offline tools recover known XCTest diagnostics and warn only if an unknown
corruption still forces a record to be skipped. Note any resulting denominator
rather than silently treating it as a model failure.

## CI / shipping

- `ci.yml` runs tiers 0–1 on every non-fast-path PR and push to main (the polishd
  live-model lane conditionally — see "When must the LLM lanes run?").
  Same-repo branches run on the self-hosted Mac runner (fast, warm cache);
  fork PRs run on GitHub-hosted macOS. Never move fork-PR jobs to the
  self-hosted runner — it is a personal machine.
- The `build-test` check stays present but skips every Swift, helper, package,
  artifact, smoke, warm, and integration lane when every changed path is a
  documentation, presentation, or operational-script path per the conservative
  allowlist in `scripts/ci/docs-only-filter.sh`. Unknown/ambiguous diffs,
  packaging inputs (`assets/icons/**`), lane-filter-relevant paths, the
  `[run-llm-eval]`/`[run-speechd-integration]` markers, and changes to the
  filter or other `scripts/ci/**` paths all fail open to the full run. Release
  and all other workflows remain fully gated.
- Watch a PR's checks with `./scripts/watch-checks.sh <n>` (or `--run
  <run-id>` for a push/rerun). It polls like `gh pr checks --watch` but also
  probes the build host over SSH and fail-fasts in ~30 s with a wake-the-Mac
  message when the host stops answering — bare `gh` watching silently eats
  GitHub's 10-minute "runner lost communication" window (and a queued job on
  a sleeping Mac just sits forever).
- Releases: `./scripts/release.sh [patch|minor|major|X.Y.Z]` from any machine
  with gh — dispatches `release.yml` on the self-hosted runner, which gates
  (build, unit, live integration, packaging, smoke) and only then tags and
  publishes the GitHub release (.zip + .dmg). Never push release tags by
  hand; the pipeline owns them.
- Packaged-app resource lookup: NEVER patch SwiftPM-generated DerivedSources
  (the toolchain regenerates them clean on every build, silently reverting the
  patch — shipped launch-broken artifacts, #87). App resources resolve at
  runtime via `Bundle.localvoxtralResources` (`AppResourceBundle.swift`);
  dependency checkouts (ShortcutRecorder) are still source-patched by
  `package_app.sh` because checkouts persist across builds. CI's launch smoke
  runs the packaged app COPIED outside the workspace with `.build` hidden —
  same-tree launches mask exactly this class of breakage.

## Architecture map

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
  before typing — see "Known tradeoffs" below for the latency it costs
- Overlay: `OverlayBufferSessionCoordinator` (session + hold-before-dismiss
  timing), `OverlayBufferStateMachine`, `DictationOverlayController` (NSPanel)
- Backends: `BackendManager` lazily prepares pinned Hugging Face snapshots and
  starts the bundled Swift helpers: `localvoxtral-speechd` for ASR on port
  8471 and `localvoxtral-polishd` for polishing on port 8472. Supervisors
  spawn, health-check, and stop both managed processes; launch cleanup removes
  retired app-managed backend artifacts from existing installs. User-facing
  backend copy (pinned models, fork
  optimizations, vLLM example) lives in the README "Under the hood" section
  (`/docs` is gitignored local notes — nothing user-facing goes there); keep
  it in sync when pins change.
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
    event JSON to `127.0.0.1:8473/v1/hook/<Event>` through an OpenSSH
    `RemoteForward` — no localvoxtral binary and no `jq`/`nc`/Node on that
    host, but it does need `sh` and `curl` (fail-open when absent). It was
    `type: "http"` hooks until 2026-07-27: Claude Code expands http-hook
    header `${VAR}`s from the process environment only and never injects
    plugin userConfig options there (verified on 2.1.220), so every hook
    authenticated as `Bearer ` and was 401'd — command hooks are the only
    surface that receives `CLAUDE_PLUGIN_OPTION_TOKEN`. The shim keeps the
    token out of every argv (`curl --header @tempfile`, 0600, heredoc-written)
    and prints the listener's 200 body untouched. `ClaudeRemoteContextListener`
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
    See "Known tradeoffs" for what is deliberately not wired up yet.
- LLM polish: `LLMPolishingService` (chat/completions client) → in managed
  mode, the bundled `localvoxtral-polishd` helper (`PolishHelper/` package:
  MLX Swift inference + a minimal loopback OpenAI server + parent-pid
  watchdog), supervised like any managed backend on port 8472. It replaced the
  former mlx-lm helper after upstream became unmaintained (2026-07).

## Known tradeoffs — deliberate, not bugs

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
    three terminals (`TerminalScreenAllowlist`, owner decision 2026-07-22):
    Ghostty, iTerm2, and Terminal.app. Resolution is
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
    `HerdrSocketClient` (hand-written, read-only — herdr is AGPL, never vendor
    its code) asks that one socket for the focused pane and the join is exact
    pane-id equality (`resolve(herdrPaneID:)`, local sessions only), guarded
    by two fail-closed cross-checks: herdr's own `agent_session` claim must
    not disagree, and the registered Claude pid must be in the pane's
    foreground process list (catches a suspended Claude with the user at the
    shell). Two live herdr sessions (distinct sockets) abstain — there is no
    way to tell which one the surface displays. A herdr join never authorizes
    raw screen attachment of the AX capture: that is the composite herdr TUI,
    and neighboring panes must not ride into this session's prompt. Instead,
    a herdr join's screen context is a clean `pane.read` excerpt of EXACTLY
    the joined pane (`HerdrPaneScreenContext`), fetched at start and stop
    behind the same consent gate and sanitize/cap pipeline as an AX read;
    `pane.read` fires only after the herdrPane join resolved and never for
    any other pane or mechanism. On any pane.read failure the session falls
    back to the pre-existing behavior — composite AX text, vocabulary-only,
    nothing attached.
  - Screen capture is split by ROUTE (`TerminalScreenAllowlist`): raw AX grid
    capture remains Ghostty-only (its single-`AXTextArea` grid is verified;
    iTerm2's AX tree is ambiguous across splits, Terminal.app's unverified).
    iTerm2/Terminal.app screen context comes ONLY from the AppleScript
    `contents` of the focused session/tab (`TerminalScreenAppleScriptReader`
    — visible screen, never `history`/scrollback; answered by the terminal
    process itself, same trust class as the TTY read, per-pane clean). Both
    routes share one downstream pipeline (sanitization, caps, start/stop
    reconcile, vocab-always / raw-excerpt-only-after-authorized-join). A TTY
    join in iTerm2/Terminal.app authorizes attaching that focused pane's
    contents; a herdr join still never attaches surface text on any terminal.
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
  but there is no remote repository collector.
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
  it, so the user must learn it is there. Note also what is NOT defensible: a
  malicious process running as the user on the REMOTE host can still read
  `~/.claude/` and therefore the plugin's token no matter what we do. Say so
  rather than implying the token bounds it.

## Conventions

- Concurrency: `@MainActor` for stateful UI/controller types; low-level types
  use `Mutex` + `@unchecked Sendable` (no custom actors). Keep new code
  warning-free under Swift 6.2 strict concurrency.
- Tests are XCTest. Prefer the existing DI seams (protocols + `#if DEBUG`
  hooks like `debugConfigureInsertionHooks`) over adding singletons.
- Settings panes (owner rule, 2026-07-04): the group structure of a pane is
  constant — a mode picker or toggle may switch a group's CONTENT (status row
  vs config fields), never the number or identity of the groups themselves.
- Menu bar popover (owner rule, 2026-07-04): NEVER render long text there —
  no raw errors, stderr, or URLs; it stretches the popover. Anything shown in
  the popover (`lastError`, status lines) is one short sentence, e.g.
  "mlx-lm failed to start." Full details belong in the alert popup and the
  log (and Settings shows the one-line failure summary only).
  `StatusPopoverView.statusDetailView` line-limits as a backstop — keep it.
- Hand-testing builds: see "Hand-testing & field debugging" above — use
  try-pr.sh and the stable signing identity, don't reinvent manual steps.
- Bundled config TOMLs (`Sources/localvoxtral/Resources/Config`): any content
  change must append the new file's SHA-256 to `BundledConfigDefaultHistory`
  (keep the old hashes — they let existing installs auto-adopt the new
  default). A tier-0 test fails with the exact hash to paste if you forget.
- Backend/lifecycle code paths log their requests, completions, and failures
  (`Log.backends`) — a silent failure path is how the ensureReady
  single-flight bug cost an hour of remote probing. Keep new paths loud.
