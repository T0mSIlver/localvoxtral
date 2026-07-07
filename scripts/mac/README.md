# Mac build-host scripts

## `com.localvoxtral.mlxlm` — polish-LLM eval service (owner runbook)

The LLM polish prompt eval (`./scripts/remote-build.sh eval-llm`,
`LLMPolishPromptEvalTests`) needs an mlx-lm chat/completions server that is
always up on the build host, exactly like `com.localvoxtral.voxmlx` (port
8000) serves the tier-1 realtime tests. It listens on **8080** (mlx-lm's
stock port) so it never collides with the app-managed instances on 8471/8472.
Installed on the build host 2026-07-06. Don't point evals at the app-managed
server on 8472 instead — it only exists while the app is running with
polishing enabled, so it vanishes whenever the app quits.

Install from a trusted owner session on the Mac. Pins mirror
`BackendCatalog.mlxLM` — keep them in sync when the catalog moves:

```bash
# One-time venv with the pinned fork wheel (same wheel the app installs).
uv venv --python 3.12 ~/.local/share/localvoxtral-eval/mlx-lm
uv pip install --python ~/.local/share/localvoxtral-eval/mlx-lm/bin/python \
  'mlx-lm @ https://github.com/T0mSIlver/mlx-lm/releases/download/v0.31.3.post3/mlx_lm-0.31.3.post3-py3-none-any.whl'

# LaunchAgent (adjust $HOME):
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
    <!-- Same prompt-cache flags as the app-managed instance
         (BackendManager.arguments) so evals measure production behavior. -->
    <string>--prompt-cache-size</string><string>1</string>
    <string>--prompt-cache-bytes</string><string>1GB</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Users/Shared/localvoxtral/mlxlm.log</string>
  <key>StandardErrorPath</key><string>/Users/Shared/localvoxtral/mlxlm.log</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.localvoxtral.mlxlm.plist
curl -s http://127.0.0.1:8080/v1/models   # verify
```

Log path matches the voxmlx service's shared-location convention (see the
gate conf section below) so the gate account can read it if a `voxlog`-style
verb is ever added. `svc-status`/`diag` already probe port 8080.

## `localvoxtral-build-gate.sh` — SSH build gate (v2)

Forced command for the Linux dev box's build key on the Mac build host. It
allowlists the `remote-build.sh` loop (rsync in, `swift build|test`,
`package_app.sh release`) and, since v2, four read-only diagnostic verbs:
`diag`, `applog [minutes]`, `voxlog [lines]`, `svc-status`. Everything else is
denied and logged to `~/Library/Logs/localvoxtral-build-gate.log`.

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
```

No `authorized_keys` change is needed — the entry already points at
`$HOME/bin/localvoxtral-build-gate.sh`; this replaces the script in place.

### Machine-local config (`~/.localvoxtral-gate.conf` in the gate account)

The gate account is deliberately not the GUI owner account, so two things
differ per machine and are read from an optional, never-committed conf file:

```bash
# /Users/<gate-account>/.localvoxtral-gate.conf
VOXLOG_FILE=/Users/Shared/localvoxtral/voxmlx.log
VOXMLX_GUI_UID=501        # uid of the GUI user running com.localvoxtral.voxmlx
```

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
./scripts/remote-build.sh diag        # versions, processes, ports, logs
./scripts/remote-build.sh applog 30   # app unified log, last 30 minutes
./scripts/remote-build.sh voxlog 100  # voxmlx log tail
./scripts/remote-build.sh svc-status  # voxmlx service/process/port status
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
