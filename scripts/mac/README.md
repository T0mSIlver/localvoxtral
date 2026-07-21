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

## On-demand test servers (voxmlx + mlxlm) — owner runbook

The two build-host model servers used by the integration/eval suites —
`com.localvoxtral.voxmlx` (port 8000, tier-1 realtime STT) and
`com.localvoxtral.mlxlm` (port 8080, LLM polish eval) — used to run
`RunAtLoad`/`KeepAlive` always-on, keeping multi-GB weights resident 24/7.
They are now **launch-on-demand with an idle reaper** so that RAM is only
spent around actual test runs. This is hands-free for both CI and
`remote-build.sh` — nobody has to remember to start/stop anything.

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
- **Manual unload:** `lv-test-servers.sh stop [voxmlx|mlxlm|all]` frees the
  weights NOW without waiting for the idle window — same stop path as reap
  (trigger removed, `SIGTERM`→`SIGKILL`, blocks until the port closes). Default
  target is `all`.
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

# 2. mlxlm venv with the pinned fork wheel. Since the bundled MLX Swift helper
#    replaced the app-managed mlx-lm wheel (2026-07), the app no longer
#    installs mlx-lm — this pin exists only for the eval reference endpoint.
uv venv --python 3.12 ~/.local/share/localvoxtral-eval/mlx-lm
uv pip install --python ~/.local/share/localvoxtral-eval/mlx-lm/bin/python \
  'mlx-lm @ https://github.com/T0mSIlver/mlx-lm/releases/download/v0.31.3.post4/mlx_lm-0.31.3.post4-py3-none-any.whl'
```

> This mlxlm service is the *prompt-eval reference endpoint* for
> `LLMPolishPromptEvalTests` / `remote-build.sh eval-llm` — the app itself no
> longer installs or runs mlx-lm; production-engine parity is covered by
> `./scripts/remote-build.sh integration-polishd` instead, and the
> `--prompt-cache-*` flags below are mlx-lm-specific and don't mirror app
> behavior. Don't point evals at the app-managed server on 8472 — it only
> exists while the app is running with polishing enabled, so it vanishes
> whenever the app quits.

### mlxlm LaunchAgent (on-demand)

```bash
cat > ~/Library/LaunchAgents/com.localvoxtral.mlxlm.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.localvoxtral.mlxlm</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/REPLACE_ME/.local/share/localvoxtral-eval/mlx-lm/bin/mlx_lm.server</string>
    <string>--model</string><string>mlx-community/Qwen3.5-0.8B-8bit</string>
    <string>--host</string><string>127.0.0.1</string>
    <string>--port</string><string>8080</string>
    <string>--prompt-cache-size</string><string>1</string>
    <string>--prompt-cache-bytes</string><string>1GB</string>
  </array>
  <!-- On-demand: launchd starts this while the trigger file exists and stops
       it (freeing the weights) when lv-test-servers.sh reap removes it. -->
  <key>RunAtLoad</key><false/>
  <key>KeepAlive</key>
  <dict>
    <key>PathState</key>
    <dict><key>/Users/Shared/localvoxtral/run/mlxlm.want</key><true/></dict>
  </dict>
  <key>StandardOutPath</key><string>/Users/Shared/localvoxtral/mlxlm.log</string>
  <key>StandardErrorPath</key><string>/Users/Shared/localvoxtral/mlxlm.log</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.localvoxtral.mlxlm.plist
```

### voxmlx LaunchAgent — convert existing to on-demand

The voxmlx agent already exists (`com.localvoxtral.voxmlx`, port 8000, its
`StandardOutPath` pointed at `/Users/Shared/localvoxtral/voxmlx.log` for the
gate — see below). To make it on-demand, edit its plist to **replace**
`<key>RunAtLoad</key><true/>` and `<key>KeepAlive</key><true/>` with:

```xml
  <key>RunAtLoad</key><false/>
  <key>KeepAlive</key>
  <dict>
    <key>PathState</key>
    <dict><key>/Users/Shared/localvoxtral/run/voxmlx.want</key><true/></dict>
  </dict>
