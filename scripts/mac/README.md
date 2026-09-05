# Mac build-host scripts

## Metal toolchain (Xcode 26+) — required for packaging

`package_app.sh` builds the bundled polishing helper (`PolishHelper/`,
MLX Swift) with xcodebuild, which compiles Metal kernels. On Xcode 26+ the
Metal compiler is a separate ~700 MB component that is NOT installed with
Xcode; one-time setup per build host:

```bash
xcodebuild -downloadComponent MetalToolchain
xcodebuild -showComponent MetalToolchain   # expect "Status: installed"
```

Installed on the build host 2026-07-07 (builder user; ci.yml self-provisions
it for the runner user, since activation is PER-USER even though the asset
lands system-wide). Gotchas: the catalog fetch fails transiently sometimes
("Failed fetching catalog for assetType") — just retry; and `xcrun --find
metal` succeeds even when the component is missing (the shim exists), so
only an actual invocation (`xcrun metal --version`) proves it works. Runs
as a normal user, no sudo needed.

## herdr, for the live integration lane

`./scripts/remote-build.sh integration-herdr` (and CI's conditional herdr
lane) needs the `herdr` binary present on this machine. It is the only
prerequisite — the lane provisions its own loopback sshd, its own keys and its
own `authorized_keys` file, so nothing is added to any account's real SSH
trust.

```bash
brew install herdr        # or https://herdr.dev; HERDR_BIN overrides the lookup
herdr --version           # 0.8.2 is what the lane's assumptions were measured against
```

Its absence fails the lane loudly with the install step rather than skipping.

What the lane borrows while it runs, and gives back on teardown: the running
account's `~/.config/herdr/config.toml` and `session.json`, plus two delimited
blocks in its `~/.ssh/config`. It refuses to start at all if that account
already has a herdr server running, so it can never trample a live session —
if the owner is using herdr on the runner account, the lane fails instead of
taking over.

### If a run is killed before it gives them back

Nothing runs on SIGKILL, so the pristine originals do not live in the run's
temp dir — they live at a stable path, `~/.localvoxtral-herdr-fixture-hold/`,
with a manifest naming the run that took them. The next `up` restores a dead
run's hold before doing anything else and refuses while a live run owns it, so
a killed run heals itself and two runs never fight over one account. To do it
by hand:

```bash
./scripts/herdr-integration-fixture.sh status    # is anything held, and by whom
./scripts/herdr-integration-fixture.sh recover   # restore and drop the hold
```

`recover` needs no arguments and works even if the run's temp dir is gone. It
refuses while the holding process is still alive — stop that first.

Details and the full assumption list: `docs/agent/test-tiers.md` and
`docs/agent/remote-herdr-panel-binding.md`.

## On-demand test servers (speechd + polishd) — owner runbook

The two build-host model servers used by the integration/eval suites are the
app's OWN bundled Swift helpers (they replaced the retired Python voxmlx /
mlx-lm services in the 2026-07 migration — see "Migration" below):

- `com.localvoxtral.testspeechd` — `localvoxtral-speechd` on **port 8000**,
  tier-1 realtime STT (the same OpenAI-Realtime websocket the app ships).
- `com.localvoxtral.testpolishd` — `localvoxtral-polishd` on **port 8080**,
  the LLM-polish-eval reference chat/completions endpoint.

Short service names are `speechd` / `polishd` (the retired `voxmlx` / `mlxlm`
are still accepted as deprecated aliases). They run **launch-on-demand with an
idle reaper** so RAM is only spent around actual test runs — hands-free for
both CI and `remote-build.sh`.

Because they are Metal-using MLX helpers, they MUST run from a PACKAGED
(xcodebuild) `.app` — a bare `swift build` binary cannot load its metallib.
The plists point at helper binaries inside a stable installed copy at
`/Users/Shared/localvoxtral/testservers/localvoxtral.app`, refreshed with
`lv-test-servers.sh install-helpers <path-to-.app>`. The helpers also NEVER
auto-download weights: the pinned models must be pre-downloaded into the
service account's Hugging Face cache (below), or `ensure` just times out with a
clear log line.

How it works (`scripts/mac/lv-test-servers.sh` is the single source of truth):

- Each agent is `RunAtLoad false` + `KeepAlive { PathState { <trigger>: true } }`.
  launchd runs the server **while a trigger file exists** and stops it (freeing
  the weights) when the file is removed. The triggers live in a world-writable
  run dir so any account — the CI runner user, the SSH build-gate account, the
  owner — can start a server just by touching a path (no cross-user
  `launchctl` call, which macOS forbids without root).
- **Warming:** a consumer runs `lv-test-servers.sh ensure <name>` (CI does this
  before the integration step; `remote-build.sh` asks the gate's `ensure` verb;
  the owner can run it directly). It touches the trigger — starting the server
  if down — and blocks until the port is healthy. Touching an already-running
  server just bumps the trigger mtime, resetting the idle window, so a burst of
  runs reuses one warm process (no cold reload every few seconds).
