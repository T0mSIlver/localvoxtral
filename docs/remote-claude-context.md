# Remote Claude Code context over SSH

Dictate into a Claude Code session that is running on another machine, and have
localvoxtral spell your code, file names, and identifiers correctly anyway.

The app's enrollment sheet runs the whole setup as one self-verifying flow.
It shows one consent sentence, a **Details** link to this command reference,
and one status line for each step. No token, command, or file contents appear
in Settings.

---

## What the feature is

localvoxtral polishes dictation better when it knows what you are working on. On
this Mac it can read your terminal's repository directly. On a remote host it
cannot — and never does. Instead, the Claude Code session on that host reports a
little about itself through a plugin, over an SSH tunnel you already have open,
and localvoxtral uses that to ground technical terms.

What a remote host can contribute:

- the prompt you last sent that session, and its working directory (as a label);
- short, sanitized excerpts the session's own hooks report;
- enough identity to know which session your terminal is showing.

What it can never do:

- make localvoxtral read a file on your Mac. A remote working directory is a
  string, not a path — the app has no way to turn one into a local file read;
- impersonate another enrolled host. Sessions are namespaced by the host whose
  token authenticated them;
- reach your dictation while the toggle is off.

Two different switches, worth keeping apart:

- **The toggle** (**Use Claude Code project files as polish context**, Settings
  › Integrations) gates what a dictation ATTACHES. With it off, nothing a host sent
  reaches the polisher. It does not close the port: while any enrolled host is
  unrevoked, the listener keeps accepting and caching valid hook records.
- **Revocation** is what stops a host. Its requests are then rejected rather
  than not received — if you have other enrolled hosts, one of them is still
  holding the port open — and with no active hosts left the listener closes it
  entirely.

Polish context also stays on this Mac by default: everything above is sent only
to a polisher running here, unless you turn on **Send polish context to
non-local endpoints**, which extends it to the polishing endpoint you
configured.

---

## How enrollment works

Enrolling a host is one flow that does everything, each step self-verifying.
Press **Set Up** in the enrollment sheet, or **Update host…** and **Set Up** in an
enrolled host's row — and it runs, in order, showing one short sentence of
status per step and stopping at the first failure with the exact remedy:

1. **Mac SSH config** — the marked `Host` block with `RemoteForward` and
   `SendEnv LC_LVX_TTY`. The exact block is below.
2. **Mac shell startup** — the `LC_LVX_TTY` export block in your login shell's
   rc. The exact blocks are below. Already applied, unsupported, or
   symlinked is reported, not failed.
3. **Remote plugin** — install, or update when already present, verified by
   reading the installed version back in the same SSH session. Manual
   equivalent: the commands below.
4. **Remote environment** — proves `LC_LVX_TTY` actually crosses by sending a
   fresh random value for that one call and comparing the echo exactly. The
   value is never logged. A mismatch names the side: no `sendenv` covering the
   host in this Mac's `ssh -G` means step 1's block is missing; otherwise the
   remote sshd refused it — add `AcceptEnv LANG LC_*` to `sshd_config` on that
   host and reload sshd there, which needs root on that host and is never
   attempted for you. Manual equivalent: from a window where the rc line ran,
   `ssh <alias> 'echo "[$LC_LVX_TTY]"'` — empty means the value is not
   crossing.
5. **Remote herdr** — when `herdr` resolves on the host, appends the
   agents-panel row (only when no agents table or rows key exists) and runs
   `herdr server reload-config`. "Not installed" and an already-customized
   table are reported, not failed. The exact TOML and reload command are below.
6. **Check Setup** — the two read-only verdicts, last, as the final status
   line.

### Commands run by Set Up

The app writes the two Mac files directly. For every remote script except the
tunnel check, it starts this exact process and sends the script through stdin:

```sh
ssh -o BatchMode=yes -o ClearAllForwardings=yes -- <alias> /bin/sh -s
```

The token is only in that stdin script on this Mac. The remote plugin step runs
`claude plugin list --json` before and after the mutation. Between those reads,
it runs the applicable commands:

```sh
claude plugin marketplace add T0mSIlver/localvoxtral
claude plugin marketplace update localvoxtral
claude plugin update localvoxtral-remote@localvoxtral
claude plugin install localvoxtral-remote@localvoxtral --config 'token=<token>' --config 'port=<this-Mac's-port>'
```

