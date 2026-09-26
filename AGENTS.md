# localvoxtral agent guide

Native macOS menu bar app for realtime dictation: Swift 6.2 strict
concurrency, SwiftPM, macOS 15+. It streams mic audio to an OpenAI
Realtime-compatible backend (the bundled `localvoxtral-speechd` helper, or any
compatible server in External URL mode) and inserts text into the focused app,
either live (Live Auto-Paste) or through an overlay committed on stop (Overlay
Buffer, with LLM polishing). Subsystem map: `docs/architecture.md`. It has
daily users, so nothing ships on "it compiles".

## Build and test

The app only compiles on macOS. From Linux, `./scripts/remote-build.sh` rsyncs
the working tree to the Mac build host and runs the toolchain there; no commit
needed. Set the host once per clone: `git config localvoxtral.buildhost
<ssh-destination>`. The script's header lists every verb.

The Mac is the owner's working machine and the only self-hosted runner. Spend
it only where nothing else can do the job:

- Linux first. `localvoxtralCore` (the Foundation-only pieces) builds and
  tests here: `./scripts/core-tests-linux.sh` (Swift 6.2; `SWIFT=` names the
  toolchain), and so do `scripts/ci/test-*.sh`. The app re-exports core, so a
  core declaration the app uses needs `package` access.