- **Reaping:** a third LaunchAgent (`com.localvoxtral.testservers-reaper`) runs
  `lv-test-servers.sh reap` on a `StartInterval`. For any service idle longer
  than the window (default 20 min, `LV_TEST_SERVER_IDLE_SECONDS`) it removes the
  trigger (so launchd won't relaunch it) **and** sends the job an explicit
  `launchctl kill SIGTERM` — because launchd does not reliably terminate an
  already-running process when a `KeepAlive` `PathState` condition flips false,
  removing the trigger alone would leave the weights resident. The reaper runs
  in the GUI-owner domain, so the `launchctl kill` is permitted. The
  compromise: warm within a work session / CI burst, RAM freed once the machine
  goes quiet — next use pays one cold model load.
- **Manual unload:** `lv-test-servers.sh stop [speechd|polishd|all]` frees the
  weights NOW without waiting for the idle window — same stop path as reap
  (trigger removed, `SIGTERM`→`SIGKILL`, blocks until the port closes). Default
  target is `all`. Stop signals BOTH the new (`testspeechd`/`testpolishd`) and
  retired (`voxmlx`/`mlxlm`) labels plus a port-bound fallback, so it works
  whichever generation is loaded.
- **Robustness:** an interrupted run or a sleeping Mac just leaves the trigger
  behind; the server stays warm and the reaper collects it later. There is no
  lock to get stuck and no orphan process (launchd owns each server; the reaper
  drops the trigger then SIGTERMs the process). On wake, the coalesced reaper
  run reclaims anything stale.

### One-time install (trusted owner session on the Mac)

```bash
# 1. Shared run dir for the trigger + activity-stamp files. World-writable and
#    sticky (like /tmp) so any account — CI runner, gate account, owner — can
#    start a server, but OWNED BY THE OWNER (the reaper's user) so the reaper's
#    sticky-bit exemption lets it delete other accounts' files.
#    DO THIS FIRST — before (re)bootstrapping the agents below. launchd sets up
#    the KeepAlive PathState watch on <run dir>/<svc>.want at bootstrap; if the
#    run dir's parent doesn't exist yet, bootstrap fails with
#    "Bootstrap failed: 5: Input/output error".
sudo install -d -m 1777 -o "$(id -un)" /Users/Shared/localvoxtral/run
sudo install -d -m 0755 /Users/Shared/localvoxtral        # log dir, if absent

# 2. Stable installed .app whose Metal-capable helper binaries the plists run.
#    Build a bundle WITH the helpers (never SKIP_SPEECHD/POLISHD), then install:
#      ./scripts/package_app.sh release           # produces dist/localvoxtral.app
#      scripts/mac/lv-test-servers.sh install-helpers dist/localvoxtral.app
#    (or point install-helpers at a try-pr.sh download / a release .app). This
#    copies to /Users/Shared/localvoxtral/testservers/localvoxtral.app. Refresh
#    it the same way whenever the helpers change; `stop all` then makes the next
#    `ensure` cold-start from the new copy.

# 3. Pre-download the pinned models into the OWNER's HF cache (the account whose
#    launchd domain runs the services — the one bootstrapping the plists below).
#    The helpers NEVER auto-download: a missing model makes speechd/polishd log
#    an error and exit, launchd relaunch-loops it, and `ensure` times out with a
#    clear message. Keep these pins in sync with SpeechModelCatalog.defaultOption
#    and PolishModelCatalog.defaultOption in the app source.
python3 -m pip install --user -U 'huggingface_hub[cli]'   # or: uv tool install huggingface_hub
hf download T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead \
  --revision 247f2eeccf962fbcaf85e361731a5e75b2d8cac1     # speechd (STT, 8000)
hf download mlx-community/Qwen3.5-4B-OptiQ-4bit \
  --revision 41eccc3316fd4bf4b27cedf4924fe23ce44e77d9     # polishd (polish, 8080)
```

> The polishd service is the *prompt-eval reference endpoint* for
> `LLMPolishPromptEvalTests` / `remote-build.sh eval-llm`. It now runs the SAME
> bundled engine and default 4B model as production (so eval-llm measures the
> shipped prompt+model combo; production-engine parity is also covered by
> `./scripts/remote-build.sh integration-polishd`). Don't point evals at the
> app-managed server on 8472 — it only exists while the app is running with
> polishing enabled, so it vanishes whenever the app quits.

### polishd LaunchAgent (on-demand)

Note the trigger path: it stays `run/mlxlm.want` (the retired name) on purpose —
that is the stable cross-generation rendezvous so an already-installed gate and
un-updated reaper keep working through the swap (see the `lv-test-servers.sh`
header). Only the Label + ProgramArguments changed.

```bash
cat > ~/Library/LaunchAgents/com.localvoxtral.testpolishd.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.localvoxtral.testpolishd</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/Shared/localvoxtral/testservers/localvoxtral.app/Contents/MacOS/localvoxtral-polishd</string>
    <string>--model</string><string>mlx-community/Qwen3.5-4B-OptiQ-4bit</string>
    <string>--model-revision</string><string>41eccc3316fd4bf4b27cedf4924fe23ce44e77d9</string>
    <string>--port</string><string>8080</string>
  </array>
  <!-- On-demand: launchd starts this while the trigger file exists and stops
       it (freeing the weights) when lv-test-servers.sh reap removes it. -->
  <key>RunAtLoad</key><false/>
  <key>KeepAlive</key>
  <dict>
    <key>PathState</key>
    <dict><key>/Users/Shared/localvoxtral/run/mlxlm.want</key><true/></dict>
  </dict>
  <key>StandardOutPath</key><string>/Users/Shared/localvoxtral/polishd.log</string>
  <key>StandardErrorPath</key><string>/Users/Shared/localvoxtral/polishd.log</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.localvoxtral.testpolishd.plist
```

### speechd LaunchAgent (on-demand)

Same as polishd, the trigger path stays `run/voxmlx.want` (retired name) as the
stable cross-generation rendezvous — the CI warm step (`ensure speechd`), the
gate, and an un-updated reaper all touch/read exactly this path, so the STT lane
keeps warming with no gate/reaper reinstall. `StandardOutPath` is the file the
gate's `voxlog`/`VOXLOG_FILE` reads.

```bash
cat > ~/Library/LaunchAgents/com.localvoxtral.testspeechd.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.localvoxtral.testspeechd</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/Shared/localvoxtral/testservers/localvoxtral.app/Contents/MacOS/localvoxtral-speechd</string>
    <string>--model</string><string>T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead</string>
    <string>--model-revision</string><string>247f2eeccf962fbcaf85e361731a5e75b2d8cac1</string>
    <string>--port</string><string>8000</string>
    <string>--cache-limit-mb</string><string>4096</string>
  </array>
  <!-- On-demand: launchd starts this while the trigger file exists and stops
       it (freeing the weights) when lv-test-servers.sh reap removes it. -->
  <key>RunAtLoad</key><false/>
  <key>KeepAlive</key>
  <dict>
    <key>PathState</key>
    <dict><key>/Users/Shared/localvoxtral/run/voxmlx.want</key><true/></dict>
  </dict>
  <key>StandardOutPath</key><string>/Users/Shared/localvoxtral/speechd.log</string>
  <key>StandardErrorPath</key><string>/Users/Shared/localvoxtral/speechd.log</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.localvoxtral.testspeechd.plist
```

### Idle-reaper LaunchAgent

```bash
cat > ~/Library/LaunchAgents/com.localvoxtral.testservers-reaper.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.localvoxtral.testservers-reaper</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/Users/REPLACE_ME/work/localvoxtral/scripts/mac/lv-test-servers.sh</string>
    <string>reap</string>
  </array>
  <!-- Every 5 min: finer than the 20-min idle window, so RAM is reclaimed
       within ~5 min of the window elapsing. Coalesces across sleep. -->
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/Users/Shared/localvoxtral/testservers-reaper.log</string>
  <key>StandardErrorPath</key><string>/Users/Shared/localvoxtral/testservers-reaper.log</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.localvoxtral.testservers-reaper.plist
```

(Point the script path at a stable checkout of this repo, or copy
`lv-test-servers.sh` to a fixed location. Override the idle window by adding an
`EnvironmentVariables` dict with `LV_TEST_SERVER_IDLE_SECONDS`. During the
migration, `git pull` that stable checkout so the reaper runs the new script —
though an OLD reaper still reaps the new services via its port-bound fallback,
since it keeps reading the same `run/voxmlx.want` / `run/mlxlm.want` triggers.)

### Verify (owner-side proof)

```bash
scripts/mac/lv-test-servers.sh status                 # both: trigger absent, down
scripts/mac/lv-test-servers.sh ensure speechd         # cold-starts, blocks to warm
scripts/mac/lv-test-servers.sh status                 # speechd: trigger present, up
# Warm reuse: a second ensure returns instantly ("already warm") and resets idle.
scripts/mac/lv-test-servers.sh ensure speechd
# Idle reap: age the trigger AND the stamps past the window, then reap (or just
# wait for the reaper agent), and confirm launchd stopped the server / freed
# RAM. Age both — reap keys off the NEWEST of the trigger + stamps, so a
# freshly cold-started trigger (recent mtime) would otherwise keep it "warm".
# The trigger/stamp filesystem key stays `voxmlx` for speechd (stable rendezvous).
# reap BLOCKS until the port actually closes (SIGTERM drains the MLX server in
# ~2-3s; it escalates to SIGKILL after STOP_GRACE), so the status right after
# reflects the real state — no need to sleep.
touch -t 202001010000 /Users/Shared/localvoxtral/run/voxmlx.*   # .want + .seen.*
scripts/mac/lv-test-servers.sh reap                   # removes trigger + stamps, TERM→KILL
scripts/mac/lv-test-servers.sh status                 # speechd: absent, down
# polishd (8080) is the same, keyed on run/mlxlm.want:
scripts/mac/lv-test-servers.sh ensure polishd
```

If the SSH build gate is installed, `remote-build.sh integration|eval-llm|eval-e2e`
warm the right server through the gate's `ensure` verb automatically (it sends
`ensure speechd`/`polishd`, falling back to the `voxmlx`/`mlxlm` alias for an
un-reinstalled gate); CI warms speechd in its own step before the integration
suite (and `eval-e2e.yml` before the nightly agent-dictation eval). The
`svc-status`/`diag`/`voxlog` verbs still probe ports 8000/8080.

No gate change is needed for the `eval-e2e` lane: its payload is a plain
`swift test --filter AgentDictationE2EEvalTests` (already allowlisted by the
`swift test` prefix rule) and its enablement rides the rsynced tree as the
gitignored marker `.agent-eval-e2e-enable.json`. The lane also caches
synthesized TTS WAVs under `~/Library/Caches/localvoxtral-eval/wav` in the
build/runner account — safe to delete any time; the next run regenerates them.
For a human-voice baseline, create a complete gitignored set with
`scripts/record-agent-eval.sh`, then pass its repo-relative directory to
`remote-build.sh eval-e2e`; rsync carries the WAVs and strict manifest to this
same private build directory without changing the gate payload.
When capture happens in a Mac checkout, `scripts/run-agent-eval-local.sh`
runs the same env-gated suite directly and avoids copying the voice set through
another source checkout.

### Migration: retire the Python voxmlx/mlx-lm services

One-time owner steps to swap the two Python test services for the bundled Swift
helpers. The trigger paths (`run/voxmlx.want` / `run/mlxlm.want`) are unchanged,
so CI stays green throughout — do these in a trusted GUI-owner session on the
Mac. `$UID` is the owner's uid (`id -u`).

