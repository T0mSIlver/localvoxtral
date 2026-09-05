# Test tiers & eval lanes

| Tier | What | When | Cost |
|---|---|---|---|
| 0 | Unit suite (500+ tests) + PolishHelper/SpeechHelper unit suites + packaging + launch smoke | every non-fast-path PR/push, CI (helper unit suites: self-hosted lanes only) | ~1 min |
| 1 | `RealtimeAPIVLLMIntegrationTests` vs the live local speechd STT test service: real inference through the production websocket client, word-accuracy asserted | every non-fast-path PR/push on the self-hosted runner; locally via `remote-build.sh integration` | ~20 s |
| 1 | `PolishHelperIntegrationTests`: the packaged polishing helper vs the real pinned model — production request path, shared eval baseline, parent-pid tether | conditional in CI (self-hosted, after packaging): only when the diff touches LLM-relevant paths or the PR opts in with `[run-llm-eval]` — see "When must the LLM lanes run?"; locally via `remote-build.sh integration-polishd` | minutes (4B weights + live inference) |
| 1 | `SpeechHelperIntegrationTests`: packaged speechd vs real spoken audio/model through the production realtime client — word accuracy, append-only delta/done parity, parent-pid tether | conditional in CI (self-hosted, after packaging): only when the diff touches speechd-relevant paths or the PR opts in with `[run-speechd-integration]`; locally via `remote-build.sh integration-speechd` | minutes (4B weights + live inference) |
| 1 | `HerdrIntegrationTests`: the remote-herdr join machinery vs a LIVE `herdr` server over a REAL `ssh -L` forward — real socket client, real forward coordinator, real `ssh -G` canonicalization, real `~/.config/herdr/config.toml` patch; the only fixture is the focused surface (a real herdr client on a pty) | conditional in CI (self-hosted): only when the diff touches herdr-relevant paths or the PR opts in with `[run-herdr-integration]`; locally via `remote-build.sh integration-herdr [ssh-destination]` | ~1 min (no model weights) |
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
- Do not "just rerun" a red run to see if it is flaky before reading its log
  either — the flake signatures are enumerated in
  `docs/agent/field-debugging.md`, and a rerun is a full second run.

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
`ClaudeRemoteEnrollmentService.configureRemoteHerdrPanel` patching a real
`~/.config/herdr/config.toml` over a real ssh session, and
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
rejecting one that differs in port.

Fixture and host requirements (`scripts/herdr-integration-fixture.sh`):

- `herdr` must be installed on the machine running the lane. Its absence is a
  LOUD failure naming the install step, never a skip — a lane that quietly
  does nothing about herdr is indistinguishable from one that passed.
- With no destination the fixture provisions its OWN loopback sshd (its own
  host key, user key and `authorized_keys` file — the account's are never
  touched), so the lane is hermetic and needs no second machine. Pass an ssh
  destination to run the identical lane against a real second host.
- For the duration of a run the fixture OWNS the account's
  `~/.config/herdr/config.toml` and `session.json` and appends two delimited
  blocks to `~/.ssh/config`. It touches the REAL ssh config on purpose: the
  code under test never passes `-F`, so an alias that lived only in a
  fixture-local file would exercise an invocation shape the app never
  produces. The ssh config is restored by REMOVING those blocks, not by
  writing a copy back, so an edit made while the lane runs survives.
- Because nothing runs on SIGKILL, the pristine originals live at a stable
  path (`~/.localvoxtral-herdr-fixture-hold/`) with a manifest naming the run
  that took them — never in the run's own temp dir, which a killed run would
  strand. `up` restores a dead run's hold before touching anything and
  refuses while a live run owns it; it will never back up an already-modified
  file over a pristine copy, which is the step that would destroy the
  originals. `status` and `recover` do it by hand
  (`scripts/mac/README.md`), and `scripts/ci/test-herdr-fixture-recovery.sh`
  holds that behavior per-push without needing herdr at all.
- It refuses to start when a herdr server is already running for that account,
  rather than trampling a human's session.
- The suite has no `XCTSkip`. Every other lane skips it by name
  (`--skip HerdrIntegrationTests` in `remote-build.sh test` and in CI's unit
  step), and running it without its marker fails with the enablement
  instructions.

When must it run? For `scripts/ci/herdr-lane-filter.sh` path matches or the
literal `[run-herdr-integration]` marker, on the same event-payload terms as
the LLM lanes. The rule behind the list: anything that changes what the app
SAYS to herdr, what it BELIEVES herdr answered, how the forward reaching
herdr is opened or leased, which host that forward reaches, or the recorded
assumptions themselves. Editing
`docs/agent/remote-herdr-panel-binding.md` matches too — a changed assumption
that was never re-measured is exactly the failure this lane exists to
prevent. Not required for UI, insertion, audio, or model work. Either way the
PR's Proof section carries the scoreboard or a one-line justification for
skipping.

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
