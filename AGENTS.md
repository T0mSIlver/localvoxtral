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
./scripts/remote-build.sh package         # build the .app bundle
```

On a Mac, just `swift build` / `swift test`.

When several agents work in parallel, each must set its own remote dir:
`LV_BUILD_DIR=work/localvoxtral-<task> ./scripts/remote-build.sh ...`

- An interrupted remote run can leave a stale SwiftPM lock in its remote dir —
  don't debug it, switch to a fresh `LV_BUILD_DIR`.
- Never pipe a full test run only through grep: `tee` the raw output to a file
  first, or a crash eats the failing test's name and you pay for reruns.

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
  and (once the v2 gate is installed)
  `./scripts/remote-build.sh diag|applog|voxlog|svc-status`.
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
| 0 | Unit suite (200+ tests) + packaging + launch smoke | every PR/push, CI | ~1 min |
| 1 | `RealtimeAPIVLLMIntegrationTests` vs live local voxmlx: real inference through the production websocket client, word-accuracy asserted | every PR/push on the self-hosted runner; locally via `remote-build.sh integration` | ~20 s |
| 2 | `ui-smoke.yml` AX smoke drill (status item, settings tabs, lazy managed-backend launch invariant); dictation-with-audio remains future work | nightly + manual on the self-hosted GUI runner | — |

Tier 1 details: the suite is env-gated (`VLLM_REALTIME_TEST_ENABLE=1`) and
expects voxmlx at `ws://127.0.0.1:8000/v1/realtime` — on the build host it runs
as the launchd service `com.localvoxtral.voxmlx` (logs:
`~/Library/Logs/voxmlx.log`). Fork PRs run on GitHub-hosted runners with no
backend, where the suite self-skips. The mic-capture tests
(`LOCALVOXTRAL_MIC_CAPTURE_TEST_ENABLE`) stay off in CI until tier 2.

## CI / shipping

- `ci.yml` runs tiers 0–1 on every PR and push to main. Same-repo branches run
  on the self-hosted Mac runner (fast, warm cache); fork PRs run on
  GitHub-hosted macOS. Never move fork-PR jobs to the self-hosted runner — it
  is a personal machine.
- Watch a PR's checks with `gh pr checks <n> --watch`.
- Releases: `./scripts/release.sh [patch|minor|major|X.Y.Z]` from any machine
  with gh — dispatches `release.yml` on the self-hosted runner, which gates
  (build, unit, live integration, packaging, smoke) and only then tags and
  publishes the GitHub release (.zip + .dmg). Never push release tags by
  hand; the pipeline owns them.
- `scripts/package_app.sh` intentionally patches SwiftPM-generated sources in
  `.build/` (resource-bundle lookup for packaged .apps); the patches are
  idempotent.

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
- Insertion: `TextInsertionService` (AX replace → Unicode CGEvents → Cmd+V)
- Overlay: `OverlayBufferSessionCoordinator` (session + hold-before-dismiss
  timing), `OverlayBufferStateMachine`, `DictationOverlayController` (NSPanel)
- Backends: `BackendManager` lazily bootstraps app-managed local serving on
  first dictation start; catalog pinned to fork wheel releases; installer
  downloads a pinned `uv` on first use, then shells out to it; supervisors
  spawn/health-check/stop the managed processes; install root lives under
  Application Support.
- Settings/config: `SettingsStore` (UserDefaults), `AppConfigStore` (TOML at
  `~/Library/Application Support/localvoxtral/config`)
- Hotkey: `HotKeyManager` (Carbon, single global hotkey)
- LLM polish: `LLMPolishingService` (chat/completions)

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
- Backend/lifecycle code paths log their requests, completions, and failures
  (`Log.backends`) — a silent failure path is how the ensureReady
  single-flight bug cost an hour of remote probing. Keep new paths loud.
