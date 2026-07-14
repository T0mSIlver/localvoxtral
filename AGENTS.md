# localvoxtral — agent guide

Native macOS menu bar app for realtime dictation (Swift 6.2 strict concurrency,
SwiftPM, macOS 15+). Streams mic audio to an OpenAI Realtime-compatible backend
(voxmlx / vLLM), merges partial transcripts, and inserts text into the focused
app — either live ("Live Auto-Paste") or via an overlay committed on stop
("Overlay Buffer", supports replacement dictionary + LLM polishing).

## Build & test — read this first on a non-Mac dev box

This repo only compiles on macOS. From a Linux box, the inner loop is the Mac
build host over SSH (no commit needed — it rsyncs the working tree). The host
is machine-local config, set once per clone (never committed):
`git config localvoxtral.buildhost <ssh-destination>`.

```bash
./scripts/remote-build.sh                 # build + unit tests
./scripts/remote-build.sh test --filter TextMergingAlgorithmsTests
./scripts/remote-build.sh integration     # realtime pipeline vs live voxmlx
./scripts/remote-build.sh eval-llm        # default polish prompt eval vs a live chat/completions server
./scripts/remote-build.sh package         # build the .app bundle (also builds the polishing helper)
./scripts/remote-build.sh integration-polishd [hf-repo]  # bundled polish helper vs real model + eval baseline (run package first); optional repo = per-model gate for PolishModelCatalog additions (self-provisions weights)
./scripts/remote-build.sh eval-e2e [EvalRecordings/agent-dictation/<set>]  # agent-dictation E2E eval: human WAVs (optional) or TTS -> voxmlx -> polishd (run package first)
./scripts/run-agent-eval-local.sh [EvalRecordings/agent-dictation/<set>]   # same eval directly from a Mac checkout (run package_app.sh first)
./scripts/ablate-agent-eval.py .build/agent-eval-local.log                 # reuse one E2E log to compare pre/post-processing, prompts, and models without rerunning audio
./scripts/remote-build.sh build --package-path PolishHelper   # helper package alone
./scripts/remote-build.sh test  --package-path PolishHelper   # helper unit tests (Metal-free)
```

The polishing helper (`PolishHelper/`, product `localvoxtral-polishd`) is a
SEPARATE SwiftPM package so the root build never compiles the MLX C++ core.
Two hard rules learned setting it up: (1) `swift build` of the helper
compiles but CANNOT produce working Metal kernels — only the xcodebuild lane
in `package_app.sh` can (aggregate scheme `PolishHelper`); a swift-build
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
still overrides it when you need a specific dir.

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
  `./scripts/remote-build.sh diag|applog|voxlog|svc-status`.
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
| 0 | Unit suite (500+ tests) + PolishHelper unit suite + packaging + launch smoke | every PR/push, CI (helper unit suite: self-hosted lanes only) | ~1 min |
| 1 | `RealtimeAPIVLLMIntegrationTests` vs live local voxmlx: real inference through the production websocket client, word-accuracy asserted | every PR/push on the self-hosted runner; locally via `remote-build.sh integration` | ~20 s |
| 1 | `PolishHelperIntegrationTests`: the packaged polishing helper vs the real pinned model — production request path, shared eval baseline, parent-pid tether | conditional in CI (self-hosted, after packaging): only when the diff touches LLM-relevant paths or the PR opts in with `[run-llm-eval]` — see "When must the LLM lanes run?"; locally via `remote-build.sh integration-polishd` | minutes (4B weights + live inference) |
| 2 | `ui-smoke.yml` AX smoke drill (status item, settings tabs, lazy managed-backend launch invariant); dictation-with-audio remains future work | nightly + manual on the self-hosted GUI runner | — |
| 2 | `AgentDictationE2EEvalTests` (`eval-e2e.yml`): wide agent-dictation eval — human WAVs or TTS(`say`) → live voxmlx ASR → bundled polishd through the production stop-commit path, scored against `EvalCorpus/agent-dictation/` (7 migrated required cases asserted; the rest XFAIL; WER informational; raw-model pre-safety diagnostic column) | nightly + manual, NEVER per-PR (owner decision 2026-07-11); locally via `remote-build.sh eval-e2e [EvalRecordings/agent-dictation/<set>]` (run `package` first) | many minutes (live ASR/4B polish over ~160 cases; TTS WAVs cached on the host) |