```bash
# 0. Prereqs (skip if already present from the on-demand install above):
sudo install -d -m 1777 -o "$(id -un)" /Users/Shared/localvoxtral/run
sudo install -d -m 0755 -o "$(id -un)" /Users/Shared/localvoxtral

# 1. Install the Metal-capable helper binaries (from a bundle built WITH them):
cd ~/work/localvoxtral && git pull
./scripts/package_app.sh release
scripts/mac/lv-test-servers.sh install-helpers dist/localvoxtral.app

# 2. Pre-download the pinned models into THIS account's HF cache (see step 3 of
#    the on-demand install above — hf download the Voxtral + Qwen3.5-4B pins).

# 3. Bootout the retired Python services and remove their plists:
launchctl bootout "gui/$UID/com.localvoxtral.voxmlx" 2>/dev/null || true
launchctl bootout "gui/$UID/com.localvoxtral.mlxlm"  2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.localvoxtral.voxmlx.plist \
      ~/Library/LaunchAgents/com.localvoxtral.mlxlm.plist

# 4. Bootstrap the new helper plists (templates above). The bootout lines make
#    a rerun of this step safe — bootstrap fails with "5: Input/output error"
#    when the label is already loaded:
launchctl bootout "gui/$UID/com.localvoxtral.testspeechd" 2>/dev/null || true
launchctl bootout "gui/$UID/com.localvoxtral.testpolishd" 2>/dev/null || true
launchctl bootstrap "gui/$UID" ~/Library/LaunchAgents/com.localvoxtral.testspeechd.plist
launchctl bootstrap "gui/$UID" ~/Library/LaunchAgents/com.localvoxtral.testpolishd.plist

# 5. Delete the retired mlx-lm venv/wheel (no longer used by anything):
rm -rf ~/.local/share/localvoxtral-eval/mlx-lm

# 6. Reinstall the SSH build gate so `ensure speechd|polishd`, the /health probe
#    arm on 8080, and the new process/label reporting take effect (see the gate
#    install section below), and `git pull` the reaper's stable checkout.

# 7. Point the gate's voxlog verb at the new STT log (gate account = the user
#    the SSH forced command runs as; same file as the "Config" section below):
echo 'VOXLOG_FILE=/Users/Shared/localvoxtral/speechd.log' >> ~/.localvoxtral-gate.conf

# 8. Verify (the "Verify" block above):
scripts/mac/lv-test-servers.sh ensure speechd && scripts/mac/lv-test-servers.sh ensure polishd
scripts/mac/lv-test-servers.sh status
```

Verification: `RealtimeAPIVLLMIntegrationTests` (via `remote-build.sh
integration`, or CI) must stay green against the new speechd service, and
`remote-build.sh eval-llm` scores the default prompt against polishd — re-run it
and confirm the scoreboard (the 4B reference replaces the old 0.8B mlx-lm
reference, so expect equal-or-better numbers). Both are OWNER-verified: the
repo-side changes are compatible with either generation behind the ports, but
only a live run on the swapped host proves accuracy parity.

## Runner node re-sign agent — TCC grants that survive runner auto-updates

`runner-node-resign.sh` keeps the self-hosted runner's bundled node binaries
(`~/actions-runner/externals/node*/bin/node` — BOTH of them, node20 and
node24) signed with the owner's stable `localvoxtral-dev` identity and a
fixed identifier. macOS keys a TCC grant for an unsigned binary to its
content hash, so every runner auto-update used to silently invalidate the
Accessibility + Screen Recording grants the tier-2 GUI lanes need (field
incidents 2026-07-24/25: red ui-smoke, real TCC prompts on the GUI session).
With a stable signature the grant is keyed to identity+identifier and
survives updates untouched. Auto-update stays ON — there is no monthly
manual-update ritual with this in place.

A LaunchAgent (`com.localvoxtral.runner-node-resign`) re-signs automatically:
`WatchPaths` on `externals/` fires when an update swaps node (plus an hourly
`StartInterval` sweep as backstop), waits for any in-flight CI job to drain
(never stops the service under a live `Runner.Worker`), then
`svc.sh stop` → `codesign --force` → `svc.sh start`. Sign failures still
restart the service — a broken grant is recoverable, a dead runner is not.
Log: `~/Library/Logs/localvoxtral-runner-node-resign.log`.

### One-time install (owner GUI session on the Mac)

```bash
# 1. Install + bootstrap the agent (copies the script to a stable path under
#    ~/Library/Application Support/localvoxtral/bin — the repo checkout may
#    be a garbage-collected rsync dir, the agent must not point into it):
scripts/mac/runner-node-resign.sh install-agent

# 2. FIRST signed pass BY HAND, so the keychain "Always Allow" prompt for the
#    signing key lands on you, not on the silent agent:
"$HOME/Library/Application Support/localvoxtral/bin/runner-node-resign.sh" run

# 3. System Settings > Privacy & Security: in BOTH Accessibility and Screen
#    Recording, REMOVE the existing node rows and re-add BOTH
#    ~/actions-runner/externals/node*/bin/node binaries (4 entries total).
#    The old rows are keyed to the pre-signing hashes and never match again.
#    This is the LAST manual TCC action; later updates re-sign automatically.

# 4. Verify:
scripts/mac/runner-node-resign.sh status     # expect: signed x2, agent loaded
gh workflow run ui-smoke.yml --ref main      # TCC preflight = the live probe
```

Caveats: there is a sub-minute window between an auto-update landing and the
agent re-signing + restarting — a tier-2 run in that window fails its TCC
preflight once and self-heals. If the `localvoxtral-dev` certificate is ever
rotated or deleted, all four grants die with it (redo step 3 after signing
with the new identity). Regression tests: `scripts/ci/test-runner-node-resign.sh`
(stubbed codesign/pgrep/svc.sh, runs in CI on every push).

## `localvoxtral-build-gate.sh` — SSH build gate (v4)

Forced command for the Linux dev box's build key on the Mac build host. It
allowlists the `remote-build.sh` loop (rsync in, `swift build|test`,
`package_app.sh release`), the v2 read-only diagnostic verbs `diag`,
`applog [minutes]`, `voxlog [lines]`, `svc-status`, and the on-demand
test-server verb `ensure <speechd|polishd|all>` (retired `voxmlx`/`mlxlm` names
accepted as aliases; touches a trigger file in the world-writable run dir and
polls the port until warm — see the on-demand section above). The `reap work/localvoxtral-<id>` recovery verb accepts one
validated work directory and terminates only stale test processes proven by
UID plus cwd/mapped-text evidence to belong to it. Everything else is denied
and logged to `~/Library/Logs/localvoxtral-build-gate.log`.

### v4: work-dir garbage collection (`gc`) and disk visibility (`disk`)

Every Linux worktree mints its own `~/work/localvoxtral-<slug>-<hash>` build
dir on the gate account (remote-build.sh derives the name from the local
checkout path so parallel agents never contend), and agent worktrees are
ephemeral — so multi-GB SwiftPM/xcodebuild trees used to accumulate until the
disk filled. v4 closes the loop:

- Every gated use of a work dir (mkdir, rsync, build/test payload) touches a
  `.lv-last-used` stamp at its root, so staleness never depends on
  rsync-preserved source mtimes. remote-build.sh protects the stamp from its
  `rsync --delete`.
- `gc` (no arguments) deletes any `work/localvoxtral-*` dir with no entry
  modified in the last `LV_GC_MAX_AGE_DAYS` days (default 14, overridable in
  `~/.localvoxtral-gate.conf`). Three keep-checks each fail toward "keep":
  recent activity (stamp or fresh build products), live processes rooted in
  the dir (lsof cwd/mapped-text evidence — same as `reap`), and
  `EvalRecordings/` presence, which downgrades deletion to a prune that
  preserves the recordings in place (private human WAVs may exist only in
  that remote copy).
- remote-build.sh fires `gc` automatically after every run, backgrounded and
  best-effort — the disk only fills while agents build, which is exactly when
  it runs. No cron/LaunchDaemon needed. A pre-v4 installed gate just denies
  the verb (a `DENY gc` line per run in the gate log until the upgrade).
- `disk` prints `df` plus per-work-dir `du` and last-used ages on demand;
  `diag` gained a cheap Disk section (df + ages, no du) whose
  `Data volume free: N GiB` line `mac-health.sh` parses to warn below
  `LV_MIN_FREE_GIB` (default 25).

Not covered by `gc` (occasional owner attention): the gate account's Hugging
Face cache accumulates a multi-GB snapshot per model pin ever tested — prune
retired pins by hand, but keep the current ones or the next integration run
re-downloads them — and `~/Library/Caches/localvoxtral-eval/wav` (TTS cache,
safe to delete any time, regenerates).

Allowed build payloads run in a dedicated process group. Whenever the payload
leader exits — including a SIGPIPE after its SSH output channel closes — the
gate sends TERM to any remaining group members, waits a bounded grace period,
then sends KILL. `remote-build.sh` also requests an explicit scoped reap when
the SSH payload fails. Both boundaries are one invocation/workdir: neither
uses a global `pkill`, so parallel worktrees and unrelated tests survive.

### Installing / upgrading the gate

Run from a trusted owner session on the Mac (not through the gate). With
`GATE_ACCOUNT` set to the dedicated low-privilege account whose
`authorized_keys` forces this script:

```bash
GATE_ACCOUNT=builder
cd ~/work/localvoxtral && git pull
sudo install -d -m 0755 -o "$GATE_ACCOUNT" "/Users/$GATE_ACCOUNT/bin"
sudo install -m 0755 -o "$GATE_ACCOUNT" \
  scripts/mac/localvoxtral-build-gate.sh \
  "/Users/$GATE_ACCOUNT/bin/localvoxtral-build-gate.sh"
sudo install -m 0755 -o "$GATE_ACCOUNT" \
  scripts/ci/cleanup-stale-test-processes.sh \
  "/Users/$GATE_ACCOUNT/bin/localvoxtral-cleanup-stale-test-processes.sh"
```