- On the Mac, run only the suites your change touches:
  `remote-build.sh test --filter <Suite>`, the flag repeated per suite (the
  host's SSH gate refuses `|`). Never run the full suite there: the PR's
  hosted `build-test` runs it on every push, drafts included. The script
  refuses a `test` with no `--filter` and the live verbs below unless
  `LV_ALLOW_HEAVY_MAC_RUN=1` is set; set it only when a rule here requires.
- Live lanes and evals (`integration*`, `eval-e2e`, `eval-term-recall`) run
  minutes to half an hour of inference. Run one only when a rule below
  requires it, once, on the final diff. When the PR's CI lane runs it, don't
  run it by hand too. Iterate on polish against a frozen eval log with
  `scripts/ablate-agent-eval.py`.
- Run `./scripts/mac-health.sh` before remote work. A sleeping Mac makes
  rsync hang instead of fail.
- Never pipe `remote-build.sh` through grep: a crash eats the failing test's
  name. The full output is in `.build/last-remote.log`, and the local Linux
  part's in `.build/last-linux.log`.
- An interrupted run can leave a stale SwiftPM lock. Switch to a fresh
  `LV_BUILD_DIR` instead of debugging it. Never hand-clean `~/work` on the
  Mac; abandoned build dirs are garbage-collected.
- Only `package_app.sh` produces working Metal kernels for the two MLX
  helpers. Read `PolishHelper/AGENTS.md` or `SpeechHelper/AGENTS.md` before
  touching either.

## Working an issue

1. **Claim it.** `gh pr list --state open --search <n>` before you start and
   again before you open the PR; parallel sessions have duplicated work. If
   another open PR carries the same area label and touches the same files,
   stop and report instead of racing it.
2. **Check the spec.** Work starts from an issue that states scope,
   constraints and the proof its PR must carry. If one is missing, write it
   into the issue and wait for the maintainer's OK.
3. **Iterate** on Linux and with filtered Mac suites (Build and test). Push
   the draft for the full suite on hosted `build-test`.
4. **Open the PR as a draft** (`gh pr create --draft`) with `Closes #<n>` in
   the body. The link moves the issue's card on the project board
   (github.com/users/T0mSIlver/projects/1) to In progress, and the merge moves
   it to Done.
5. **Mark it ready** (`gh pr ready <n>`) only once `build-test` is green and
   none of your other PRs is waiting on `mac-lanes`. Ready starts the Mac
   lanes; see CI below.
6. **After the merge**, move each issue your issue was blocking
   (`gh api repos/T0mSIlver/localvoxtral/issues/<n>/dependencies/blocking`)
   from Blocked to Todo once all its blockers are closed; GitHub does not.
   Stopping before the merge? Leave a handoff comment: state, what's left,
   decisions made.

The board's Needs human review status holds PRs, not issues, that wait on
the owner. The scheduler adds an open PR when it asks for the owner's OK to
merge; whoever merges a `needs-human-review` PR adds it right after the
merge. Add with `gh project item-add 1 --owner T0mSIlver --url <pr-url>`,
then `gh project item-edit --project-id PVT_kwHOAhDp9c4BkXCa --id <item>
--field-id PVTSSF_lAHOAhDp9c4BkXCazhjH4TM --single-select-option-id <id>`,
the option's id from `gh project field-list 1 --owner T0mSIlver --format
json`; `gh issue create --project` fails here. Only the owner moves a
PR's card to Done: on an open PR that is the OK to merge (#763), on a merged
one it means checked. A failed check becomes a `bug` issue that links the PR.

New issues get one area label (`asr`, `polish`, `ci`, `claude-join`,
`mistral`, `session`) plus `bug` or `enhancement`. Group work with sub-issues
and order it with blocked-by links, not prose.

Found work outside your issue's scope (a gap, a weakened check, a stale doc)?
Open the follow-up issue yourself, with scope, constraints and proof, link it
from your issue and say so in your report. Don't ask whether to file it.

## Proof

- Fill the PR template's Proof section with real command output, and name the
  test that demonstrates the change. "CI is green" is not proof of a behavior
  change.
- A bug fix adds a regression test, shown failing before the fix and passing
  after: two filtered runs, both in the PR body.
- Never weaken a test to get green: no moved thresholds, deleted assertions,
  new `XCTSkip` or wider timing tolerances. Investigate, or stop and report.
- No wall-clock in tests: no `Date()`, no real `Task.sleep` polling. Inject
  clocks; `OverlayBufferSessionCoordinator`'s `now:` / `sleepFor:` seams are
  the reference.
- Test classes run in several xctest processes at once (#442). A test that
  listens binds port 0 or takes `unusedLoopbackPort()`, never a fixed port
  or a counter from one. Files and sockets get unique names.
- The session's timers sleep on `Dependencies.clock`, the reconnect run on
  `Dependencies.reconnectSleep`. A test that starts or stops a session passes
  a `ManualSessionClock` (`Tests/localvoxtralTestSupport`) and advances it;
  on the wall clock the timers fire into the process-retained view model
  after the test ends. New timers go on the clock.
- Can't test something yourself (a UI change, behaviour only a person at
  the Mac sees)? Add the `needs-human-review` label and numbered steps for
  the owner under the template's Hand check item.
- Session-path change (start and stop, realtime clients, merging, insertion,
  overlay commit): prove it in process, in `DictationPipelineTests` or next
  to it. The e2e dictation check, the only one where the packaged app
  dictates into another app, gates releases (`release.sh` refuses without a
  pass on the release commit), not PRs. A PR may take one run for what only
  it reaches: insertion into another app's window, focus, TCC. Dispatch only
  with `scripts/ui-smoke-dispatch.sh`, after review fixes and a green
  `build-test`, and paste its lines; a NOT RUN or lost-focus red goes in
  Proof, not into a second dispatch (`docs/agent/test-tiers.md`).
- Live lanes run only on a lane-filter path match or a marker
  (`[run-stt-integration]`, `[run-llm-eval]`, `[run-speechd-integration]`,
  `[run-herdr-integration]`) in the PR body or head commit when the run is
  created; a rerun reuses the old payload. Changes to prompts, model pins or
  the catalog, sampling, the polish request shape, the helper engines, or the
  eval corpus, scorer or TTS→ASR→polish harness REQUIRE the matching lane
  plus one eval-e2e scoreboard on the final diff, or a one-line
  justification for skipping. When the LLM filter matches a change that
  touches none of those (a test file moved between targets, a rename with no
  content change), waive the lane with `[skip-llm-eval: <that justification>]`
  at run creation; without a reason it is ignored, and `[run-llm-eval]` wins.
  Changes to what the app sends herdr, what it believes herdr answered, or how
  its ssh forward opens REQUIRE `integration-herdr`. Details:
  `docs/agent/test-tiers.md`.

## CI

- Three required jobs: `build-test` (hosted macOS), `linux` (hosted Ubuntu:
  `scripts/ci/test-*.sh` and the core suites) and `mac-lanes` (the owner's
  MacBook). `mac-lanes` skips pushes to main and fork PRs, and runs a draft
  only when its body held `[mac-lanes]` at run creation. Never move fork-PR
  work onto that Mac. New lanes go in `build-test` unless they need something
  only that Mac has: signing identity, Metal, the STT service, the herdr
  fixture, a GUI session.
- One Mac runs every agent's `mac-lanes`, one job at a time, so the queue is
  what everyone waits for. A push to a ready PR cancels its running Mac job
  and queues another: `gh pr ready <n> --undo` before a series of pushes. Keep
  upper layers of a stack draft until the one below is about to merge. Never
  dispatch a ref that already has a run queued: the two land in different
  concurrency groups and both run. Queue rules: `docs/agent/test-tiers.md`,
  "Dispatching a run without deepening the queue".
- A PR body that quotes a lane marker runs it. Name markers without brackets
  unless you mean them.
- `gh pr edit` fails on this repo. Edit a body with
  `gh api -X PATCH repos/<owner>/<repo>/pulls/<n> -F body=@file`; editing
  starts no run, so paste Proof after the run finishes.
- Red run: read its log first. `gh run rerun <id> --failed` reruns only the
  failed job; a red Mac job gets one rerun, then goes to the owner. Watch
  checks with `./scripts/watch-checks.sh <n>`; unlike bare `gh`, it notices
  when the Mac stops answering.
- Releases go through `./scripts/release.sh`. Never push a release tag by hand.
- Never patch SwiftPM-generated DerivedSources; that shipped launch-broken
  builds (#87). App resources resolve through `Bundle.localvoxtralResources`.
- The launch smoke copies the packaged app outside the workspace with
  `.build` hidden, because same-tree launches mask the #87 class of breakage.
  Don't simplify it.

## Code

- Concurrency: `@MainActor` for stateful UI and controller types; low-level
  types use `Mutex` + `@unchecked Sendable`. No custom actors.
- Prefer the existing DI seams (protocols, `#if DEBUG` hooks such as
  `debugConfigureInsertionHooks`) over new singletons. Shared test doubles
  that need only the core live in `Tests/localvoxtralTestSupport`, which both
  test targets use and Linux builds; the rest live in
  `Tests/localvoxtralTests/TestSupport`. Extend them, never copy one into a
  test file as `private` (#402).
- Never read a child process pipe with `FileHandle.availableData`. It raises an
  uncatchable ObjC exception on a descriptor error and aborts the app (#60).
  Use `POSIXPipeRead.nextChunk(fromDescriptor:)`.
- Backend and lifecycle paths log requests, completions and failures to
  `Log.backends`. Keep new paths loud; silent failures have cost hours of
  remote probing.
- A content change to a bundled config TOML in
  `Sources/localvoxtral/Resources/Config` appends the new file's SHA-256 to
  `BundledConfigDefaultHistory`, keeping the old hashes. A tier-0 test fails
  with the exact hash if you forget.
- Settings panes: a mode picker or toggle may switch a group's content, never
  the number or identity of the groups. A row has no subtitle: its title says
  what it does, and anything more goes behind the group's Learn more link.
- Menu bar popover: one short sentence at most, never raw errors, stderr or
  URLs. Full details go to the alert and the log.
  `StatusPopoverView.statusDetailView`'s line limit is the backstop; keep it.

## Read first, when your work touches

- The Claude Code context path (`Sources/ClaudeContext*`,
  `Sources/localvoxtral*/ClaudeContext/`, `integrations/claude-code/`), text
  insertion, or polish-commit semantics: `docs/agent/invariants.md`. Its
  trust boundaries encode measured failures; don't infer intent from the code.
  Also `Sources/localvoxtral/ClaudeContext/AGENTS.md`.
- A field bug, a hand-test build, signing or TCC trouble:
  `docs/agent/field-debugging.md`. Dispatch `mac-crashlog.yml` before
  theorizing; install builds with `./scripts/try-pr.sh`.
- CI lanes and evals: `docs/agent/test-tiers.md`.
- Showing the owner what a view looks like: `docs/agent/view-snapshots.md`
  (hosted runner, no Mac).
- Either MLX helper: `PolishHelper/AGENTS.md`, `SpeechHelper/AGENTS.md`.
- The eval corpus: `EvalCorpus/agent-dictation/AGENTS.md`.
- Claude Code, opencode or Vibe integrations: `integrations/claude-code/AGENTS.md`
  and the READMEs under `integrations/`.
- Build host, launchd, runner: `scripts/mac/README.md`. Per-workflow notes:
  `.github/workflows/README.md`.

## Docs

- `README.md` is a landing page. User docs live in `docs/`, agent guides in
  `docs/agent/`, machine-local scratch in the gitignored `local-notes/`.
- Changed a model pin or backend copy? Update `docs/under-the-hood.md` in the
  same PR.
- Moved or renamed a section that a comment points at? Fix the pointer in the
  same PR; `ci.yml`, the lane filters and several scripts cite docs by
  section name.

## Rules for editing THIS file

Every agent loads this file, and Codex silently truncates it past 32 KiB
(`AgentsGuideSizeTests` enforces the budget). A line earns its place by what
the model could not have guessed: a trap, a rule that contradicts the obvious
choice, a command it would not find. Anything a model would do anyway goes.
Situational depth goes in `docs/agent/` or a colocated `AGENTS.md`, routed
from the list above. This file says how to work on the repo, not how one
maintainer likes to work.
