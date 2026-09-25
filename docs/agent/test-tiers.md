# Test tiers & eval lanes

| Tier | What | When | Cost |
|---|---|---|---|
| 0 | Unit suite (3,900+ tests, one xctest process per core, each running whole test classes: `scripts/lib/unit-test-shards.sh`, the same shape `remote-build.sh test` drives over ssh) + shell gate suites (run in parallel by `scripts/ci/run-shell-suites.sh`; a new suite is one more argument there, and `test-ui-gate.sh` runs on a PR only when `scripts/ci/ui-gate-suite-filter.sh` says the diff touches a file it reads) + format lint + coverage (the unit suite skips `PolishContextPreparationTests`, the row below) | every non-fast-path PR/push, in CI's `build-test` job on **GitHub-hosted macOS** (owner decision 2026-09-05 — same-repo PRs too, not just forks; the Mac is the queue bottleneck and hosted runners are free for public repos) | ~4 min hosted, ~0 s queue |
| 0 | `PolishContextPreparationTests`: the cost budgets of clipboard-context preparation — how much work grounding, excerpt selection and the containment sweep do on a realistic code-heavy buffer | every non-fast-path PR/push, in its own required step of `build-test` right after the unit suite (same `--enable-code-coverage`, so it reuses that binary). It is out of the unit suite because its assertions ARE about cost, so it cannot be made fast without deleting them (#430). Locally: `remote-build.sh test-cost-budgets` | ~6 s |
| 0 | Packaging + launch smoke of the **signed** bundle, and the installable artifact | every non-fast-path dispatch and same-repo PR that is NOT a draft (pushes to main skip `mac-lanes`; a draft builds no bundle unless its body carries `[mac-lanes]`), in CI's `mac-lanes` job on the self-hosted Mac — the `localvoxtral-dev` identity is what keeps the owner's TCC grant valid across `try-pr.sh` installs. Fork PRs get an ad-hoc-signed equivalent inside `build-test` instead, since `mac-lanes` never runs for them | ~1 min |
| 0 | PolishHelper / SpeechHelper unit suites (Metal-free: router, cache locator, watchdog; codec/delta contract) | self-hosted lanes only, and path-gated per helper — a PR runs a helper's suite only when the diff touches that helper's directory or the shared CI plumbing; `workflow_dispatch` runs both (`scripts/ci/helper-lane-filter.sh`, no marker; pushes to main skip `mac-lanes`). Locally: `remote-build.sh test --package-path PolishHelper` / `SpeechHelper` | 11 s + 20 s |
| 1 | `RealtimeAPIVLLMIntegrationTests` vs the live local speechd STT test service: real inference through the production websocket client, word-accuracy asserted | conditional in CI (self-hosted): a PR runs it when the diff touches what the lane can see (the realtime client family, its scorer and fixture, the package pins, the CI plumbing: `scripts/ci/stt-lane-filter.sh`) or opts in with `[run-stt-integration]`; every dispatch and the nightly release run it. The service it talks to is the helper installed on the build host, not the PR's build, so a SpeechHelper diff is the next row's business; locally via `remote-build.sh integration` | ~50 s |
| 1 | `PolishHelperIntegrationTests`: the packaged polishing helper vs the real pinned model — production request path, shared eval baseline, parent-pid tether | conditional in CI (self-hosted, after packaging): only when the diff touches LLM-relevant paths or the PR opts in with `[run-llm-eval]` — see "When must the LLM lanes run?"; locally via `remote-build.sh integration-polishd` | minutes (4B weights + live inference) |
| 1 | `SpeechHelperIntegrationTests`: packaged speechd vs real spoken audio/model through the production realtime client — word accuracy, append-only delta/done parity, parent-pid tether | conditional in CI (self-hosted, after packaging): only when the diff touches speechd-relevant paths or the PR opts in with `[run-speechd-integration]`; locally via `remote-build.sh integration-speechd` | minutes (4B weights + live inference) |
| 1 | `HerdrIntegrationTests`: the remote-herdr join machinery vs a LIVE `herdr` server over a REAL `ssh -L` forward — real socket client, real forward coordinator, real `ssh -G` canonicalization, real herdr `config.toml` patch (the fixture server's own, beside any herdr the account runs); the only fixture is the focused surface (a real herdr client on a pty) | conditional in CI (self-hosted): only when the diff touches herdr-relevant paths or the PR opts in with `[run-herdr-integration]`; locally via `remote-build.sh integration-herdr [ssh-destination]` | ~1 min (no model weights) |
| 1 | `MistralRealtimeIntegrationTests`: the realtime client vs the LIVE hosted Mistral transcription API — handshake, synthetic spoken audio through the production frames, word accuracy, delta/done parity, and the 401 rejection path | NEVER in CI (the runner holds no Mistral key and the lane bills per minute of audio); by hand from the dev box via `MISTRAL_API_KEY=... ./scripts/remote-build.sh integration-mistral` | ~1 min + a few cents |
| 2 | `ui-smoke.yml`, two jobs. The AX smoke drill (`scripts/ui-smoke.sh`: status item, settings tabs, no managed backend spawned at launch in External URL mode, clean quit) runs on a GitHub-hosted `macos-latest` runner on an ad-hoc-signed bundle without the MLX helpers, launched from a copy outside the workspace with `.build` hidden (#87); it reaches no backend and needs no microphone. Then `scripts/e2e-dictation.sh` on the owner's Mac: the packaged dogfood app dictates from a WAV in place of the microphone into a throwaway target window, once per scenario file in `scripts/e2e/scenarios/` (Live Auto-Paste, Overlay Buffer), and the inserted text is scored against the spoken phrase. The only check that launches the packaged app AND dictates; polishing is off and `MicrophoneCaptureService` is bypassed. Exit 3 = the Mac could not run it (locked, no STT server, no Accessibility grant, a speech service lagging past what the app waits for): green with a warning on a schedule, red on a dispatch or label | drill: the 18:00 UTC slot, dispatch and the `needs-ui-smoke` label, hosted. Dictation: evening lock-aware slots on the self-hosted GUI runner (18:00/19:30/21:00 UTC; `ui-smoke-guard.sh` skips green when the Mac is on battery, the screen is locked, or a slot's dictation was already scored that day), dispatch and the label | drill: ~5.5 min hosted (4.5 min cold packaging, 1 min drill); dictation: a few minutes of the Mac |
| 2 | `AgentDictationE2EEvalTests` (`eval-e2e.yml`): wide agent-dictation eval — human WAVs or TTS(`say`) → live speechd ASR → bundled polishd through the production stop-commit path, scored against `EvalCorpus/agent-dictation/` (7 migrated required cases asserted; the rest XFAIL; WER informational; raw-model pre-safety diagnostic column) | weekly, Sundays 04:45 UTC (skips green when the Mac is on battery — `ac-power-guard.sh`, owner rule 2026-07-24: scheduled lanes never run unplugged; manual dispatch always runs) + manual, NEVER per-PR (owner decision 2026-07-11); locally via `remote-build.sh eval-e2e [EvalRecordings/agent-dictation/<set>]` (run `package` first) | many minutes (live ASR/4B polish over ~160 cases; TTS WAVs cached on the host) |
| 2 | `TermRecallEvalTests`: the speech engine alone on the owner's technical terms — `say` or human WAVs → one live speech test service, scored by `TermRecallScorer` for term recall, false insertions of listed terms and non-term WER, English and French apart; also scores a file of hypotheses and pairs two runs. PRIVATE cases (`EvalCorpus/term-recall/README.md`) | by hand only, never in CI (the cases never leave the owner's machines): `remote-build.sh eval-term-recall [--asr <name>]`. Required proof for engine term biasing (#316, #521) and a second pass on stop (#524) | 260 cases: ~10 min on Nemotron, ~35 min on Voxtral (measured 2026-09-25; TTS WAVs cached on the host) |
| 2 | `release.yml` NIGHTLY channel: the whole release pipeline (unit suite, live STT integration, packaging, launch smoke) against `main`, published as a `vX.Y.Z-nightly.YYYYMMDD` prerelease that never touches `/releases/latest`; nightlies beyond the newest 7 are pruned | cron 03:15 UTC + `./scripts/release.sh nightly`; a scheduled run skips green on battery (`ac-power-guard.sh`) and when `main` is already the newest nightly or stable tag. To exercise the pipeline without releasing anything: `./scripts/release.sh rehearse [target] [ref]` (every gate, artifacts on the run, no tag, any ref). That rehearsal is the proof a change to release.yml carries | ~10-20 min |

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
on 8472, which dies whenever the app quits. The optional second argument is the
model alias, and its prefix selects the request shape: `llamacpp/<model>` sends
the llama.cpp-via-Bifrost extras, `mistral/<model>` sends Mistral's closed
request schema (prefix stripped from the model name, `reasoning_effort: none`,
none of the `top_k`/`min_p`/`chat_template_kwargs`/`thinking_budget_tokens`
extras) and copies this box's `MISTRAL_API_KEY` into the marker — e.g.
`MISTRAL_API_KEY=… ./scripts/remote-build.sh eval-llm https://api.mistral.ai mistral/mistral-medium-3-5`.
Enablement is env (`LLM_POLISH_EVAL_ENABLE=1`, with
`LLM_POLISH_EVAL_REQUEST_SHAPE=mistral` for the shape) or the marker file the
script writes into the synced tree (the SSH gate can't pass env vars). A change
to the request shape MUST re-run this lane against the provider it changes.
Prompt changes MUST re-run
this eval and paste the scoreboard in the PR's Proof section. The corpus +
scorer live in `LLMPolishEvalSupport`, shared with
`PolishHelperIntegrationTests` (`remote-build.sh integration-polishd`), which
holds the bundled MLX Swift polishing helper to the same baseline — engine or
model-pin changes MUST run that one too.

Mistral lane: `MistralRealtimeIntegrationTests` is the only lane that leaves the
owner's machines — it talks to `wss://api.mistral.ai/v1/audio/transcriptions/realtime`
with a real key and is billed per minute of audio, so it is deliberately absent
from every workflow. Enablement is `MISTRAL_API_KEY` in the environment (a direct
run on a Mac) or the gitignored `.mistral-integration-enable.json` marker that
`remote-build.sh integration-mistral` writes 0600 into the synced tree and removes
on exit; without either, the suite self-skips and the unit lane stays clean. Run it
for any change to the Mistral wire path — frame shapes, the `model` query item, the
`Authorization` header, the finalization gate, or the HTTP-status enrichment the
`.unauthorized`/`.rateLimited` classifier kinds depend on — and paste the accuracy
line in the PR's Proof section.

## When must the LLM lanes run?

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
`llm_*.toml` prompts and `AppConfigStore.swift`, which loads and renders
them, model catalog/pins, the polish client, token guard,
prompt warmup, clipboard context/macro, repo vocabulary, the polish-commit
path (`StopCommitCoordinator.swift`, the steps it calls, and
`DictationSessionController+StopCommit.swift`, which hands it the
transcript, the latched dictionary and the commit target), and the eval
support/corpus. The
decide step writes "LLM eval lane: RUNNING (…)" or "SKIPPED (…)" to the
run's step summary so a skipped run is self-explanatory. The PolishHelper
UNIT suite (Metal-free) is path-gated per helper, and the tier-1 speechd
realtime integration is path-gated on PRs (`scripts/ci/stt-lane-filter.sh`)
and unconditional on dispatches and in the nightly release.

The rule behind the list — the LLM lanes are REQUIRED for changes to:
prompts, model pins/catalog, sampling/template kwargs, the polish request
shape or anything that alters what reaches the model (context attachment,
dictionary/vocabulary hints, macro placeholders, token guard repair
semantics), the helper engine, or the eval corpus/scorer. NOT required for
UI, insertion, audio, backend-supervision, or test-only changes elsewhere.
Either way, the PR's Proof section states one of the two: the lane's
scoreboard, or a one-line justification for skipping. If the path filter
misses a change that belongs above, add `[run-llm-eval]` AND extend the
filter list in the same PR.

The filter matches by name, so it also catches changes that cannot alter what
reaches the model: a test file or a Foundation-only type moved between targets
(the #545 series), a rename with no content change. For those, put
`[skip-llm-eval: <reason>]` in the PR body or head commit message, under the
same run-creation rule as the opt-in marker, and the lane skips even though the
path matched. Use it only when the change cannot affect the prompt, model pins
or catalog, sampling, the polish request shape, the helper engines, or the eval
corpus, scorer or harness; when in doubt, let the lane run. The reason is the
Proof section's one-line justification, and the decide step echoes it as a
"LLM eval lane WAIVED" warning on the run page. A bare `[skip-llm-eval]` or an
empty reason waives nothing (the run page says why), and `[run-llm-eval]`
beside it wins. The filter stays the default rather than an opt-in because it
has caught files whose role in the prompt was not obvious from their names:
`AppConfigStore` renders the polish prompt and joined the list late (#564). The other direction has a list too: `EXEMPT` in
the same script names the `ClaudeContext/` files that install, configure or
keep a tunnel open, so an enrollment or settings diff does not buy live 4B
inference on the owner's Mac. A new file in that directory runs the lane until
it is added there, and only a file that cannot change what reaches the model,
or which session's context does, belongs. `./scripts/remote-build.sh integration-polishd`
remains the local equivalent. The weekly `eval-e2e.yml` lane is the only
scheduled eval; the per-PR polishd lane skipped by the filter runs again only
when a matching change (or the marker) triggers it.

## Which runner a lane lands on

`ci.yml` is four parallel jobs, and which one a lane is in is a statement about
what it needs, not about cost:

- **`build-test`, GitHub-hosted `macos-latest`, every event and every
  contributor** — a required status check on main, like `mac-lanes`.
  Anything that needs only a macOS toolchain: the pure-shell gate suites, the installer test, format
  lint, the unit suite, coverage. A fork PR gets ONLY this job, so it also
  packages/uploads/smokes an ad-hoc-signed bundle there.
- **`linux`, GitHub-hosted Ubuntu, every event and every contributor** —
  a required check. Every `scripts/ci/test-*.sh` suite, by glob, and
  the Linux-buildable Swift targets through `scripts/core-tests-linux.sh`.
  `build-test` runs the shell suites too, for the Mac's bash 3.2.
- **`dogfood`, GitHub-hosted `macos-latest`, every event** — not required.
  The dogfood capture suite, built with `LOCALVOXTRAL_DOGFOOD=1`.
- **`mac-lanes`, the self-hosted Mac, same-repo PRs that are NOT drafts +
  pushes + dispatches** — a draft gets `build-test` only, and marking it ready
  (`gh pr ready <n>`) starts the run. The literal `[mac-lanes]` in a draft's PR
  body opts it back in, for a draft that needs the signed `try-pr.sh` artifact
  or a live lane. What the job holds is
  anything that needs THAT machine: the `localvoxtral-dev` signing identity
  (an ad-hoc signature invalidates the owner's Accessibility grant on every
  `try-pr.sh` install), the launch-on-demand speechd STT service and the
  multi-GB weights, a real Metal toolchain for the two MLX helpers, the
  herdr/sshd fixture, the GUI session the UI-gate artifact root lives in, and
  the warm `clean: false` `.build` the helper suites depend on.

**Adding a lane: put it in `build-test` unless you can name the thing on the
owner's Mac that it needs.** The Mac is a single runner and a personal machine;
`build-test` is free and starts in seconds.

## Why the helper unit suites are path-gated

Owner decision 2026-09-05. The two helper UNIT suites ran on every self-hosted
run — 11 s + 20 s — including on diffs that could not possibly change what they
test. They are gated per helper by `scripts/ci/helper-lane-filter.sh`, which is
sound because **both helpers are hermetic SwiftPM packages**:
`PolishHelper/Package.swift` and `SpeechHelper/Package.swift` declare only
REMOTE dependencies — no `path:` dependency, no `..` reference, no symlink out
of the directory, no source shared with the root package. A helper suite's only
inputs are therefore its own directory (`Package.swift` and `Package.resolved`
included — that is the dependency-pin surface), the Xcode toolchain (not a
diff), and the CI plumbing that invokes it.

So: `PolishHelper/**` → the polish suite; `SpeechHelper/**` → the speech suite;
`.github/workflows/ci.yml`, `scripts/ci/**` or `scripts/package_app.sh` → BOTH;
`workflow_dispatch` → BOTH; a push to main → BOTH (main is the parity
reference and is never gated; `mac-lanes` itself skips main pushes, so this
rule applies only if that changes); an uncomputable diff or an unrecognized event →
BOTH, failing open exactly like `docs-only-filter.sh`.

**This is not the live-model lanes' "expensive, so opt in" pattern and there is
no marker.** Nothing here is a judgment call: a diff that can affect a suite
runs it, and a dispatch is the escape hatch if you ever want both anyway. If
you make a helper depend on something outside its directory — a local `path:`
dependency, a shared source directory — the premise breaks and the shared list
in the filter has to grow in the same PR.

## Dispatching a run without deepening the queue

There is ONE self-hosted runner (the owner's MacBook), so CI concurrency is 1
and every extra run is paid by everything behind it. Measured 2026-09-05: in a
3.6 h burst with four agents pushing, the runner was **89 % busy** — 26 jobs,
19 minutes of total idle — and 3.4 h of work produced **8.95 h of accumulated
queue**. At that utilization a queue is quadratically sensitive to load, so one
avoidable run costs far more than its own duration.

- **Never dispatch a build for a ref whose push/PR run is still queued.** The
  dispatch lands in a DIFFERENT concurrency group — `ci-refs/heads/<branch>`
  vs `ci-refs/pull/<n>/merge` — so `cancel-in-progress` does not deduplicate
  them and both run to completion. Check first:
  `gh run list --branch <ref>` (or `--workflow ci.yml`), and wait for the
  existing run instead. Observed the same day: runs `33973422149` (dispatch)
  and `33973420824` (PR) on one branch 20 s apart, and `33974946864`
  (dispatch on main) alongside `33974943655` (that push's own run).
- **The one exception** is a dispatch that produces something the queued run
  cannot: `dogfood=true` for an instrumented artifact when the queued run
  carries no `[dogfood-package]` marker, or any other artifact-only input. A
  dispatch that would merely re-run the same lanes is never worth its slot.
- **Drafts, and how a push is priced.** `mac-lanes` skips a draft, so the
  cheap loop is: open as a draft, push as often as the hosted `build-test`
  needs, `gh pr ready <n>` once. After that every push costs a Mac slot and
  cancels the run in progress (11 % of the Mac's busy time went to runs that
  were later cancelled, #418), so pull a PR back with `gh pr ready <n> --undo`
  before a series of pushes; that also replaces its queued Mac job with a
  skipped one. A draft and its ready run share one head SHA, which is why
  `watch-checks.sh` reads the newest check run of each name.
- Do not "just rerun" a red run to see if it is flaky before reading its log
  either — the flake signatures are enumerated in
  `docs/agent/field-debugging.md`, and a rerun is a full second run.

## Proving a change with the e2e dictation check

`scripts/e2e-dictation.sh` is the one check where the packaged app hears audio
and puts text into another app's window. Each run holds the owner's Mac for
several minutes, takes the keyboard and queues every other agent's
`mac-lanes` behind it, so it runs at release time, when the owner is at the
Mac, and a PR proves the session path in process (#574).

`DictationPipelineTests` runs one dictation per e2e scenario, from
`startDictation` to the stop's commit, through the real session code and the
real `RealtimeAPIWebSocketClient` over a loopback socket
(`TestSupport/FakeRealtimeServer`). Only the microphone, the speech model and
the target app are fakes. A session-path change extends it or the suites
beside it. The link-by-link map, and the broken link each test catches, are
in #583.

At release, `scripts/release.sh` refuses a stable release (not a nightly or a
rehearsal) unless a UI Smoke run on the release commit has its
`E2E dictation scored` step green. That step runs only when every scenario
was scored and passed; the dictation step itself also goes green on a locked
Mac. An evening run on main counts while main has not moved. Otherwise:

```bash
gh workflow run ui-smoke.yml --ref main   # the Mac unlocked, the owner at it
./scripts/release.sh --dry-run patch      # the gate's answer, no dispatch
```

On a PR the run is optional, for what only it reaches: text insertion into
another app's window, focus handling and TCC. No agent account can run it
directly, since the build gate has no GUI session and the UI gate reaches
only the app under test. It goes through the wrapper, which refuses when the
run is not justified. A dispatch also runs the AX drill on a GitHub-hosted
runner, which costs the Mac nothing:

```bash
./scripts/ui-smoke-dispatch.sh --dry-run <branch>   # does this diff need it?
./scripts/ui-smoke-dispatch.sh <branch>
gh run list --workflow ui-smoke.yml --branch <branch> -L 1
./scripts/watch-checks.sh --run <run-id>
gh run view <run-id> --log | grep -E "spoken:|inserted:|PASS:|FAIL:|NOT RUN:"
```

It refuses when:

- the diff against main touches no insertion, focus or commit file. The list is
  `scripts/ci/e2e-dictation-filter.sh`; the polish path, the overlay's look,
  settings and docs are off it. The PR body quotes the `path:` line either
  way, as it does for the live lanes.
- `build-test` is not green on the pushed head. Dispatch after the review
  fixes, on the final diff, never per commit.
- a UI Smoke run on the branch is queued or running, or started less than an
  hour ago.
- a run already ran on this head commit, whatever it concluded. `NOT RUN:`
  (exit 3: the Mac was locked, the STT test service was down or lagging, or
  the app had no Accessibility grant) and a lost keyboard focus measure the
  Mac, not the change. Put the line in the Proof section and ask the owner; don't
  redispatch. A later commit may run again after the hour; take that run only
  when the commit changed one of those files since the last one.

The last two count only runs whose job ran a step. Adding any other label to
a PR creates a UI Smoke run that is skipped or cancelled before it reaches the
Mac; the wrapper lists those as ignored.

`--override "<why>"` skips all but the queued-run refusal, for a rerun the
owner asked for; quote the reason in the PR. The `needs-ui-smoke` label
dispatches without these checks, so it is the owner's, not an agent's.

A stack of PRs takes at most one run, from its top branch, before its lowest
layer merges: the top's diff against main holds every layer. The evening runs
on main (18:00 to 21:00 UTC) cover what no PR claimed, and the release gate
covers the rest.

Paste the `spoken:` / `inserted:` / `PASS:` lines in the Proof section.

The speech service on the Mac is shared, and other agents' model work can put
it seconds behind the audio, which fails a correct app (#548).
`scripts/e2e/speech-service-probe.py` plays the scenario's WAV to the service
without the app and times the final transcript from the end of the speech. It
runs before the app starts and after any failed scenario. A failure becomes
`NOT RUN:` with the measured lag only when the probe finds the service past
3.5 s: the check's 2 s of silence plus the app's 1.5 s minimum finalization
wait. An idle service measures about 2.6 s. A probe within the limit, or one
that measured nothing, leaves the failure a `FAIL:`, so a broken session still
fails. The `speech service probe:` lines are in the log either way.

A new scenario is a file in `scripts/e2e/scenarios/` (`mode`, `phrase`,
`min_word_accuracy`), not a new script. Polishing is off in every scenario so
the score measures the app; model quality belongs to `eval-e2e`.

## Proving a change to the polish path with the request goldens

Polishing is off in the e2e check, so a change between the stop-commit and
the polish model is proved by `PolishRequestGoldenTests` instead. Each case
drives `finishStoppedSession` through the shared fakes and pins, as JSON under
`Tests/localvoxtralTests/Fixtures/PolishRequestGoldens/`, what one commit
sent (request, configuration) and wrote (session record, committed text,
error line, pasteboard read counts). The cases cover both prompt profiles,
the speaker profile, every context source alone and in conflict, the
clipboard payload macro, a template without the dictionary slot, the three
backend configurations and every polish failure.

A refactor of that path (#432 steps 5 to 7) leaves every fixture untouched;
`git diff --stat` of the directory goes in the Proof section. A PR that
changes what reaches the model deletes the affected fixture, re-runs the
suite to record it, and explains the new bytes in the PR. From a non-Mac box
the recorded file lands only on the build host, which cannot send files
back, so the test also prints it between `POLISH GOLDEN BEGIN/END` lines in
`.build/last-remote.log`; lift it from there. A mismatch never rewrites a
fixture.

## The live herdr lane

`HerdrIntegrationTests` (`remote-build.sh integration-herdr`) is the only
place anything checks that **herdr still behaves the way the remote-herdr
join assumes it does**. `docs/agent/remote-herdr-panel-binding.md` records
those assumptions; before this lane they were documented hopes. Each one that
a live server can answer has its own named test, so a herdr upgrade that
changes it fails with a message naming the assumption rather than silently
un-authorizing field joins.

What is real in the lane: `HerdrSocketClient` on a forwarded unix socket,
`ClaudeRemoteHerdrForwardService` spawning a real supervised `ssh -N -L`,
`SSHDestinationCanonicalizer.live()` running real `ssh -G`,
`ClaudeRemoteEnrollmentService.setupRemoteHerdr` (the setup run's herdr step)
patching the fixture server's own herdr `config.toml` over a real ssh session, and
`HerdrPanelBindingProbe` / `HerdrPanelMicIndicator` on top of all of it. The
ONE fixture is the focused surface: a real herdr client on a pty, read from
its typescript instead of through accessibility.

Assumptions currently pinned against the live server: only a whole-view App
client renders the agents sidebar (`terminal attach` renders the raw pane and
cannot echo the token — the load-bearing one); both a JSON `null` and an
empty string clear a `pane.report_metadata` token; the `ttl_ms` window is
1…86_400_000 inclusive; `pane.process_info` still reports named foreground
processes; `pane.read` answers only about the pane asked for; and `ssh -G`
identity matching accepts an alias that differs only in `User` while
rejecting one that differs in port. On herdr 0.9+ the lane additionally pins
federation: `machine list --json` reports `selected` for the viewed machine
and none for Local, and the production catalog reader resolves the same
answer; the local server still answers `pane.current` with its own focused
pane while a machine is selected; the agents panel composes rows from every
connected machine at once (a remote token renders while Local is displayed
and vice versa, retiring the whole-view discriminator for federated
clients); those rows render from the LOCAL client config alone; and
`terminal session observe` renders no panel token, like `terminal attach`.

Fixture and host requirements (`scripts/herdr-integration-fixture.sh`):

- `herdr` must be installed on the machine running the lane. Its absence is a
  LOUD failure naming the install step, never a skip — a lane that quietly
  does nothing about herdr is indistinguishable from one that passed.
- With no destination the fixture provisions its OWN loopback sshd (its own
  host key, user key and `authorized_keys` file — the account's are never
  touched), so the lane is hermetic and needs no second machine. Pass an ssh
  destination to run the identical lane against a real second host.
- It runs BESIDE a herdr the account is already running (the owner's runner
  account runs one all day). Every fixture herdr process — server, CLI calls,
  surfaces, and the remote half behind the loopback sshd's forced
  `authorized_keys` environment — gets its own socket and
  `XDG_CONFIG_HOME` / `XDG_STATE_HOME` under the run's workdir, which is where
  herdr resolves `config.toml`, `session.json`, plugins and client state from.
  The account's herdr files and server are never read, written or addressed,
  and the enrollment config patch over the fixture alias edits the fixture
  server's config. Over a caller-supplied destination that patch would edit
  the second host's real config, so that one test fails up front in
  destination mode.
- For the duration of a run the fixture appends three delimited blocks to the
  account's `~/.ssh/config`, and refuses to start if the account already
  defines one of its aliases (ssh keeps the first value, so the lane would
  dial the account's host). It touches the REAL ssh config on purpose: the
  code under test never passes `-F`, so an alias that lived only in a
  fixture-local file would exercise an invocation shape the app never
  produces. The ssh config is restored by REMOVING those blocks, not by
  writing a copy back, so an edit made while the lane runs survives. The three
  blocks are the connection block, the canonicalization-test block, and the
  federation block (the federated target's loopback alias); federated clients
  run with `XDG_STATE_HOME` pointed at the run's scratch `client-state-home`
  and the hermetic remote server listens on the run's short `remote.sock`,
  never on the account's catalog or sockets.
- Because nothing runs on SIGKILL, the pristine ssh config lives at a stable
  path (`~/.localvoxtral-herdr-fixture-hold/`) with a manifest naming the run
  that took them — never in the run's own temp dir, which a killed run would
  strand. `up` restores a dead run's hold before touching anything and
  refuses while a live run owns it; it will never back up an already-modified
  file over a pristine copy, which is the step that would destroy the
  originals. `status` and `recover` do it by hand
  (`scripts/mac/README.md`), and `scripts/ci/test-herdr-fixture-recovery.sh`
  holds that behavior per-push without needing herdr at all (including
  restoring the herdr copies a pre-#323 fixture's hold still carries).
- The suite has no `XCTSkip`. Every other lane skips it by name
  (`--skip HerdrIntegrationTests` in `remote-build.sh test` and in CI's unit
  step), and running it without its marker fails with the enablement
  instructions.

When must it run? For `scripts/ci/herdr-lane-filter.sh` path matches or the
literal `[run-herdr-integration]` marker, on the same event-payload terms as
the LLM lanes. A manual `ci.yml` dispatch also runs it by default, which is the
supported way to repeat this live external contract without manufacturing
commits; `-f herdr=false` opts one dispatch out. That is what
`scripts/try-pr.sh --dogfood` passes: that dispatch exists to produce an
artifact, not to repeat the herdr contract. The
rule behind the list: anything that changes what the app
SAYS to herdr, what it BELIEVES herdr answered, how the forward reaching
herdr is opened or leased, which host that forward reaches, or the recorded
assumptions themselves. Editing
`docs/agent/remote-herdr-panel-binding.md` matches too — a changed assumption
that was never re-measured is exactly the failure this lane exists to
prevent. Not required for UI, insertion, audio, or model work. Either way the
PR's Proof section carries the scoreboard or a one-line justification for
skipping.

The fixture records the runner account, herdr binary/version, inherited and
isolated socket settings, terminal variables, requested and actual pty size,
rendered sidebar width, sshd port, forward sockets, and pane lifecycle. CI
uploads those files as `herdr-lane-diagnostics` even when the lane passes. The
artifact deliberately excludes the fixture's ephemeral host and user keys.
On 2026-09-07 this evidence exposed an account-sensitive startup race: the
`tom` launchd runner kept provisional `w1:p1` alive across two one-second
reads, then replaced it with `w2:p1` 50–200 ms after readiness; the `builder`
SSH account reached `w2:p1` before the same check. Both used herdr 0.8.2,
45×130 ptys, and a rendered 26-cell sidebar. Pane readiness therefore needs
three consecutive resolving samples. Do not trade that condition for a longer
token TTL or surface timeout; neither participates in this race.

Worker builds on the Mac must not overlap the lane. Measured 2026-09-07 on
the build host (per-request latency tap in `HerdrSocketClient`, 10 lane runs
idle + 10 with one concurrent `swift build`): idle 10/10 green with
p50/p99/max 110/121/126 ms; loaded 9/10 with p50/p99/max 108/123/137 ms and
zero unexpected refusals or timeouts across 379 successful requests — but one
loaded run failed `testMicIndicatorRefreshesTheTokenAndClearsItOnStop`
because a `pane get` read immediately after the stop still showed the token
while every socket request in that run had succeeded in ~100 ms. The socket
path is NOT slow under load (36× inside the 5 s timeout); the read lags the
server's ack under CPU contention. The lane therefore polls for the clear
(bounded below the 8 s token TTL, so a truly lost clear still fails) — and a
red lane with worker builds running beside it means re-run the lane alone
before debugging the diff. The mic-indicator lifecycle test holds its injected
first refresh until that deliberate clear is observed; accelerating the
refresh onto a 50 ms wall-clock sleep makes clear-versus-refresh ordering a
runner scheduler race instead of testing the four-second production cadence.

The speechd live-model lane follows the same owner constraint: it runs only for
`scripts/ci/speechd-lane-filter.sh` matches or `[run-speechd-integration]`.
SpeechHelper engine/pin, packaging, or integration-contract changes must run it;
the Metal-free SpeechHelper unit suite remains per-push on self-hosted CI.

Agent-dictation E2E eval (`AgentDictationE2EEvalTests`, weekly `eval-e2e.yml`
+ `remote-build.sh eval-e2e`): model/prompt/feature-pipeline changes — anything
the rule above marks LLM-relevant, plus the TTS→ASR→polish harness itself —
MUST paste the eval-e2e scoreboard in the PR's Proof section, or explicitly
justify skipping it in one line. Only the 7 migrated punctuation cases are
`required` today; Phase 3 calibration will promote cases that prove stable
across server states (restarts / prompt-cache configurations) to `required` —
promotion PRs must carry that cross-state evidence.

Its ASR stage talks to a speech test service on the Mac, which runs the helper
installed there, never the PR's build. Each dictation model in
`SpeechModelCatalog` has its own service, one row of
`scripts/mac/test-speech-models.tsv`, and `eval-e2e --asr <name>` scores that
one (default `voxtral`). To score a helper change, install the PR's packaged
.app for that row first (`scripts/mac/README.md`, "Speech test services").

Mistral arm of the same eval: `MISTRAL_API_KEY=… ./scripts/remote-build.sh
eval-e2e --provider mistral [EvalRecordings/agent-dictation/<set>]` moves BOTH
live stages to Mistral's hosted API — the hosted realtime socket for ASR, and a
polish configuration built by `SettingsStore` itself in `.mistralAPI` mode — so
its scoreboard is what proves `Mistral API` mode end to end. It needs no local
speechd and no prior `package` run (nothing bundled is in the loop), and it
turns `polishContextTrustedEndpointEnabled` on, because `api.mistral.ai` is not
loopback and every clipboard/repo-vocabulary case would otherwise score an
ungrounded polish. It BILLS the owner's account (≈0.006 USD/min of audio plus
Medium 3.5 polish tokens), so it is by-hand only: never scheduled, never in CI,
and the key rides a 0600 marker the script removes on exit.

## Human agent-eval recordings and ablations

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

## Replaying stored dictations

Whether localvoxtral learns a user is measured on that user's own recordings,
run twice on identical input. With **Keep dictation audio on this Mac** on (Settings →
History), each saved dictation keeps its WAV. On the Mac that dictated, as
that user, `./scripts/export-dictation-replay.sh <dir>` copies the history
store, the recordings, the learned terms and Names and terms into a set.
Copy it to the gitignored `EvalRecordings/replay/<set>/` of a checkout. The run
below rsyncs the checkout, set included, to the build host, so the
dictations' text and audio land there too. Then:

```bash
./scripts/remote-build.sh package
./scripts/remote-build.sh eval-e2e --replay EvalRecordings/replay/<set>
```

`AgentDictationE2EEvalTests.testReplayStoredDictations` transcribes each
Overlay Buffer dictation once on the live speech service, then polishes the
transcript through the production stop-commit path twice: **day 0** with
Names and terms only, **today** with every confirmed learned term added. It
scores the transcript and both arms against the text the dictation inserted
at the time: word accuracy, and recall of the terms that text spells. That
text is what polishing produced then, not a checked reference, so a gain
shows as today moving closer to it than day 0 on the same audio.

The log prints numbers only (`replay:` lines); paste those, never
transcripts. Delete the set from the checkout and the Mac when done.