No `authorized_keys` change is needed — the entry already points at
`$HOME/bin/localvoxtral-build-gate.sh`; this replaces the script in place.
Upgrading the installed gate is required to gain interrupted-build teardown;
merging the repository copy alone does not change the forced command already
installed under the dedicated account.

### Machine-local config (`~/.localvoxtral-gate.conf` in the gate account)

The gate account is deliberately not the GUI owner account, so two things
differ per machine and are read from an optional, never-committed conf file:

```bash
# /Users/<gate-account>/.localvoxtral-gate.conf
VOXLOG_FILE=/Users/Shared/localvoxtral/speechd.log   # STT test-service log (was voxmlx.log)
VOXMLX_GUI_UID=501        # uid of the GUI user running com.localvoxtral.testspeechd
# LV_RUN_DIR=/Users/Shared/localvoxtral/run   # only if you moved the triggers
```

The `ensure` verb needs no `VOXMLX_GUI_UID` — it never calls `launchctl`, it
just touches a trigger file the owner-domain launchd watches, so the default
run dir works as-is once the owner has created it (mode 1777).

The `voxlog` verb tails the STT test-service log. The speechd plist template
above already writes `/Users/Shared/localvoxtral/speechd.log` (a shared
location), so across-account reads just work once `VOXLOG_FILE` points there.

(The alternative — ACL read grants on the owner's `~/Library/Logs` chain — is
fiddlier and breaks when the log file is rotated/recreated.)

### Verifying from the Linux box

```bash
./scripts/remote-build.sh diag        # versions, processes, ports, disk, logs
./scripts/remote-build.sh applog 30   # app unified log, last 30 minutes
./scripts/remote-build.sh voxlog 100  # speechd STT test-service log tail
./scripts/remote-build.sh svc-status  # speechd/polishd service/process/port status
./scripts/remote-build.sh disk        # df + per-work-dir du and last-used ages
./scripts/remote-build.sh gc          # reclaim stale work dirs now (also runs
                                      # automatically after every build/test)
ssh <gate-destination> 'ensure speechd' # warm the on-demand STT server
ssh <gate-destination> 'reap work/localvoxtral-<id>' # scoped stale-test cleanup
ssh <gate-destination> 'echo pwned'   # must print "denied command"
```

Notes:

- `applog` uses `log show`, which is restricted for non-admin accounts
  (confirmed on macOS 26: "Could not open local log store: Operation not
  permitted" for the gate account). The crashlog workflow
  (`mac-crashlog.yml`) runs as the runner user and is the fallback.
- `svc-status` includes process and port sections because `launchctl print`
  cannot read another user's GUI domain. Port checks are connect tests
  (`nc -z`) — `lsof` only sees the gate account's own sockets.
- Process listings deliberately print pid/user/executable only, never full
  command lines: other users' cmdlines can embed secrets (env assignments in
  remote-ssh invocations), and diag output flows into agent transcripts.

## `localvoxtral-ui-gate.sh` — SSH UI gate (v1)

A **second** forced-command gate, and the only one installed on the **GUI
account**. The build gate (`builder`) deliberately is not the console user, so
nothing routed through it can see or touch the desktop; this gate exists so an
agent can drive the localvoxtral build under test — and only that — without
being handed the owner's whole session.

It is not a computer-use harness. There is no coordinate input and no
full-screen capture anywhere in it:

| verb | what it does |
| --- | --- |
| `state` | JSON: lock state, idle seconds, AC/battery, the Accessibility + Screen Recording preflight, whether an app under test is running, which terminals this gate opened — and a `setup` section that says which verbs will work before you try them (below) |
| `launch [--dogfood] <artifact>` | launches a `.app` that is under an allowlisted root **and** has `CFBundleIdentifier com.localvoxtral.app`; records pid + start time + executable path; prints the pid. Refuses beside any running localvoxtral, including one this gate did not start |
| `shot [settings\|popover\|overlay\|window <n>]` | base64 PNG of ONE window, resolved from the window list filtered to that pid, refused if the resolved window's owner is anything else. stdout is pure base64; the `shot: window …` line is on **stderr**, so pipe straight into `base64 -d` — no `tail` |
| `ax dump [all\|settings\|overlay\|window <n>]` | the AX element tree of that pid's windows, as JSON |
| `ax click <selector>` | presses the one element the selector matches |
| `ax type <selector> -- <text>` | types into a text-bearing element |
| `key <escape\|tab\|return>` | one keycode from a three-entry allowlist; brings the app under test frontmost first and refuses if that did not take, so a keystroke never lands in whatever the owner last touched |
| `menu open` / `menu click <item-title>` / `menu dismiss` | drives the status item of the recorded pid. localvoxtral opens no window at launch, so this is what makes every row above it reachable. `open`/`dismiss` confirm the result against the window list — the same layer the `shot popover` row resolves — so they cannot report a menu that is not on screen |
| `dictate tap` / `dictate hold <seconds>` / `dictate cancel` | posts the app's OWN configured modifier trigger (read from its defaults) as a gesture at the HID tap — the only way to start a dictation, and therefore to exercise the Claude Code / herdr join |
| `app <control command>` | forwards ONE line to the **dogfood** control socket of the app under test and returns the reply. Five shapes only: `session start overlay\|live`, `session stop`, `join report`, `surface probe`, `registry list`. Refuses a build with no `LVXDogfoodCapture` stamp — see "`app` — asking the app what it joined" |
| `log [minutes]` | localvoxtral's own unified-log lines over a clamped window (default 15, max 120), line-capped and token-scrubbed. Predicate-scoped to `subsystem == "com.localvoxtral"` **and** to one process — the recorded pid, else the app's process name, which it says. Never a system-log reader. Read-only, so it works while the screen is locked |
| `gate-log [lines]` | the last N lines of this gate's OWN log (default 20, max 200) — where a denial's reason is written. Read-only, works while the screen is locked |
| `quit` | terminates the recorded pid |
| `term open <ghostty\|iterm\|terminal> <command> [args]` | opens a terminal window running an allowlisted command, resolved to an absolute path under `$HOME/bin` before anything opens. **The allowlist is empty by default** — see "What may go on `term open`'s allowlist" below |
| `term focus <id>` / `term close <id>` | acts on one window this gate opened, identified by the CGWindowID that appeared while it was opening one |

Selectors are `key<op>value` pairs joined by `,` — `=` exact, `~` contains,
`+` for a space, keys `role`/`title`/`desc`/`value`/`index`/`window`:

```
ax click role=AXButton,title=General
ax click role=AXButton,title~Text+Processing
ax type  role=AXTextField,title~Endpoint -- http://127.0.0.1:8471/v1
```

An ambiguous selector is refused rather than guessed at; add `index=<n>` to
pick among matches deliberately.

Everything else is denied, and **every** invocation — allowed or denied — is
logged with a timestamp to `~/Library/Logs/localvoxtral-ui-gate.log`. The one
thing never written there is `ax type`'s text (it is how an API key gets into
the Endpoints pane); the log keeps the selector and `-- <redacted>`.

