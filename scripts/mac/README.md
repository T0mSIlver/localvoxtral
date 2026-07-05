# Mac build-host scripts

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

- `applog` uses `log show`, which macOS may restrict for non-admin accounts.
  If it returns nothing for the gate account, that's the cause — the crashlog
  workflow (`mac-crashlog.yml`) runs as the runner user and is the fallback.
- `svc-status` includes process and port sections because `launchctl print`
  cannot read another user's GUI domain.
