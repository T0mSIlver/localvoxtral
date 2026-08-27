# localvoxtral — agent guide

Native macOS menu bar app for realtime dictation (Swift 6.2 strict concurrency,
SwiftPM, macOS 15+). Streams mic audio to an OpenAI Realtime-compatible backend
(the bundled `localvoxtral-speechd` helper in managed mode; vLLM or any
compatible server in External URL mode), merges partial transcripts, and
inserts text into the focused app — either live ("Live Auto-Paste") or via an
overlay committed on stop ("Overlay Buffer", supports replacement dictionary +
LLM polishing). Subsystem map: `docs/architecture.md`.

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
./scripts/remote-build.sh integration-polishd [hf-repo]  # bundled polish helper vs real model + eval baseline (run package first)
./scripts/remote-build.sh integration-speechd [hf-repo]  # packaged speech helper vs real audio/model (run package first)
./scripts/remote-build.sh eval-e2e [EvalRecordings/agent-dictation/<set>]  # agent-dictation E2E eval (run package first)
./scripts/remote-build.sh dogfood          # build the instrumented tree + run the context-capture suite
./scripts/remote-build.sh dogfood-package  # package an instrumented .app for hand-dogfooding
./scripts/remote-build.sh build --package-path PolishHelper   # compile a helper package alone (no Metal kernels)
./scripts/remote-build.sh test  --package-path PolishHelper   # helper unit tests (Metal-free); same for SpeechHelper
```

On a Mac, just `swift build` / `swift test` (but only `package_app.sh` can
produce working Metal kernels for the helpers — see `PolishHelper/AGENTS.md`
/ `SpeechHelper/AGENTS.md` before touching either).

- Before starting long remote work, `./scripts/mac-health.sh` — it fails fast
  when the Mac is asleep/unreachable instead of letting rsync hang.
- Parallel agents are isolated automatically (per-worktree remote dir;
  `LV_BUILD_DIR` overrides). Abandoned dirs are garbage-collected — never
  hand-clean `~/work` on the Mac. `./scripts/remote-build.sh disk` shows
  sizes/ages.
- An interrupted remote run can leave a stale SwiftPM lock in its remote dir —
  don't debug it, switch to a fresh `LV_BUILD_DIR`.
- Every run's full remote output lands in `.build/last-remote.log`. Never pipe
  the script itself through grep (a crash eats the failing test's name) — let
  it print, then grep the log file.

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

## Test tiers — the short version

Tier 0 (unit suites + packaging + launch smoke) and the tier-1 speechd
realtime integration run on every non-fast-path PR/push. The live-model LLM
lanes are CONDITIONAL: they run only for lane-filter path matches
(`scripts/ci/llm-lane-filter.sh` / `speechd-lane-filter.sh`) or the literal
markers `[run-llm-eval]` / `[run-speechd-integration]` in the PR body or head
commit — and the marker must be present when the run is created (rerun reuses
the old payload; push after adding it). Tier 2 (UI smoke, nightly E2E eval)
is scheduled, never per-PR.

The binding rule: changes to prompts, model pins/catalog, sampling, the
polish request shape or anything that alters what reaches the model, the
helper engines, or the eval corpus/scorer REQUIRE the matching lane, and the
PR's Proof section carries either the scoreboard or a one-line justification
for skipping. Model/prompt changes — and changes to the TTS→ASR→polish
harness itself — additionally paste the eval-e2e scoreboard
(`remote-build.sh eval-e2e`) or justify skipping it; "tier 2 is scheduled"
does not waive that duty. Full tier table, lane details, eval-recording and
ablation workflows: `docs/agent/test-tiers.md`.

## CI / shipping

- Same-repo branches run on the self-hosted Mac runner; fork PRs run on
  GitHub-hosted macOS. Never move fork-PR jobs to the self-hosted runner —
  it is a personal machine.
- Docs-only diffs take a fast path (`scripts/ci/docs-only-filter.sh`,
  conservative allowlist; unknown paths fail open to the full run). Only
  `build-test` fast-paths; release and every other workflow stay fully gated.
- Watch a PR's checks with `./scripts/watch-checks.sh <n>` (or `--run
  <run-id>` for a push/rerun) — unlike bare `gh`, it probes the build host
  and fail-fasts when the Mac stops answering.
- Releases: `./scripts/release.sh [patch|minor|major|X.Y.Z]` — the pipeline
  gates and owns the tags. Never push release tags by hand.
- NEVER patch SwiftPM-generated DerivedSources (regenerated clean every
  build; shipped launch-broken artifacts, #87). App resources resolve via
  `Bundle.localvoxtralResources` (`AppResourceBundle.swift`); dependency
  checkouts are still source-patched by `package_app.sh` because checkouts
  persist.
- CI's launch smoke runs the packaged app COPIED outside the workspace with
  `.build` hidden — same-tree launches mask exactly the #87 class of
  breakage; don't "simplify" that step.

## Deep guides — read the one that matches your work, BEFORE the work

- **Any change to the Claude Code context path** (join arms, screen capture,
  remote listener/enrollment/forwards — `Sources/ClaudeContext*`,
  `Sources/localvoxtral/ClaudeContext/`, `integrations/claude-code/`), and
  any change to text insertion or polish-commit semantics:
  `docs/agent/invariants.md`. The trust boundaries there are load-bearing;
  several encode measured failures. Do not infer intent from the code alone.
- **A field bug on the owner's Mac; hand-testing a build; signing/TCC
  weirdness; dogfood capture**: `docs/agent/field-debugging.md` — dispatch
  `mac-crashlog.yml` FIRST, theorize second; install builds with
  `./scripts/try-pr.sh`, never manual steps.
- **Adding/gating CI lanes, running or judging evals**:
  `docs/agent/test-tiers.md`.
- **Touching either MLX helper**: `PolishHelper/AGENTS.md` /
  `SpeechHelper/AGENTS.md` (and `SpeechHelper/DEPENDENCY.md` for the pin).
- **Eval corpus edits**: `EvalCorpus/agent-dictation/AGENTS.md` + its README.
- **Claude Code / opencode plugin work**: `integrations/claude-code/AGENTS.md`,
  `integrations/claude-code/README.md`, `integrations/opencode/README.md`.
- **Build-host / launchd / runner operations**: owner runbook
  `scripts/mac/README.md`. Per-workflow notes: `.github/workflows/README.md`.

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
  no raw errors, stderr, or URLs. Anything shown in the popover is one short
  sentence; full details belong in the alert popup and the log, and Settings
  shows the one-line failure summary only.
  `StatusPopoverView.statusDetailView` line-limits as a backstop — keep it.
- Pipes from child processes: never read with `FileHandle.availableData` —
  it raises an uncatchable ObjC exception on descriptor errors and aborts the
  app (field crash, PR #60). Use `POSIXPipeRead.nextChunk(fromDescriptor:)`.
- Bundled config TOMLs (`Sources/localvoxtral/Resources/Config`): any content
  change must append the new file's SHA-256 to `BundledConfigDefaultHistory`
  (keep the old hashes). A tier-0 test fails with the exact hash if you forget.
- Backend/lifecycle code paths log their requests, completions, and failures
  (`Log.backends`). Keep new paths loud — silent failure paths have cost
  hours of remote probing.

## Docs — where things live, and sync duties

- `README.md` is a landing page; user documentation lives in `docs/`
  (committed, user + contributor facing), agent deep guides in `docs/agent/`.
  Machine-local scratch goes in the gitignored `local-notes/`, never `docs/`.
- Model pins or backend copy changed? Update `docs/under-the-hood.md` in the
  same PR (it is the human-facing statement of `BackendManager`'s pins).
- Moved or renamed a section a comment points at? Fix the pointer in the same
  PR — `ci.yml`, the lane filters, and several scripts reference these docs
  by name.

## Rules for editing THIS file

- This file is always-loaded context for every agent and silently truncated
  by some tools at 32 KiB — a tier-0 test (`AgentsGuideSizeTests`) enforces
  the byte budget. Deep or situational material goes in `docs/agent/` or a
  colocated `AGENTS.md`, reached through the router above.
- A new line must be (1) non-obvious, (2) repeatedly relevant, and
  (3) specific enough to act on. Traps to avoid, not maps to follow: no
  architecture prose here (that's `docs/architecture.md`), no restating what
  the code or a linked doc already says.