Three refusals are load-bearing and are what the regression suite
(`scripts/ci/test-ui-gate.sh`, in ci.yml's shell-test step) exists to hold:

- **No shell verb.** No `eval`, no `bash -c`, no verb taking a free command
  line. `term open` is the single constrained exception: its first token must
  be in `LV_UI_TERM_COMMANDS` (empty by default), must not be on the permanent
  denylist the conf file cannot override, every token must survive the same
  metacharacter blocklist as any other argument, and the command is logged
  **in full**. The rule for that allowlist is below and is not negotiable.
- **Locked screen = hard refusal**, fail closed. The probe is shared with the
  ui-smoke lane (`scripts/ci/screen-lock-state.sh`); an undeterminable state
  denies here and runs there, on purpose.
- **Owner takeover rule.** Any verb that steals focus — `launch`, `ax click`,
  `ax type`, `key`, `term open`, `term focus` — speaks a warning, waits 3 s,
  then announces completion or failure (`LV_UI_WARN_SLEEP_SECONDS` in the conf
  file relaxes the wait; the default is the rule as stated). `state`, `shot`,
  `ax dump`, `quit` and `term close` do not warn: none of them takes the
  keyboard or raises a window in front of what the owner is doing.

### One-time install (owner GUI session on the Mac)

Run from a trusted owner session — **not** through either gate.

```bash
# 1. On the Linux dev box: a key used for nothing else.
ssh-keygen -t ed25519 -f ~/.ssh/localvoxtral-ui-gate -C localvoxtral-ui-gate

# 2. On the Mac, as the GUI (console) user:
cd ~/work/localvoxtral && git pull
install -d -m 0700 "$HOME/bin"
install -m 0755 scripts/mac/localvoxtral-ui-gate.sh "$HOME/bin/localvoxtral-ui-gate.sh"
install -m 0755 scripts/ci/screen-lock-state.sh "$HOME/bin/localvoxtral-screen-lock-state.sh"
install -d -m 0700 "$HOME/localvoxtral-ui-artifacts"  # where launchable .app bundles go

# 3. Force the command on that key ONLY (one line in ~/.ssh/authorized_keys).
#    `restrict` disables pty, agent/port/X11 forwarding and user rc files; the
#    command= is then the entire trust boundary.
cat >>"$HOME/.ssh/authorized_keys" <<'KEY'
restrict,command="/Users/<gui-user>/bin/localvoxtral-ui-gate.sh" ssh-ed25519 AAAA...<the key from step 1>... localvoxtral-ui-gate
KEY
chmod 600 "$HOME/.ssh/authorized_keys"
```

Leave `sshd_config`'s `AcceptEnv` at its default (`LANG`/`LC_*`). The gate's
test seams are ordinary environment variables; sshd fixing the environment is
what keeps a client from setting them.

Then the TCC grants, in System Settings > Privacy & Security. Both are
required, and both are granted to **sshd**, not to the gate script — press
Cmd-Shift-G in the "+" file picker and enter
`/usr/libexec/sshd-keygen-wrapper`:

- **Accessibility** — `ax dump/click/type` and `key` (AX API + CGEvent).
- **Screen Recording** — `shot` (`screencapture -l`). Without it the capture
  silently produces an empty or desktop-picture-only file.

**Be clear-eyed about what that means:** granting those to sshd grants them to
*everything* that arrives over SSH as this user, so the forced command is the
only boundary left. That is why this script has no shell verb, why `term
open`'s allowlist is short, and why it must stay that way.

The stricter alternative, and the documented next hardening step: keep the TCC
grants off sshd entirely by moving the GUI work into a small signed helper
binary run by a LaunchAgent in the Aqua session, with the gate reduced to
writing a request onto a queue the agent reads. Then sshd holds nothing, the
helper is what macOS keys the grants to, and a compromised SSH session can only
enqueue verbs the helper already implements. It also side-steps the open
question below about whether an SSH-hosted process can reach the GUI session at
all. It is more moving parts than a single reviewed script, so it is not what
v1 does.

### `state`'s `setup` section — which verbs will work, before you try one

Every refusal in this gate is deliberately uniform: `denied command`, exit 126,
nothing on stdout. That is right, and it was also the whole problem. Driving
the installed gate on 2026-08-30 hit `term open` refusing everything and `app`
denying, and the causes were three files that did not exist and one runtime
default that was off — each a one-line fix, and none of them distinguishable
from "the verb is broken" or "the gate is old".

So `state` reports setup:

```json
"setup": {
  "gate": {"revision": "f44a91a15001"},
  "lock_probe": {"installed": true},
  "gate_conf": {"present": true, "status": "ok"},
  "artifacts": [{"name": "localvoxtral-dogfood.app", "dogfood": true}],
  "term_open": {"terminals": ["ghostty", "iterm", "terminal"],
                "commands": ["lv-attach"], "refused_by_denylist": [],
                "unresolvable": []},
  "lv_attach": {"installed": true, "allowlisted": true, "conf": "ok",
                "destination": "builder", "session_default": true},
  "control_socket": {"present": false, "consent": "off"}
}
```

Reading it:

- `gate.revision` is the first 12 hex of the installed script's SHA-256.
  Compare with `shasum -a 256 scripts/mac/localvoxtral-ui-gate.sh` to settle
  "is the gate old", which used to be an unfalsifiable theory.
- `gate_conf.status` is `absent`, `ok` or `unparsable`. A conf with a syntax
  error used to take the **whole gate** down — `source` returns non-zero and
  `set -e` exits before anything prints. It now degrades to the built-in
  defaults, which are the closed ones, warns on stderr on every invocation,
  and shows up here.
- `term_open.commands` is exactly what `term open`'s first token is matched
  against. `[]` means every command is refused, which is the shipped default.
  `refused_by_denylist` names allowlisted entries the permanent denylist
  refuses anyway — a conf that reads as configured and behaves as not.
  `unresolvable` names allowlisted entries with no executable file behind
  them, which is the failure below, reported before a verb is tried.
- `lv_attach.conf` comes from `~/bin/lv-attach --check`, so it is the
  **installed** wrapper's own verdict rather than a second copy of its rules:
  `ok`, `missing`, `no-destination`, `invalid-destination`, `invalid-session`,
  `present-unchecked` (a config with no wrapper to validate it) or
  `wrapper-too-old`.
- `artifacts` lists what `launch` would accept, by name, with the dogfood slot
  marked. Anything that is not a validated localvoxtral bundle is not listed.
- `control_socket` is the two halves `app` needs: `consent` is
  `debug.dogfood_control_socket_enabled`, `present` is whether a socket is
  actually bound.

**What it reports and what it does not.** Presence, parse verdicts, and values
that are already this gate's own vocabulary — allowlisted command names,
terminal names, bundle names under a root the gate names in its own refusals.
Never a config file's contents. The one judgement call is the lv-attach
destination: a **bare alias** is echoed, because it is a label in the owner's
own `~/.ssh/config`, names no account and no address, and is the value that
catches the real failure ("this points at the wrong machine"). A `user@host`
destination is an account **and** an address, so its shape is reported and its
value is not — the same line `app`'s closed reply vocabulary draws.

### `gate-log` — reading why something was denied

The reason behind a `denied command` was always written to
`~/Library/Logs/localvoxtral-ui-gate.log`; what was missing is that no verb
could read it back, so an agent over SSH saw the generic line and had to go
through the owner to learn a one-line fix.

```bash
ssh lv-ui 'term open ghostty lv-attach'   # denied command
ssh lv-ui 'gate-log 5'
# 2026-08-30T14:39:37+0200 DENY term open ghostty lv-attach (term open has no
#   allowlisted commands (the default is empty — see scripts/mac/README.md))
```

**`deny` still does not explain itself, and that is the point.** A gate that
answered each refusal with its reason would be an oracle for state the caller
cannot otherwise see — whether a path exists, whether a bundle validated,
whether a pid is running, which names a conf allowlists. The fix for an
invisible reason is a bounded reader, not a chattier refusal.

What `gate-log` can disclose is exactly what this gate wrote about itself: one
sanitised, printable, 512-byte-capped line per invocation, with `ax type`'s
text already replaced by `<redacted>` **at write time**, so reading the log
back cannot resurrect an API key. Output goes through the same 43-character
base64url scrub `log` uses. It logs its own invocation before reading and drops
that line from the answer, so `gate-log 1` means "the entry before this one".
It is read-only and focus-free, so like `log` it works while the screen is
locked.

### `menu` — the verb that makes every other verb reachable

localvoxtral is a menu bar app and opens **no window at launch**. Straight
after `launch`, `ax dump all` returns `[]`, `shot settings` reports no window,
and `ax click` matches nothing — all correct, and all useless. `menu open`
clicks the status item; the menu it opens is what `shot popover` photographs,
and `menu click Settings` is what produces the Settings window every other verb
then addresses.

Item titles are matched by containment, with an exact title winning and
ambiguity refused — because a real title (`Settings…`) contains characters the
gate's token charset cannot carry, so `menu click Settings` is the way in. A
space is spelled `+`, as in selector values: `menu click Show+Log`.

`menu dismiss` closes the menu through the app's own AX cancel action rather
than a synthesised Escape, so no keystroke is ever posted at whatever owns the
keyboard. It takes nothing from the owner and therefore does not warn.

**How `open` and `dismiss` know a menu is on screen — and why it is not the
obvious test.** An `NSMenu` handed to an `NSStatusItem` hangs off that item as
an `AXMenu` child for the app's whole life, displayed or not. Taking that
attachment for "the menu is open" is what the first cut did, and it made
`menu open` a no-op that returned `ok already-open` instantly while nothing
appeared, `shot popover` then found nothing, and `ax dump all` stayed `[]`
(field check 2026-08-29). Both verbs now ask the **window list** instead: a
window owned by the recorded pid at layer ≥ 100, which is the very same rule
`shot popover` resolves with. So `menu open` succeeds exactly when
`shot popover` can photograph something, by construction, and a press that
produced nothing is a failure that says so. `menu dismiss` gains a second
property from the same test: with nothing on screen it returns
`ok no-menu-open` **without touching the status item**, where before it could
fall through to a press — and a press on a closed menu opens one.

`menu click` deliberately does *not* require a displayed menu: `AXPress` on a
menu item works either way, which is how the gate reached Settings while
`menu open` was broken. Keep it that way — it is the fallback when the window
test cannot see a menu that is genuinely up.

The mechanism is the Accessibility API (`AXExtrasMenuBar` on the recorded pid),
not System Events: an Apple event would need a separate Automation grant whose
consent sheet cannot be answered over SSH, while Accessibility is a grant sshd
already holds.

### `dictate` — the only verb that can start a session

The gate exists to debug the Claude Code / herdr join, and that join resolves
when a dictation **starts**. `key`'s allowlist is `escape|tab|return` and the
app's trigger is a modifier-only gesture, so nothing else here can start one.

`dictate` posts the app's own configured trigger — read out of
`com.localvoxtral.app`'s defaults each invocation, never hard-coded — as a
`flagsChanged` event at the HID tap. That is the same path
`scripts/record-demo.sh` has driven on this machine since the demo recording;
the app detects the gesture with an `NSEvent` monitor and filters nothing, so
this is the real gesture, not a side door. A plain `keyDown` would do nothing:
the event's type has to be `flagsChanged` and carry the modifier's flag mask.

- `dictate tap` → Overlay Buffer session (a second tap stops it)
- `dictate hold <seconds>` → Live Auto-Paste push-to-talk, held for that long.
  Must exceed the app's own `settings.modifier_only_hold_delay`, else it is a
  tap wearing a hold's name; capped at `LV_UI_MAX_HOLD_SECONDS` (30).
- `dictate cancel` → Escape, which the app consumes system-wide for the
  duration of a session.

It refuses when the app is not running, when the screen is locked, when the
trigger settings cannot be read (**it will not guess which key to press**),
when the modifier-only trigger is disabled in the app's settings, and when
Secure Keyboard Entry is held — that last one because the events would be
silently discarded, which is the worst failure shape to debug. `tap`/`hold`
take the audible warning; `cancel` does not.

**It does not bring localvoxtral frontmost, on purpose.** The trigger is global
by design and the dictation grounds its context in whatever *is* focused — a
terminal running Claude Code. Activating localvoxtral first would make every
session resolve against the wrong surface, which is the thing under test. The
result line names the frontmost app instead, so you know where it landed.

Reading the outcome: `ax dump overlay` after a `dictate tap`. The overlay's
Claude-join badge is a real AX element with an explicit label —
`Grounded in Claude Code session <workspace>`, or
`No Claude Code session joined for this dictation`. Two caveats: the badge only
appears when terminal-screen or repo context is enabled, and **only Overlay
Buffer sessions open an overlay at all** — `dictate hold` (Live Auto-Paste)
never shows one, so `tap` is the oracle.

### `app` — asking the app what it joined

`dictate` can start a session; it cannot tell you what the session **joined**.
Two things about that are invisible from outside the app's process: a dictation
has no deterministic trigger (which is what `dictate` works around, at the cost
of synthesising a gesture), and `ClaudeSessionRegistry` is in-memory and
per-process — so `localvoxtral --probe-surface`, a separate one-shot process,
always resolves against an **empty registry** and can never report a real join
arm.

A dogfood build answers both, over a local AF_UNIX socket it binds only when
`debug.dogfood_control_socket_enabled` is armed
(`docs/dogfood-builds.md`). `app` forwards one line to it:

```bash
ssh lv-ui 'app registry list'         # is the registry empty, or the surface unidentified?
ssh lv-ui 'app surface probe'         # resolve the FOCUSED surface now, live registry
ssh lv-ui 'app session start overlay' # a real dictation, through the app's own tap handler
ssh lv-ui 'app session stop'
ssh lv-ui 'app join report'           # what the last dictation actually joined
```

`registry list` is the one to reach for first: an empty registry and a surface
the resolver could not identify produce the same silence, and that ambiguity is
the most common dead end in this area.

What bounds the verb:

- **The socket path is fixed**, not an argument. No shape of this verb points
  it at another socket on the machine.
- **Dogfood only.** A shipped build compiles no socket at all, so the verb
  refuses unless `launch --dogfood` recorded a stamped bundle — one clear line
  instead of a connect that never answers.
- **Five shapes, allowlisted in the gate.** A verb added to the app's socket is
  not automatically reachable through an already-installed gate.
- **Lock policy is per command.** `session start` takes the keyboard, so it is
  refused on a locked screen and speaks the takeover warning like `dictate`.
  `surface probe` reads the *focused* surface, and behind a lock screen that is
  not the surface you are asking about, so it is refused too. `session stop`,
  `join report` and `registry list` are in-process reads (or a give-back) and
  work while locked.
- **A started session is capped** by the app itself, so an SSH command that
  dies mid-dictation cannot leave it recording.
- **The socket's runtime consent is a SECOND grant, and stays one.** A dogfood
  build writes capture records when `debug.dogfood_capture_enabled` is armed
  (which `launch --dogfood` does); it binds the control socket only when
  `debug.dogfood_control_socket_enabled` is armed as well, and nothing arms
  that for you — not `try-pr.sh --ui-gate`, not the CI install step. The split
  is deliberate: "records what I do" and "accepts commands on a local socket
  **any** process on this Mac can connect to" are different permissions, and
  this machine is also the self-hosted CI runner. `state` reports
  `setup.control_socket.consent`, and the refusal names the fix:

  ```bash
  defaults write com.localvoxtral.app debug.dogfood_control_socket_enabled -bool true
  ```
- The reply is a closed vocabulary of bools, counts and enum names — no
  workspace, marker, tty, pane id, host or session id ever crosses.

### `log` — the app's own lines, and nothing else

Join abstentions are diagnosed from `Log.claudeContext`, and without them the
answer is one category word.

```bash
ssh lv-ui 'log'        # the last 15 minutes
ssh lv-ui 'log 60'     # clamped 1..120
```

Predicate-scoped to `subsystem == "com.localvoxtral"`. It is deliberately not a
general system-log reader: this is the owner's personal machine, and every
other application's activity stays out of reach. Output is capped at 400 lines
(the drop is announced, never silent) and passed through the same 43-character
base64url scrub the dogfood records use — the app writes its categories
`privacy: .public` on purpose, but "every line anyone ever adds is safe" is not
an assumption worth depending on.

**The subsystem alone is not enough on this machine, and that was a real
finding.** This Mac is also the self-hosted CI runner, and a unit-suite run
logs under localvoxtral's own subsystem from `xctest`. Field check 2026-08-30:
`log 2` returned 111 lines of which exactly one came from the app under test;
the rest were a concurrent CI run, including
`Terminal pane joined to a live Claude session via title marker`. Attributing
that to the dictation you just made is a wrong conclusion drawn from a real log
line, which is the worst thing this verb could do. So the predicate carries a
process as well:

- with an app under test, `processIdentifier == <the pid launch recorded>` —
  one instance, scoped exactly like every other verb in the gate;
- with none, `process == "localvoxtral"`, which still excludes `xctest` but no
  longer excludes a second instance or a `--probe-surface` one-shot. The verb
  says so on **stderr, before the lines**, so the caveat is read before the
  conclusion.

Even correctly scoped, a build running on the runner is writing to the same log
store at the same time, so timestamps interleave with CI's noise in the
surrounding system log — the predicate keeps the *lines* clean, not the
neighbourhood. `state` and the gate's own log tell you which pid is which.

It steals no focus and writes nothing, so unlike the actuation verbs it is
allowed while the screen is locked.

**Caveat, and it is not yet resolved.** `log show` is restricted for
**non-admin** accounts — the build gate's account hits exactly that, and this
file records it a few sections down ("Could not open local log store: Operation
not permitted"). The UI gate runs as the GUI user, a different and *admin*
account, so it is expected to work here; that has **not** been verified on this
machine as of 2026-08-30. The verb is built so the difference is impossible to
miss: a restricted store exits non-zero and quotes the reason rather than
returning an empty page, and an empty window says "no com.localvoxtral entries
for <scope> in the last N minute(s)" on stderr. If it does turn out to be
restricted for the GUI account too, there is no flag that lifts it — the
alternatives are `mac-crashlog.yml` on the runner (which already ships a
subsystem-filtered log) or having the app write its own file.

### Getting a build into the artifact root

`launch` only accepts bundles under `LV_UI_ARTIFACT_ROOTS`, and those roots
must stay writable by the owner alone: inside one, a bundle claiming
`com.localvoxtral.app` is trusted, so a world-writable root would let any local
process plant one and have the gate start it as the GUI user. `try-pr.sh`
extracts to `/tmp`, which is exactly such a directory — so the bundle moves,
never the roots.

```bash
# On the Mac's GUI account. Fetches the CI artifact and installs it; does NOT
# launch it, because launching is the gate's job.
./scripts/try-pr.sh 238 --ui-gate
./scripts/try-pr.sh main --dogfood --ui-gate     # instrumented build

# A locally packaged bundle, same destination:
./scripts/mac/install-ui-artifact.sh dist/localvoxtral.app
```

**An agent driving the gate has no shell on that account and no verb that runs
`try-pr.sh`, so CI does the install instead.** The self-hosted runner is a
launchd agent inside the owner's GUI session — its `$HOME` is the GUI
account's home, which is where the artifact root lives — so a
`workflow_dispatch` of `ci.yml` with `dogfood=true` builds *and* installs:

```bash
gh workflow run CI --ref <branch> -f dogfood=true
# the run summary then carries the exact:  ssh lv-ui 'launch --dogfood …'
```

That step is gated to `workflow_dispatch` **and** `dogfood=true` — narrower
than the dogfood lane itself, whose `[dogfood-package]` marker fires on
ordinary PR pushes, none of which should write into the owner's home. If the
target slot is running the step warns and skips rather than failing the build
(exit 3 from the installer); every other install failure is red.

Two slots, replaced in place: `localvoxtral.app` and (for a
`LVXDogfoodCapture`-stamped build) `localvoxtral-dogfood.app`. Keeping one copy
per build would be worse than useless — they share a bundle id, a defaults
domain and a TCC grant, so a stale one is indistinguishable at runtime, which
is the wrong-binary confusion `docs/agent/field-debugging.md` is about. What
each slot currently holds is in `<bundle>.app.source` next to it.

The installer refuses a root it cannot write, a root that is group- or
other-writable, a bundle that is not a validated localvoxtral app, and any
overwrite of a bundle that is **currently running** from that slot. It does not
quit anything: `quit` is a gate verb, and only the operator knows whether a
dictation is in flight. Do quit the running app before `launch` — a second
instance fights the first for the global hotkey and for the speechd/polishd
ports 8471/8472.

### Machine-local config (`~/.localvoxtral-ui-gate.conf`, GUI account)

Never committed; same trust argument as the build gate's conf (anyone who can
write it can already replace the gate script).

```bash
# LV_UI_ARTIFACT_ROOTS="$HOME/localvoxtral-ui-artifacts"  # where launch may look
# LV_UI_TERM_COMMANDS="lv-attach"       # term open's first tokens; EMPTY by default
# LV_UI_TERM_COMMAND_DIRS="$HOME/bin"   # where an allowlisted name is resolved
# LV_UI_TERMINALS="ghostty iterm terminal"
# LV_UI_WARN_SLEEP_SECONDS=3                              # 0 only if you are sitting there
# LV_UI_SHOT_MAX_BYTES=8388608
```

**No installer writes this file, and none ever should.** `LV_UI_TERM_COMMANDS`
is the gate's allowlist — the same object as the gate script, one layer up. The
rule that CI must not write the gate script applies for exactly the same reason
to what the gate will accept: an empty default exists to force a deliberate
grant, and a grant that arrives with a build is not one. So the one manual step
is an **append**, which cannot clobber a file that already exists and wins over
any earlier assignment when the file is sourced:

```bash
printf 'LV_UI_TERM_COMMANDS="lv-attach"\n' >> ~/.localvoxtral-ui-gate.conf
```

`ui-gate-doctor.sh` prints that exact line when the allowlist is empty, and
`state`'s `setup.term_open.commands` shows the result. A syntax error in this
file no longer breaks the gate: it is ignored, every setting falls back to its
built-in (closed) default, and `state` reports `"gate_conf":{"status":
"unparsable"}`.

### What may go on `term open`'s allowlist

**An allowlisted command must not be able to run a child command.** Not "must
not be a shell" — must not be able to *start* one, at any remove, through any
flag or subcommand. `list_contains` matches the **first token only** and
nothing inspects flags, so a name on this list is trusted with every argument
it will ever be given.

The test to apply before adding a name: read its `--help`. If any flag or
subcommand takes a command, a script, a prompt, or a file to execute — `-c`,
`-e`, `exec`, `run`, `--eval`, `-p`, an agent that runs tools — it fails.

**That test is necessary and not sufficient, and the gap is the likely
mistake.** An editor or a pager reaches a shell at *runtime*, not through a
flag: `vi` and `vim` have `:!cmd`, `less` and `man` have `!cmd` and `v` (which
opens `$EDITOR`), `awk` has `system()`, `git` runs your editor and your hooks.
Every one of them passes a `--help` reading, and "I just want a viewer in that
window" is exactly the reasoning that allowlists one. So does the wrapper class
whose *normal* argv is somebody else's command — `nice`, `watch`, `timeout`,
`env`, `xargs`, `open` (`open -a Terminal`), `npx`, `cargo`, `go` — and the
fetchers that bring code to run, `curl` and `wget`. All of these are on the
permanent denylist for that reason; if you find yourself wanting one, you want
a wrapper instead.

That rejects the obvious shells and **every coding-agent CLI**. `claude
--dangerously-skip-permissions -p <prompt>`, `codex exec`, `opencode run` and
`herdr agent start` each execute arbitrary code as the GUI user, and none of
them needs a space or a metacharacter to do it. An earlier revision of the gate
shipped `herdr claude opencode codex` as the default allowlist; that was a
fully-permissioned remote shell wearing four allowlisted names, and it is why
the default is now empty and why `LV_UI_TERM_FORBIDDEN` — a permanent denylist
assigned *after* the conf file is sourced — refuses those names even if this
conf allowlists them.

The way to make the verb useful is a **single-purpose wrapper**, which takes
an identifier and execs one fixed command. That wrapper ships in this repo —
`scripts/mac/lv-attach.sh` — precisely because it is the thing holding the
boundary, and an unreviewed shell script written once into `~/bin` is the
weakest possible place for that. `install-ui-artifact.sh` puts it at
`~/bin/lv-attach` (mode 0700) with every build, so it arrives reviewed and
stays current.

Allowlist it — append, so the line cannot clobber an existing conf:

```bash
printf 'LV_UI_TERM_COMMANDS="lv-attach"\n' >> ~/.localvoxtral-ui-gate.conf
```

and tell it where to go — the destination is deliberately **not** an argument:

```bash
# ~/.lv-attach.conf   (install-ui-artifact.sh writes this as a commented
#                      template if it does not exist, and never overwrites it)
destination=builder      # an ssh alias, or user@host
session=work             # optional default herdr session
```

`~/bin/lv-attach --check` answers whether that resolves, and it is the same
answer `state` reports under `setup.lv_attach` — the gate asks the installed
wrapper rather than re-reading the file, so the destination validator has one
implementation and not two.

Then `ssh lv-ui 'term open ghostty lv-attach work'`.

**Why the wrapper's config is templated by the installer and the gate's
allowlist is not.** A destination is ordinary configuration; the only cost of
getting it wrong is a terminal that opens onto the wrong machine, and "what is
this file called and what goes in it" was itself a round trip through the
owner. The allowlist is the boundary. So the installer writes an
`~/.lv-attach.conf` with **no active destination** (it cannot know which
machine you mean) and never touches `~/.localvoxtral-ui-gate.conf`.

**Allowlisting `lv-attach` is safe precisely because it cannot take a command,
which is the property `ssh` lacks.** `ssh <host> <anything>` runs that
anything; that is why `ssh` is on the permanent denylist and why allowlisting
it would hand the whole boundary away. `lv-attach` takes at most ONE argument,
a herdr session name matched against `^[A-Za-z0-9._-]{1,64}$` and refused if it
starts with `-`; it takes no flags, no second positional and no command; it
*reads* its config with `sed` rather than sourcing it; and it ends in one of
exactly two fixed `exec ssh -t -- <destination> herdr [--session <name>]`
lines. `test-ui-gate.sh` section 23 proves the refusals, tries injection
through the identifier, and pins that the file contains no `eval`, no
`bash -c`/`sh -c`, no `source`, and no `"$@"` in a command position.

It opens a **whole-view** herdr client rather than `herdr terminal attach
<pane>` on purpose: the app's `HerdrInvocation` classifier refuses every herdr
shape except a bare `herdr` or `herdr --session <name>`
(`docs/agent/invariants.md`), so a pane-attach wrapper would reliably open a
window the app deliberately never joins — useless for the exact debugging
`term open` exists for. Pick the pane inside herdr, after attaching.

If you write your own wrapper instead, review it with the same eyes as the
gate itself, and never let it take a command from its argument.

**Where the agent runs.** For terminal/agent-integration scenarios the agent
(Claude Code, codex, …) is started on the **fixture side** — the Linux host
running herdr, driven by the herdr-integration harness — and the Mac's
`term open` only ever attaches to it, as `lv-attach` above does. The Mac gate
never launches an agent, so the "allowlist a coding-agent CLI" pressure that
produced the original hole does not exist.

### `term open` — what it runs, and how it finds the window it opened

Both halves of this were wrong on 2026-08-30, and between them they told the
operator a story that was false in every particular.

**The command is resolved to an absolute path before anything opens.** The
launcher used to say `exec lv-attach` and let PATH find it. A script started by
`open -n -a Ghostty --args -e <script>` gets no login-shell environment, and
`$HOME/bin` — where `install-ui-artifact.sh` puts the wrapper — is on neither
that PATH nor sshd's. So the launcher hit `command not found`, exited
instantly, and left an **empty** Ghostty window. `term open` now resolves the
allowlisted name against `LV_UI_TERM_COMMAND_DIRS` (default `$HOME/bin`),
requires a file that exists and is executable, and refuses **with nothing
opened** when there is none. The directory list stays short on purpose: a name
resolved out of a directory other accounts can write is the allowlist handed
away. `state`'s `setup.term_open.unresolvable` reports the same thing without
opening anything at all.

**The window is identified by a CGWindowID diff, not a title marker.** The
launcher printed an OSC 0 title carrying a random marker and the gate polled
for a window with it. That cannot work for the one command this verb exists to
run: `lv-attach` execs a whole-view herdr client, and herdr owns the title from
the moment it starts — `docs/agent/invariants.md` says a title marker "can
neither reach nor come back from a herdr-hosted session", which is why the
app's own `titleMarker` join arm is suppressed there. So `term open` snapshots
the terminal application's window ids **before** `open`, then binds the window
that is new since that snapshot; nothing the command does to its title can hide
it. The marker survives only as a tie-breaker for commands that leave the title
alone. `term focus`/`term close` then address that window id, mapped to an AX
window by frame (AX exposes no window id without private API).

**Three faults, three messages.** "No window" used to mean all of these at
once, and reporting the second as the third is what produced a confidently
wrong root cause. The launcher writes its pid before `exec`, which separates
them:

| what the pid file says | what happened | what to do |
| --- | --- | --- |
| absent | the terminal never ran the launcher | the command was never executed; this is not a window problem |
| present, process gone | the command ran and exited immediately — an empty window is exactly what that looks like | run `~/bin/<command> <args>` by hand as the GUI user and read its error |
| present, process alive | the command is running; only the window could not be identified | re-run without opening a terminal window yourself at the same moment |

**A failed `term open` leaves nothing behind.** If it cannot confirm which
window it opened, it kills the process it started (that pid file is the only
handle once the window is unaddressable), removes the launcher, and registers
no terminal. In Ghostty the window closes with the command; in Terminal/iTerm
it stays showing a finished command. Several windows appearing at the same
moment is refused rather than guessed at — binding the wrong one would point
`term close` at whatever the owner just opened.

**Why `term open` is not a way around the app-scoped verbs.** `shot`,
`ax dump`, `ax click`, `ax type` and `key` all take their pid from the
`app.state` that `launch` wrote, and `launch` only ever records a validated
localvoxtral bundle's pid. No verb retargets them at a terminal.
`term focus`/`term close` do reach a terminal window, but only to raise or
close it — they carry no selector, no keystroke and no capture, so nothing this
gate types can reach a shell prompt. `test-ui-gate.sh` section 12 pins this
with both an app under test and an open terminal recorded.

### Verifying from the Linux box

```bash
./scripts/mac/ui-gate-doctor.sh --remote lv-ui   # every readiness item, ticked
                                        # or with the one command that fixes it
ssh lv-ui 'state'                       # the same facts as JSON
ssh lv-ui 'gate-log 20'                 # why the last thing was denied
ssh lv-ui 'launch localvoxtral-ui-artifacts/localvoxtral.app'
ssh lv-ui 'menu open'                   # localvoxtral has NO window until this
ssh lv-ui 'shot popover' | base64 -d > /tmp/popover.png
                                        # stdout is pure base64; the
                                        # "shot: window …" line is on stderr
ssh lv-ui 'menu click Settings'         # substring: the real title is Settings…
ssh lv-ui 'shot settings' | base64 -d > /tmp/settings.png
ssh lv-ui 'dictate tap'                 # starts an Overlay Buffer session
ssh lv-ui 'ax dump overlay'             # the Claude-join badge names the session
ssh lv-ui 'log 5'                       # the app-under-test pid's own lines
                                        # (subsystem alone also matches CI's
                                        # xctest runs on this same machine)
ssh lv-ui 'app registry list'           # dogfood build only; refused otherwise
ssh lv-ui 'app surface probe'           # resolve the focused surface, live registry
ssh lv-ui 'app rm -rf /'                # must print "denied command"
ssh lv-ui 'ax dump settings' | python3 -m json.tool | head
ssh lv-ui 'ax click role=AXButton,title=Dictation'
ssh lv-ui 'quit'
ssh lv-ui 'echo pwned'                  # must print "denied command"
ssh lv-ui 'bash -lc id'                 # must print "denied command"
ssh lv-ui 'term open ghostty bash -c id' # must print "denied command"
ssh lv-ui 'term open ghostty claude --dangerously-skip-permissions -p hi'
                                        # must print "denied command" — the
                                        # agent CLIs are permanently refused
```

Every one of those, allowed or denied, appends a line to
`~/Library/Logs/localvoxtral-ui-gate.log` — read it after the first session.

### First install: run the doctor, then the checks no script can make

```bash
# On the Mac's GUI account, from the checkout:
./scripts/mac/ui-gate-doctor.sh

# From the Linux dev box, against the installed gate:
./scripts/mac/ui-gate-doctor.sh --remote lv-ui
```

Every line is either `ok` or `FIX` followed by one copy-pasteable command; it
exits 0 when nothing needs attention, 1 when something does, 2 when the gate
could not be reached at all. It covers the gate script's revision (and, locally,
whether the installed copy matches this checkout), the forced-command line, the
lock probe, both TCC grants as the gate's own preflight saw them, the gate conf
and what `term open` would accept, whether `lv-attach` is installed, allowlisted
and pointed somewhere, what `launch` would accept, and the dogfood control
socket's two consents. Run it again after each fix.