Tier 1 details: the suite is env-gated (`VLLM_REALTIME_TEST_ENABLE=1`) and
expects voxmlx at `ws://127.0.0.1:8000/v1/realtime` — on the build host it runs
as the launchd service `com.localvoxtral.voxmlx` (logs:
`~/Library/Logs/voxmlx.log`). Fork PRs run on GitHub-hosted runners with no
backend, where the suite self-skips. The mic-capture tests
(`LOCALVOXTRAL_MIC_CAPTURE_TEST_ENABLE`) stay off in CI until tier 2.

On-demand test servers: the voxmlx (8000) and mlxlm (8080) launchd services are
launch-on-demand (a trigger file + idle reaper — `scripts/mac/lv-test-servers.sh`,
owner runbook `scripts/mac/README.md`), so their weights are not resident 24/7.
This is hands-free: CI warms voxmlx in a step before the integration suite, and
`remote-build.sh integration|eval-llm|eval-e2e` warm the right server through the gate's
`ensure` verb first, blocking until the port is healthy. A burst of runs reuses
one warm process (each `ensure` resets a ~20 min idle window); the reaper frees
the RAM once the machine goes quiet.

LLM polish prompt eval: `LLMPolishPromptEvalTests` scores the bundled default
polishing prompt (punctuation-spacing cases, French vs English) against a live
chat/completions server through the production request path. Run it with
`./scripts/remote-build.sh eval-llm [endpoint]` — default endpoint is the
on-demand `com.localvoxtral.mlxlm` launchd service on port 8080, which the lane
warms first via the gate's `ensure` verb (owner runbook: `scripts/mac/README.md`);
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
UNIT suite (Metal-free) and the tier-1 voxmlx realtime integration stay
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

While the set is incomplete, run `scripts/run-agent-eval-local.sh --subset ...`;
this selects recorded speech rows but still runs every polish-only required
case. After it reaches 146/146, omit `--subset` for the strict baseline. The run writes
`.build/agent-eval-local.log` and opens the per-case HTML report beside the WAVs.
Use `scripts/ablate-agent-eval.py` on that log to compare stages/prompts/models
without transcribing again. Ablation responses append immediately to a resumable
JSONL file and its aggregate score is Markdown-neutral. Cache identity includes
the endpoint and complete request payload. For technical-term iteration, use
`--variants current-production,current-production-oracle --model qwen35-4b
--ceiling-model qwen36dense-27b`; the report attributes ASR preservation, 4B
recovery, exact-evidence recovery, 27B-only recovery, and misses by both. Model
arms are intentionally sequential to prevent a llama.cpp router from unloading
one beneath the other. Keep comparisons paired on the same case IDs and preserve
the explicit Qwen sampling parameters. XCTest
can occasionally splice a status line into the sentinel-delimited JSONL report;
the offline tools recover known XCTest diagnostics and warn only if an unknown
corruption still forces a record to be skipped. Note any resulting denominator
rather than silently treating it as a model failure.

## CI / shipping

- `ci.yml` runs tiers 0–1 on every PR and push to main (the polishd
  live-model lane conditionally — see "When must the LLM lanes run?").
  Same-repo branches run on the self-hosted Mac runner (fast, warm cache);
  fork PRs run on GitHub-hosted macOS. Never move fork-PR jobs to the
  self-hosted runner — it is a personal machine.
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
- Backends: `BackendManager` lazily bootstraps app-managed local serving on
  first dictation start; catalog pinned to fork wheel releases; installer
  downloads a pinned `uv` on first use, then shells out to it; supervisors
  spawn/health-check/stop the managed processes; install root lives under
  Application Support. User-facing backend copy (pinned models, fork
  optimizations, vLLM example) lives in the README "Under the hood" section
  (`/docs` is gitignored local notes — nothing user-facing goes there); keep
  it in sync when pins change.
- Settings/config: `SettingsStore` (UserDefaults), `AppConfigStore` (TOML at
  `~/Library/Application Support/localvoxtral/config`)
- Hotkey: `HotKeyManager` (Carbon, single global hotkey)
- LLM polish: `LLMPolishingService` (chat/completions client) → in managed
  mode, the bundled `localvoxtral-polishd` helper (`PolishHelper/` package:
  MLX Swift inference + a minimal loopback OpenAI server + parent-pid
  watchdog), supervised like any managed backend on port 8472. Replaced the
  uv-installed mlx-lm fork wheel (upstream mlx-lm unmaintained, 2026-07).

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
  path. Clipboard context is only a prompt/vocabulary hint; no content-based
  leak detector scans or rejects the model output. Only explicit clipboard-paste
  payload-placeholder count integrity remains active for both profiles. The
  token guard type remains as a recognizer used by clipboard vocabulary and by
  focused unit coverage; do not infer that it runs at commit.

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