An update with no new token uses this last line instead:

```sh
claude plugin install localvoxtral-remote@localvoxtral --config 'port=<this-Mac's-port>'
```

The environment-crossing step sends this script with a fresh `LC_LVX_TTY`
value in the SSH child's environment:

```sh
printf 'LVX_TTY:%s\n' "${LC_LVX_TTY-}"
```

If the value does not cross, the app inspects the effective local config with:

```sh
ssh -G -- <alias>
```

The herdr step uses the following commands:

```sh
set -eu
if ! command -v herdr >/dev/null 2>&1; then
  for lv_dir in "$HOME/.claude/local" "$HOME/.local/bin" "$HOME/bin" /opt/homebrew/bin /usr/local/bin "$HOME"/.nvm/versions/node/*/bin; do
    if [ -x "$lv_dir/herdr" ]; then PATH="$lv_dir:$PATH"; break; fi
  done
fi
if ! command -v herdr >/dev/null 2>&1; then
  printf '%s\n' LVX_HERDR_ABSENT
  exit 0
fi
lv_config=${HERDR_CONFIG_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}
if [ -f "$lv_config" ] && grep -Eq '^[[:space:]]*\[ui\.sidebar\.agents\][[:space:]]*(#.*)?$|^[[:space:]]*rows[[:space:]]*=' "$lv_config"; then
  printf '%s\n' LVX_HERDR_CUSTOMIZED
  exit 42
fi
mkdir -p "$(dirname "$lv_config")"
touch "$lv_config"
cat >> "$lv_config" <<'LOCALVOXTRAL_HERDR_PANEL'
[ui.sidebar.agents]
rows = [["state_icon", "workspace", "tab"], ["agent"], [{ token = "$lvmark", dim = true }]]
LOCALVOXTRAL_HERDR_PANEL
herdr server reload-config
printf '%s\n' LVX_HERDR_CONFIGURED
```

The `grep` match stops the step without changing the file. The final tunnel
check omits `ClearAllForwardings` so it can test the configured forward:

```sh
ssh -o BatchMode=yes -- <alias> /bin/sh -s
```

Its exact stdin script checks for `curl` and posts an unauthenticated `{}` body:

```sh
set -u
command -v curl >/dev/null 2>&1 || { printf '%s\n' 'LVX_NO_CURL'; exit 0; }
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:<this-Mac's-port>/v1/hook/SessionStart 2>/dev/null) || code=000
[ -n "$code" ] || code=000
printf 'LVX_HTTP:%s\n' "$code"
```

