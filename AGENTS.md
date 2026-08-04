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
  `--dogfood` fetches the instrumented `localvoxtral-app-dogfood` artifact
  instead, verifies its `LVXDogfoodCapture` stamp, arms the runtime capture
  default, and launches — the one-command dogfood install. That artifact is
  opt-in in CI (`[dogfood-package]` in the PR body / head commit message, or
  a `workflow_dispatch` with `dogfood=true`); when the target run lacks it,
  the script offers to trigger a dispatch build and shows the latest run
  that has one.
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
  (retrieval / matcher / conflict / budget). Records also carry a content-free
  behavioral signal (`DogfoodEditSignalWatcher`): a bounded post-commit window
  — 2 s for 1–5 words up to 15 s for very long transcripts — watching for the
  user immediately erasing what was inserted (Backspace, forward delete, or ⌘A).
  Only the gesture, a bucketed delay, the word-count bucket, and the output mode are
  recorded; no key content and no other key at all. It is a GLOBAL `NSEvent`
  keyDown observer (no new permission — the same Accessibility trust insertion
  already needs), installed only while a window is open and torn down the
  instant it closes, and the record is patched in place afterwards rather than
  held back for the window (a held record is lost to any quit). The `clean` and
  `superseded` outcomes are recorded too: without the negative there is no
  denominator. It is behind a COMPILE flag
  (`LOCALVOXTRAL_DOGFOOD`, or the gitignored `.dogfood-capture-enable` marker
  that crosses the build gate) plus a runtime opt-in
  (`defaults write com.localvoxtral.app debug.dogfood_capture_enabled -bool true`).
  Shipped releases do not contain it, and there is deliberately no uploader —
  records are local files under Application Support. Fastest install:
  `./scripts/try-pr.sh main --dogfood` (CI-built opt-in artifact, stamp
  verified, capture default armed automatically). `dogfood-package` remains
  the local-build equivalent; both keep the bundle id so the TCC grant
  survives and stamp `LVXDogfoodCapture` into Info.plist so you can tell
  which binary you are running — as does Settings > About's constant "Build"
  row (`DogfoodBuildStatus`), which also shows whether capture is armed in
  this process.
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
  `[run-llm-eval]`/`[run-speechd-integration]`/`[dogfood-package]` markers,
  and changes to the
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
  optimizations, vLLM example) lives in the README "Under the hood" section;
  keep it in sync when pins change. Committed user-facing docs live in
  `docs/` (tracked normally); machine-local scratch notes go in the
  gitignored `local-notes/` instead.
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
    `ClaudeSessionSnapshot.process` — see the remote-opacity tradeoff below.
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
    See "Known tradeoffs" for what is deliberately not wired up yet.
- LLM polish: `LLMPolishingService` (chat/completions client) → in managed
  mode, the bundled `localvoxtral-polishd` helper (`PolishHelper/` package:
  MLX Swift inference + a minimal loopback OpenAI server + parent-pid
  watchdog), supervised like any managed backend on port 8472. It replaced the
  former mlx-lm helper after upstream became unmaintained (2026-07).

## Known tradeoffs — deliberate, not bugs

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
    (1) the focused surface's own TTY hosts a FOREGROUND `ssh` session whose
    destination is exactly one enrolled host's alias. `SSHDestinationTTYProbe`
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
    The accepted cost, stated rather than hidden: the manual flow — `ssh host`,
    then typing `herdr` — gets NO context at all, not even a marker fallback,
    because herdr intercepts OSC 2 so the marker never reaches the outer
    terminal. A wrong join is worse than no join. It also makes the arm free
    for everyone else: a plain ssh to an enrolled host no longer spawns a
    forward before falling through;
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