```

then re-bootstrap it:

```bash
launchctl bootout "gui/$(id -u)/com.localvoxtral.voxmlx" || true
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.localvoxtral.voxmlx.plist
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
`EnvironmentVariables` dict with `LV_TEST_SERVER_IDLE_SECONDS`.)

### Verify (owner-side proof)

```bash
scripts/mac/lv-test-servers.sh status                 # both: trigger absent, down
scripts/mac/lv-test-servers.sh ensure voxmlx          # cold-starts, blocks to warm
scripts/mac/lv-test-servers.sh status                 # voxmlx: trigger present, up
# Warm reuse: a second ensure returns instantly ("already warm") and resets idle.
scripts/mac/lv-test-servers.sh ensure voxmlx
# Idle reap: age the trigger AND the stamps past the window, then reap (or just
# wait for the reaper agent), and confirm launchd stopped the server / freed
# RAM. Age both — reap keys off the NEWEST of the trigger + stamps, so a
# freshly cold-started trigger (recent mtime) would otherwise keep it "warm".
# reap BLOCKS until the port actually closes (SIGTERM drains the MLX server in
# ~2-3s; it escalates to SIGKILL after STOP_GRACE), so the status right after
# reflects the real state — no need to sleep.
touch -t 202001010000 /Users/Shared/localvoxtral/run/voxmlx.*   # .want + .seen.*
scripts/mac/lv-test-servers.sh reap                   # removes trigger + stamps, TERM→KILL
scripts/mac/lv-test-servers.sh status                 # voxmlx: absent, down
```

If the SSH build gate is installed, `remote-build.sh integration|eval-llm|eval-e2e`
warm the right server through the gate's `ensure` verb automatically; CI warms
voxmlx in its own step before the integration suite (and `eval-e2e.yml` before
the nightly agent-dictation eval). The
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

## `localvoxtral-build-gate.sh` — SSH build gate (v4)

Forced command for the Linux dev box's build key on the Mac build host. It
allowlists the `remote-build.sh` loop (rsync in, `swift build|test`,
`package_app.sh release`), the v2 read-only diagnostic verbs `diag`,
`applog [minutes]`, `voxlog [lines]`, `svc-status`, and the on-demand
test-server verb `ensure <voxmlx|mlxlm|all>` (touches a trigger file in the
world-writable run dir and polls the port until warm — see the on-demand
section above). The `reap work/localvoxtral-<id>` recovery verb accepts one
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
VOXLOG_FILE=/Users/Shared/localvoxtral/voxmlx.log
VOXMLX_GUI_UID=501        # uid of the GUI user running com.localvoxtral.voxmlx
# LV_RUN_DIR=/Users/Shared/localvoxtral/run   # only if you moved the triggers
```

The `ensure` verb needs no `VOXMLX_GUI_UID` — it never calls `launchctl`, it
just touches a trigger file the owner-domain launchd watches, so the default
run dir works as-is once the owner has created it (mode 1777).

For `voxlog` to work across accounts, point the voxmlx LaunchAgent's
`StandardOutPath`/`StandardErrorPath` at a shared location and set
`VOXLOG_FILE` to match:

```bash
sudo install -d -m 0755 -o "$(id -un)" /Users/Shared/localvoxtral
# edit ~/Library/LaunchAgents/com.localvoxtral.voxmlx.plist: StandardOutPath +
# StandardErrorPath -> /Users/Shared/localvoxtral/voxmlx.log, then:
launchctl bootout "gui/$(id -u)/com.localvoxtral.voxmlx" || true
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.localvoxtral.voxmlx.plist
```

(The alternative — ACL read grants on the owner's `~/Library/Logs` chain — is
fiddlier and breaks when the log file is rotated/recreated.)

### Verifying from the Linux box

```bash
./scripts/remote-build.sh diag        # versions, processes, ports, disk, logs
./scripts/remote-build.sh applog 30   # app unified log, last 30 minutes
./scripts/remote-build.sh voxlog 100  # voxmlx log tail
./scripts/remote-build.sh svc-status  # voxmlx service/process/port status
./scripts/remote-build.sh disk        # df + per-work-dir du and last-used ages
./scripts/remote-build.sh gc          # reclaim stale work dirs now (also runs
                                      # automatically after every build/test)
ssh <gate-destination> 'ensure voxmlx' # warm the on-demand STT server
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