The plugin check uses the first SSH argv above and runs `claude plugin list`
after resolving `claude` from `PATH`, `~/.claude/local`, `~/.local/bin`,
`~/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, or
`~/.nvm/versions/node/*/bin`. Plugin installation uses that same resolver.

Removing the host reverses the Mac side — the ssh block, and the shell block
only when no other host remains — and never lets a reversal problem block the
removal itself: the registry entry is the off switch, and anything that could
not be rewritten is named in an alert with its manual fix. The remote half of
uninstalling stays manual by design ("Uninstalling" below).

### Shell startup blocks

For zsh and bash, the app adds this marked block to `~/.zshrc`,
`~/.bash_profile`, or an existing `~/.bashrc`:

```sh
# localvoxtral plain-ssh join (begin)
# Publishes this terminal's tty so localvoxtral can tell which window a
# Claude Code session over ssh belongs to. Remove this block in
# Settings, or by hand.
if [ -z "${LC_LVX_TTY:-}" ] && [ -z "${SSH_TTY:-}" ]; then
  case "$(tty 2>/dev/null)" in /dev/*) LC_LVX_TTY="$(tty)"; export LC_LVX_TTY ;; esac
fi
# localvoxtral plain-ssh join (end)
```

For fish, it writes `~/.config/fish/conf.d/localvoxtral.fish`:

```fish
# localvoxtral plain-ssh join (begin)
# Publishes this terminal's tty so localvoxtral can tell which window a
# Claude Code session over ssh belongs to. Remove this block in
# Settings, or by hand.
if not set -q LC_LVX_TTY; and not set -q SSH_TTY
    set -l __lvx_tty (tty 2>/dev/null)
    if string match -q -- '/dev/*' "$__lvx_tty"
        set -gx LC_LVX_TTY "$__lvx_tty"
    end
end
# localvoxtral plain-ssh join (end)
```

### 1. An `~/.ssh/config` block

```
# BEGIN localvoxtral claude context (<host-id>)
Host <your-alias>
    RemoteForward <this-Mac's-port> 127.0.0.1:8473
    ExitOnForwardFailure no
    SendEnv LC_LVX_TTY
# END localvoxtral claude context (<host-id>)
```

`RemoteForward` means: while you have an SSH session open to that host, that
port *on the host* is a private pipe back to localvoxtral on your Mac. Nothing
listens on the network; nothing is exposed. The Mac-side end is always 8473 —
the app's own listener — and only the remote end varies.

`SendEnv LC_LVX_TTY` carries this terminal's tty into the remote session, so a
plain `ssh` Claude Code session can be joined to the window you are actually
dictating into. Set `LC_LVX_TTY` from your shell first — Settings › Integrations ›
Remote hosts › "Terminal setup for plain SSH" writes the one line for you, or
see the integration README — and with it unset this sends nothing and costs
nothing. `LC_` is the point: `sshd`'s stock `AcceptEnv LANG LC_*` already lets
it through, and the environment travels per session channel, so it survives
`ProxyJump` and `ControlMaster` where a TCP-level match cannot. Most
ssh_configs already send `LC_*`; this line is what makes it true on the ones
that do not.

The two `#` lines are not commentary — they are delimiters. localvoxtral finds
and replaces exactly the block between them, so applying the config twice is a
no-op instead of a duplicate `Host` stanza (OpenSSH is first-match-wins, and a
stale duplicate above a fresh one would silently win). Everything else in your
config is preserved byte for byte.

The app inserts the block after the one-sentence consent. It refuses to write when
`~/.ssh/config` or `~/.ssh` is a symlink (a dotfiles setup — an atomic rename
would replace your link) or when `~/.ssh` is not exclusively yours to write. In
those cases, use this reference to edit the real file yourself.

### 2. The plugin on the host

```
claude plugin marketplace add T0mSIlver/localvoxtral
 claude plugin install localvoxtral-remote@localvoxtral --config 'token=<token>' --config 'port=<this-Mac's-port>'
```

Both options travel together, always. The `port` is the same number the
ssh-config block binds: change one without the other and every hook on that
host posts into a port nothing forwards, which fails open — that is, looks
exactly like nothing happening.

`localvoxtral-remote` is a different plugin from the local `localvoxtral` one,
not a mode of it. It declares hooks only — no skill, no command, no agent, no
status line, so it never spends your tokens. Its shim is POSIX `sh` plus `curl`
and nothing else: no localvoxtral binary, no `jq`, no Node on the remote host.

The app can run both commands for you over `ssh`, sending them through the
remote shell's stdin. That guarantee is **local and only local**: the token
never appears in the arguments of any process on your Mac, so it cannot be read
out of `ps` here, and it is never written to a file here.

On the remote host it is a different story, and it cannot be otherwise.
`claude plugin install` takes its config as a command-line flag — there is no
stdin path into it — so for the lifetime of that one command the token sits in
that process's arguments, where anyone able to read the host's process table
(`/proc/<pid>/cmdline` on Linux) can see it. Afterwards it is stored in the
plugin's userConfig under `~/.claude`, readable by anything running as you on
that host.

That is the honest boundary of what a token can protect: it bounds what a
remote host may ask localvoxtral for, not what someone with access to that
host's processes and files can read. Practical consequences:

- On a shared or multi-user host, prefer pasting the command yourself, when and
  where you choose, rather than letting setup run it — the exposure window is
  brief either way, but it is yours to time.
- If you think the token was seen, **rotate it**. Rotation takes effect
  immediately, with no grace period, and running **Set Up** with the new token
  is the whole recovery.

### 3. A token

The token is generated on enrollment and passed straight into the consented
setup run. It is never shown in Settings. localvoxtral stores only a hash, so
rotation is the recovery path after an interrupted or dismissed setup. Rotation
takes effect immediately with no grace period.

What the token authorizes is narrow: a host that presents it may *contribute
remote context*. The listener tags every session it accepts as remote no matter
what the payload claims, so a host cannot talk its way into being treated as
local.

**Revoking the host in localvoxtral is the real off switch.** It takes effect
immediately, without a relaunch, and with no enrolled hosts left the app stops
listening on the port at all. Uninstalling the remote plugin only stops the host
asking.

One honest caveat: a malicious process running as you *on the remote host* can
read `~/.claude/` and therefore that host's token. The token bounds what a
remote host can do; it does not protect the host from itself.

---

## Why `ExitOnForwardFailure` stays `no`

`ExitOnForwardFailure yes` tells `ssh` to refuse the whole session if a
requested forward cannot be created. That sounds safer, and here it would be
worse: the port is already bound whenever a second window to the same host has
the tunnel, so `yes` would refuse you a shell because a dictation nicety was
unavailable. A convenience feature must never cost you your login.

The price of `no` is that a failed forward is *silent*. The hooks get connection
refused, fail open, and you simply get no context. That silence is exactly what
step 6's **Check Setup** exists to break.

## The forward port is per-Mac

The remote end of the tunnel is not a fixed 8473. Each localvoxtral install
derives its own port in the range **28473–30472** from a per-install identity
stored on that Mac, and every artifact that names a port takes it from that one
value: the ssh-config block, the install command's `port` option, the in-app
check, and the update commands.

That is not tidiness — it closes a real failure. Two SSH connections asking for
the same remote listen port do not both get it: the first wins and keeps
winning, and the second stays connected with only a warning (our block sets
`ExitOnForwardFailure no` on purpose — see below). Before per-Mac ports, that
meant a second Mac's enrollment silently delivered *this* host's events — and
its `Authorization: Bearer` token — to the first Mac, which rejected them with
a 401, which the remote shim reads as a completed exchange. Nothing anywhere
reported a problem. Distinct ports make that state unreachable.

What per-Mac ports do **not** fix, stated plainly: one remote host runs one
Claude Code install with one plugin config, so its `port` names exactly one
Mac. Enrol two Macs against the same host and only the most recently installed
config receives events. The other's tunnel binds fine and simply sees no
traffic — visible single-tenancy, not a silent cross-delivery of someone else's
credentials.

## A second session to the same host

Within one Mac, the first SSH session wins the forward. A second concurrent
session tries to bind the same port on the remote, fails, and — because
`ExitOnForwardFailure` is `no` — connects anyway with no tunnel of its own.
That is fine and expected: the first session's tunnel is still up and still
carries the host's events. This is why a raw `ssh -v` forward check is
misleading on a healthy setup, and why the in-app check probes the port instead
of grepping ssh's warnings.

## Sessions with no terminal

Hook events only reach your Mac while something holds the tunnel — normally one
of your own SSH sessions. A session a harness starts on the host (t3 code,
`claude remote-control` services, any headless runner) has no such terminal, so
its context goes nowhere. Turn on **Keep the tunnel open** in that host's row
and the app holds the forward itself, reconnecting as needed.

## Hosts enrolled before per-Mac ports

An enrollment made before this existed uses the legacy shared 8473 on both
ends, and keeps working — migration is never forced. Use **Update host…** in
the host's row when you want it: it updates the marketplace clone and the
plugin, then stores this Mac's allocated port, and it rewrites this host's
ssh-config block in the same action so the two halves can never disagree. Your
token is preserved — `claude plugin update` keeps the stored config, and
`--config` merges per key.

The update path refreshes the marketplace and calls `plugin update`; a bare
`plugin install` is not an update. On Claude Code 2.1.220 it exits 0 with
"already installed", and `marketplace add` does not refresh an existing clone.

## Shell history and rotation

The generated install command is prefixed with a space. With
`HISTCONTROL=ignorespace` (bash) or `setopt HIST_IGNORE_SPACE` (zsh) that keeps
the token out of the host's shell history. It is a habit, not a guarantee.

If you paste the command into a shell that records it anyway — or you are simply
not sure — **rotate the token**. That is what rotation is for. Running the setup
from the app instead avoids the history question: the token goes through SSH
stdin, never in a process argument on this Mac; on the host it is in that one
`claude plugin install` command's argv while it runs (see above).

## tmux, screen, and window titles

There is no window-title marker anymore: it was removed in September 2026 (see
"What was removed (September 2026)" in `integrations/claude-code/README.md`),
along with the setting and the tmux/screen title-passthrough advice that went
with it. A remote session joins by the tty echo (`LC_LVX_TTY`, above) or by
matching the SSH connection the focused terminal holds; the full mechanics and
their limits — jump hosts, `ControlMaster`, tmux/screen/zellij — are in the "A
plain `ssh host` session" section of that README.

Without either join you get **no context from that pane at all** — not a
reduced amount. Context is only ever attached to a session localvoxtral
positively joined: a lookup that cannot identify the session abstains rather
than guessing, so an unjoined pane contributes nothing. herdr users need
nothing here: a herdr pane is joined by its pane id, not by a title.

## What happens when things are missing

Everything fails open, silently. If `sh` or `curl` is absent on the host, if the
tunnel is down, if localvoxtral is not running, or if the app simply does not
answer — the hook exits successfully and you get no context. A Claude Code turn
is never blocked by this feature, and the delay it can add is bounded: the
shim's curl runs with `--max-time 1`, so the worst case is one second before it
gives up and exits 0.

Plain `ssh` to a host you have not enrolled keeps working exactly as before: no
tunnel, no token, no hooks.

One case is noisier than the rest, and not by our choice: while a session holds
the tunnel and localvoxtral is *not running*, `ssh` on your Mac prints
`connect_to 127.0.0.1 port 8473: failed.` into the remote terminal on every
dial — that is another process's stderr, which the plugin cannot silence. So
after a failed dial the shim backs off for five minutes. Prompt submits still
try, so context returns with your first prompt once the app is back.

---

## Checking the setup

Use **Check Setup** in the enrollment sheet. It runs two read-only checks and
interprets them for you. If you would rather run them by hand:

### Is the tunnel live, and is localvoxtral behind it?

```
ssh builder 'curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" -d "{}" http://127.0.0.1:28511/v1/hook/SessionStart'
```

`28511` is an example — replace it with your allocated port, the one the
`RemoteForward` line in your `~/.ssh/config` block names.

**`401` is the success answer** — provided localvoxtral is listening on this
Mac. The probe deliberately sends no credential, so being refused is the proof
that the request crossed the tunnel and something on the Mac side answered. It
does not by itself prove that the something was localvoxtral: if our own bind
failed, whatever holds the listener port (8473) here receives the forwarded
request instead,
and its rejection looks identical from the host. Check the listener line in
Settings › Integrations › Remote hosts as well — the in-app check does exactly this,
which is why it can tell you which of the two you are looking at.

`000` — or a curl connection error — means nothing answered: usually just that
you have no SSH session open to that host at this moment. Any other status code
means something that is not localvoxtral answered on that port; find it and
quit it.

If the host has no `curl` at all, the plugin can never deliver anything no
matter how healthy the tunnel is — the shim is a curl one-liner. `command -v
curl` on the host settles that; the in-app check reports it as its own verdict.

### Is the plugin installed on the host?

```
ssh <alias> 'PATH="$HOME/.claude/local:$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" claude plugin list'
```

The PATH prefix is not decoration. A non-interactive SSH command skips your
login shell's rc files, so `claude` is frequently off PATH here even on a host
where it works perfectly when you log in. Look for `localvoxtral-remote` in the
output.

The in-app check looks in one more place than this one-liner can:
`~/.nvm/versions/node/*/bin`, which npm-installed Claude Code lands in. A glob
cannot be expanded inside the quoted `PATH=` above, so if `claude` lives under
nvm on that host, run `command -v claude` in a normal shell there and prepend
that directory instead.

### Is the forward being requested at all?

```
ssh -v <alias> true 2>&1 | grep -i 'remote forward'
```

A failure line here is *expected* whenever another live session to that host
already holds the tunnel — see "A second session to the same host" above. The
port check is the truth either way, which is why the app does not run this one.

---

## Uninstalling

On the remote host:

```
claude plugin uninstall localvoxtral-remote@localvoxtral
claude plugin marketplace remove localvoxtral
```

On this Mac:

1. Remove the `# BEGIN localvoxtral claude context (<host-id>)` … `# END …`
   block from `~/.ssh/config`.
2. In Settings › Integrations › Remote hosts, **Revoke** (or **Remove**) the host.

Step 2 is the one that matters. Revocation is what actually stops the host: the
token dies on this Mac, not on the remote. With no active hosts left, the
listener closes its port.