The prose list this replaces is gone on purpose: it was seven numbered items
the owner read and mis-followed, and every one of them that a script *can*
check is now checked.

**What no script can check**, and what still has to be done by hand on the
first install — the doctor prints this list too:

0. `log` returns lines rather than failing. If it prints "Could not open local
   log store: Operation not permitted", the unified log is restricted for this
   account too and the verb is dead — say so rather than working around it; see
   the caveat under "`log` — the app's own lines".
1. `state` reports `"screen_lock":"unlocked"` while you are logged in, and
   `"locked"` after you lock the screen — this is the ONE probe standing
   between the gate and a locked machine. It has two arms; over SSH the
   IORegistry arm is the one that has to answer, and it has not been run
   against a real `ioreg` yet.
2. `tcc.accessibility` and `tcc.screen_recording` are true **in a session that
   arrived over SSH**. The doctor reports what the gate's preflight saw, which
   is the right answer only if you ran it through `--remote`; a local run
   reports a local process's grants. If they are false after granting sshd, the
   sshd-holds-the-grants design does not work on this macOS version and the
   LaunchAgent alternative above is the fix — do not work around it by
   loosening the gate.
3. `shot settings` returns a PNG of the Settings window and not a black or
   empty image (a black capture means the Screen Recording grant is not
   reaching the SSH session), `ax click` presses the right control, and `key`
   works — it calls `NSRunningApplication.activate` and re-checks
   `frontmostApplication`, both AppKit calls made from a short-lived
   SSH-hosted process with no run loop, which is exactly where they are least
   likely to behave. "Could not be brought frontmost" is that symptom.
4. `menu open` prints `ok window=<n>`, `shot popover` returns a PNG of that same
   menu, and `menu dismiss` prints `ok`. The shell suite stubs the helper, so
   what it pins is that the decision is made from the window list, never that
   macOS puts a status menu there. If `menu open` says the status item was
   pressed but no window appeared at layer >= 100, check with `menu click
   Settings` (which works either way) and say which — do not go back to
   trusting the attached `AXMenu`.
5. `term open ghostty lv-attach` opens a window that actually reaches the
   configured host, `term focus`/`term close` find it, and a failed one leaves
   nothing behind. The gate now distinguishes "the command never ran", "the
   command exited immediately" and "the window could not be identified"; what
   it cannot tell you is whether the herdr client on the far end attached to
   the session you meant. Confirm that from the remote host (`last` shows a new
   pty login from the `-t` ssh).
6. `log` returns only the app under test. Start a build on the runner, then run
   `log 2` and confirm no `xctest[` line comes back. Without `launch`, the same
   command warns on stderr that it is not pid-scoped.
