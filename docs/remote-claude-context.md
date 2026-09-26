# Remote Claude Code context over SSH

Dictate into a Claude Code session running on another machine, and localvoxtral
still spells your code, file names and identifiers correctly.

The app's enrollment sheet runs the whole setup as one flow that checks each
step as it goes. It shows one consent sentence, a **Details** link to this
page, and one status line per step. Settings never shows a token, a command or
file contents.

---

## What the feature is

localvoxtral polishes dictation better when it knows what you are working on. On
this Mac it reads your terminal's repository directly. On a remote host it never
does. The Claude Code session on that host reports a little about itself
through a plugin, over an SSH tunnel you already have open, and localvoxtral
uses that to spell technical terms.

A remote host can send:

- the prompt you last sent that session, and its working directory (as a label);
- short, sanitized excerpts the session's own hooks report;
- enough identity to know which session your terminal is showing.

A remote host can never:

- make localvoxtral read a file on your Mac. A remote working directory is a
  string, not a path, and the app has no way to turn one into a local file read;
- impersonate another enrolled host. Each session belongs to the host whose
  token authenticated it;
- reach your dictation while the toggle is off.

Two switches do different things:

- **The toggle** (**Send diff, recent files and last prompt**, Settings › Context) gates what a dictation
  ATTACHES. With it off, nothing a host sent reaches the polisher. It does not close the port: while any enrolled host is
  unrevoked, the listener keeps accepting and caching valid hook records.
- **Revocation** stops a host. The listener then rejects its requests, since
  another enrolled host may still hold the port open. With no active hosts
  left, the listener closes the port.

By default, polish context also stays on this Mac. The app sends it only to a
polisher running here, unless you turn on **Send context to non-local polishing servers**, which extends it to the polishing
endpoint you configured.

---

## How enrollment works

If you use herdr's saved machines (herdr 0.9's `herdr machine add`), you do not
have to type a destination. Settings › herdr lists them under **Saved
machines**, one row per machine with its saved ssh
target, and **Import…** fills the enrollment form with the machine's name and
target. A machine saved as `user@host` or an `ssh://` destination needs a
`Host` alias in your `~/.ssh/config` first. Add one, then import it.
After the form, the flow is the same for everyone.

Press **Set Up** in the enrollment sheet, or **Update host…** and **Set Up** in an
enrolled host's row. The app runs these steps in order and checks each one. It
shows one short status sentence per step and stops at the first failure with
the exact fix:

1. **Mac SSH config.** The marked `Host` block with `RemoteForward` and
   `SendEnv LC_LVX_TTY`. The exact block is below.
2. **Mac shell startup.** The `LC_LVX_TTY` export block in your login shell's
   rc. The exact blocks are below. A block that is already applied, an
   unsupported shell and a symlinked rc file are reported, not failed.
3. **Remote plugin.** Installs the plugin, or updates it when present, and
   reads the installed version back in the same SSH session to verify it. The
   commands to do it by hand are below.
4. **Remote environment.** Proves `LC_LVX_TTY` crosses by sending a fresh
   random value for that one call and comparing the echo exactly. The app never
   logs the value. A mismatch names the side. If this Mac's `ssh -G` shows no
   `sendenv` covering the host, step 1's block is missing. Otherwise the remote
   sshd refused it: add `AcceptEnv LANG LC_*` to `sshd_config` on that host and
   reload sshd there. That needs root on that host, and the app never attempts
   it for you. To check by hand, run
   `ssh <alias> 'echo "[$LC_LVX_TTY]"'` from a window where the rc line ran.
   Empty output means the value is not crossing.
5. **Remote herdr.** When `herdr` resolves on the host, appends the
   agents-panel row (only when no agents table or rows key exists) and runs
   `herdr server reload-config`. "Not installed" and an already-customized
   table are reported, not failed. The exact TOML and reload command are below.
6. **Check Setup.** Runs the two read-only checks last and shows their verdict
   as the final status line.

### Commands run by Set Up

The app writes the two Mac files directly. For every remote script except the
tunnel check, it starts this exact process and sends the script through stdin:

```sh
ssh -o BatchMode=yes -o ClearAllForwardings=yes -- <alias> /bin/sh -s
```

On this Mac, the token exists only in that stdin script. The remote plugin step
runs `claude plugin list --json` before and after the change. Between those
reads, it runs whichever of these commands apply:

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

The herdr step runs:

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

When the `grep` matches, the step stops without changing the file.

The final tunnel check runs in two steps. The first clears forwardings, so it
can only reach a tunnel another connection already holds (the app's own, a
terminal's, an editor's). That is the tunnel your hooks use between checks:

```sh
ssh -o BatchMode=yes -o ClearAllForwardings=yes -- <alias> /bin/sh -s
```

The second step runs only when nothing answered. It drops that option, so the
config block's own forward is open while it runs. A `401` there means the
block works but nothing keeps the tunnel open:

```sh
ssh -o BatchMode=yes -- <alias> /bin/sh -s
```

Both send the same stdin script, which checks for `curl` and posts an
unauthenticated `{}` body:

```sh
set -u
command -v curl >/dev/null 2>&1 || { printf '%s\n' 'LVX_NO_CURL'; exit 0; }
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:<this-Mac's-port>/v1/hook/SessionStart 2>/dev/null) || code=000
[ -n "$code" ] || code=000
printf 'LVX_HTTP:%s\n' "$code"
```

The plugin check uses the first SSH argv above and runs `claude plugin list`
after resolving `claude` from `PATH`, `~/.claude/local`, `~/.local/bin`,
`~/bin`, `/opt/homebrew/bin`, `/usr/local/bin`,
`~/.nvm/versions/node/*/bin`, or, last, the newest Claude Desktop CLI in
`~/.claude/remote/ccd-cli/<version>`. Plugin installation finds `claude` the
same way.

While the host's **Keep the tunnel open** is off, the run's first step also
checks for Claude Desktop, with the first SSH argv above and this script:

```sh
if [ -d "$HOME/.claude/remote/srv" ]; then printf 'LVX_DESKTOP:yes\n'; else printf 'LVX_DESKTOP:no\n'; fi
```

When Desktop is there, the run turns **Keep the tunnel open** on, because
Desktop's ssh never carries the tunnel. The toggle stays yours to turn off.

Removing the host reverses the Mac side. It removes the ssh block, and the
shell block only when no other host remains. A problem undoing either never
blocks the removal, because the registry entry is the off switch. An alert
names anything the app could not rewrite, with its manual fix. You uninstall
the remote half by hand, by design ("Uninstalling" below).

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

While you have an SSH session open to that host, `RemoteForward` makes that
port *on the host* a private pipe back to localvoxtral on your Mac. Nothing
listens on the network and nothing is exposed. The Mac-side end is always 8473,
the app's own listener. Only the remote end varies.

`SendEnv LC_LVX_TTY` carries this terminal's tty into the remote session, so a
plain `ssh` Claude Code session can be joined to the window you are dictating
into. Set `LC_LVX_TTY` from your shell first: Settings ›
Remote hosts › Plain SSH › "Terminal setup" writes the one line for you, or
see the integration README. With it unset, this line sends nothing and costs
nothing. The `LC_` prefix matters because `sshd`'s stock `AcceptEnv LANG LC_*`
already lets it through. The environment also travels per session channel, so
it survives `ProxyJump` and `ControlMaster` where a TCP-level match cannot.
Most ssh_configs already send `LC_*`, and this line covers the ones that do
not.

The two `#` lines are delimiters. localvoxtral finds and replaces exactly the
block between them, so applying the config twice changes nothing instead of
adding a duplicate `Host` stanza. That matters because OpenSSH uses the first
match, so a stale duplicate above a fresh one would silently win. The rest of
your config stays byte for byte the same.

The app inserts the block after the one-sentence consent. It refuses to write when
`~/.ssh/config` or `~/.ssh` is a symlink (a dotfiles setup, where an atomic
rename would replace your link) or when `~/.ssh` is not exclusively yours to
write. In those cases, edit the real file yourself using the block above.

### 2. The plugin on the host

```
claude plugin marketplace add T0mSIlver/localvoxtral
 claude plugin install localvoxtral-remote@localvoxtral --config 'token=<token>' --config 'port=<this-Mac's-port>'
```

Always pass both options together. The `port` is the same number the
ssh-config block binds. Change one without the other and every hook on that
host posts into a port nothing forwards. The hooks fail open, so this looks
exactly like nothing happening.

`localvoxtral-remote` is a separate plugin from the local `localvoxtral` one,
not a mode of it. It declares only hooks: no skill, command, agent or status
line, so it never spends your tokens. Its shim needs only POSIX `sh` and
`curl`: no localvoxtral binary, no `jq`, no Node on the remote host.

The app can run both commands for you over `ssh`, sending them through the
remote shell's stdin. That guarantee is **local and only local**: the token
never appears in the arguments of any process on your Mac, so `ps` here cannot
show it, and the app never writes it to a file here.

The remote host is different, and nothing can change that.
`claude plugin install` takes its config as a command-line flag and has no
stdin path, so while that one command runs, the token sits in its arguments.
Anyone who can read the host's process table (`/proc/<pid>/cmdline` on Linux)
can see it. Afterwards, the plugin stores it in its userConfig under
`~/.claude`, readable by anything running as you on that host.

So the token limits what a remote host may ask localvoxtral for. It does not
limit what someone with access to that host's processes and files can read. In
practice:

- On a shared or multi-user host, paste the command yourself, at a time and
  place you choose, rather than letting setup run it. The exposure is brief
  either way, but you pick the moment.
- If you think someone saw the token, **rotate it**. Rotation takes effect
  immediately, with no grace period, and running **Set Up** with the new token
  is the whole recovery.

### 3. A token

The app generates the token on enrollment and passes it straight into the
setup run you consented to. Settings never shows it. localvoxtral stores only a
hash, so after an interrupted or dismissed setup, you recover by rotating.
Rotation takes effect immediately with no grace period.

The token authorizes one thing: a host that presents it may *contribute
remote context*. The listener tags every session it accepts as remote, whatever
the payload claims, so a host cannot get itself treated as local.

**Revoking the host in localvoxtral is the real off switch.** It takes effect
immediately, without a relaunch, and with no enrolled hosts left the app stops
listening on the port at all. Uninstalling the remote plugin only stops the host
asking.

A malicious process running as you *on the remote host* can read `~/.claude/`
and so that host's token. The token limits what a remote host can do. It does
not protect the host from itself.

---

## Mistral Vibe on an enrolled host

An enrolled host can report its Mistral Vibe sessions too, over the same tunnel.
Vibe is one step of the host's setup run. The enrollment sheet's **Set Up** and the
row's **Update Host…** install the Claude Code plugin and then, when `vibe` is on the
host, the Vibe hooks. A host without Vibe skips that step, and a host without
Claude Code skips the plugin step and the plugin half of the final check. The
run fails only when the host has neither. The row offers
**Update Host…** while the plugin or the Vibe hooks are outdated or not yet heard
from, so after installing Vibe on a host, relaunch localvoxtral and press it.
When the Vibe hooks already report this version, a run leaves them alone: it
sends no Vibe script and keeps their token.

The Vibe step runs four `ssh -o BatchMode=yes -o ClearAllForwardings=yes -- <alias>
/bin/sh -s` commands, each with its script on stdin:

1. Read the host: whether `vibe` is on the non-interactive PATH (with
   `~/.local/bin` added), the installed hooks version, and `~/.vibe/hooks.toml`
   (base64, at most 256 KiB) with its `cksum`.
2. Write `~/.vibe/localvoxtral/remote/` at mode 0700 with `post.sh`,
   `terms.sh`, `compact.py` and `port` (0600), and put a marked block of two
   `[[hooks]]` tables into `~/.vibe/hooks.toml`. The new `hooks.toml` text is
   computed on this Mac by the same rules as the local install, and the script
   writes it only if the file's `cksum` is still the one step 1 saw.
3. Read the host again and compare the version and the block.
4. Write `token` (0600). It goes last, so a run that stops earlier leaves an
   existing install working with its current token.

The run refuses, and writes nothing, when a path under `~/.vibe` is a symlink,
when `hooks.toml` has an unpaired marker, a marker inside a multi-line string, a
hook named `localvoxtral-remote-files` or `localvoxtral-remote-turn` outside the
block, or a key right after the block, and when the file changed during the run.

The token is a second credential for the same host, created for this run. The
app keeps only a hash of the host's first token, which went into the Claude
Code plugin's config, so Vibe cannot reuse it. The listener trusts the new token from just before
step 4, alongside the previous Vibe token until step 4 succeeds, so an
update that loses its connection cannot lock the host out. It authenticates as
the same host, and **Rotate token**, **Revoke** and **Remove** end it like
the first. Removing a host leaves the files on it, as it leaves the Claude Code
plugin, and their token no longer authenticates. It sits in `~/.vibe/localvoxtral/remote/token`,
readable by any process running as you on that host. The Claude Code plugin's
token already has the same exposure in `~/.claude`.

What runs on the host, what it sends and what it never sends is in the
[Vibe hooks README](../integrations/vibe/README.md#on-an-ssh-host).

## Terms from the coding agent on a host

With **Ask the coding agent for each new project's terms** on
([Terms from your coding agent](dictation.md#terms-from-your-coding-agent)), a
remote Claude Code or Vibe session's project gets its terms from a run on the
host. The Mac cannot run it: the repository is on the host, and the Mac holds
only a label for it, never a path it could hand to ssh.

1. **Mac, at commit.** A dictation joins a remote Claude Code or Vibe session
   whose project (`remote:<label>`) has no answer and no attempt in the last
   24 hours, on a host that has reported `localvoxtral-remote` 1.15.0 or Vibe
   hooks 1.2.0. The Mac marks that session in memory for 10 minutes and records
   an attempt on the project.
2. **Mac, next hook.** The reply to that session's next hook carries
   `X-Lvx-Terms: wanted`, once. The body stays the constant one.
3. **Host shim.** `post.sh` matches the header exactly and takes a per-project
   stamp in its state directory (`$XDG_RUNTIME_DIR/localvoxtral/terms/`, else
   `~/.cache/localvoxtral/terms/`) by an atomic `mkdir`. The project is the git
   toplevel of the hook's working directory, or that directory outside git. A
   project marked done, or attempted in the last 24 hours, is skipped.
   Otherwise the shim starts `terms.sh` detached (`setsid`, or an ignored
   `HUP` where there is none) under `env -i HOME PATH LANG`, with every
   descriptor on `/dev/null` and the token on stdin, and returns.
4. **Host runner.** `terms.sh` runs the same read-only `claude -p` or `vibe -p`
   as the Mac's local run, in the project directory, with a 180 s watchdog.
   Vibe runs under `~/.vibe/localvoxtral/remote/vibe-home`, which holds only
   links to your `config.toml` and `.env`, so no Vibe hook fires. It posts the
   first 8 KiB of the answer to `POST /v1/terms`, with the token in a header
   file and the session id in `X-Lvx-Terms-Session`. A 200 marks the project
   done.
5. **Mac, `/v1/terms`.** The listener authenticates the token, scopes the
   session id under that host, and accepts only an answer for a live session
   it asked, from the agent it asked, once. It files the terms under the
   project it recorded in step 1, never one the host names, through the same
   filter as a local answer. Anything else is refused with a status and a log
   line that names the reason, never the body.

What crosses the tunnel is the answer, `{"terms": [...]}`: about 120 bytes in
the measured runs. The run bills the host's Claude Code login or Mistral key,
under the same caps as the local run. A process that squats the forward port
could send the header too; the host's stamp bounds that to one run per project
per 24 hours.

## Why `ExitOnForwardFailure` stays `no`

`ExitOnForwardFailure yes` tells `ssh` to refuse the whole session if it cannot
create a requested forward. That sounds safer, but here it is worse. The port
is already bound whenever a second window to the same host has the tunnel, so
`yes` would refuse you a shell because dictation context was unavailable.
Dictation context should never cost you your login.

The price of `no` is that a failed forward is *silent*. The hooks get connection
refused, fail open, and you get no context. Step 6's **Check Setup** exists to
catch that.

## The forward port is per-Mac

The remote end of the tunnel is not a fixed 8473. Each localvoxtral install
derives its own port in the range **28473–30472** from a per-install identity
stored on that Mac, and every artifact that names a port takes it from that one
value: the ssh-config block, the install command's `port` option, the in-app
check, and the update commands.

This prevents a real failure. When two SSH connections ask for the same remote
listen port, only the first gets it and keeps it. The second stays connected
with only a warning (our block sets `ExitOnForwardFailure no` on purpose, see
above). Before per-Mac ports, a second Mac's enrollment silently delivered
*this* host's events, and its `Authorization: Bearer` token, to the first Mac.
That Mac rejected them with a 401, which the remote shim reads as a completed
exchange. Nothing reported a problem. Distinct ports make that state
impossible.

Per-Mac ports do **not** fix this: one remote host runs one Claude Code install
with one plugin config, so its `port` names exactly one Mac. Enrol two Macs
against the same host and only the most recently installed config receives
events. The other Mac's tunnel binds fine and sees no traffic. That limit is
visible, and no Mac receives another's credentials.

## A second session to the same host

Within one Mac, the first SSH session gets the forward. A second concurrent
session tries to bind the same port on the remote and fails. Because
`ExitOnForwardFailure` is `no`, it connects anyway with no tunnel of its own.
That is expected and harmless: the first session's tunnel is still up and
still carries the host's events. So a raw `ssh -v` forward check is
misleading on a healthy setup, and the in-app check probes the port instead
of grepping ssh's warnings.

The problem comes when that first session ends. The port frees, but the
sessions that failed to bind never ask again. A host whose open sessions all
started while another one held the forward has no tunnel at all, and no
terminal says so. The sessions left open are usually long-lived ones that are
not shells: an editor's remote server, a herdr federation link, a socket
forward. **Keep the tunnel open** (below) fixes this, because the app re-binds
the port itself instead of leaving it to whichever session came first.

## Sessions with no terminal

Hook events reach your Mac only while something holds the tunnel, normally one
of your own SSH sessions. A session a harness starts on the host (t3 code,
`claude remote-control` services, any headless runner) has no such terminal, so
its context goes nowhere. Claude Desktop's sessions on the host are in the same
position: Desktop's ssh clears every forward. Turn on **Keep the tunnel open**
in that host's row and the app holds the forward itself, reconnecting as
needed, including after the Mac wakes or changes network. Host setup turns it
on when it finds Claude Desktop on the host.

After a network change, the host keeps the old connection's port bound until
its sshd notices the connection is gone. Until then the row reads "Port held on that
host", and the app checks again every five minutes.
`ClientAliveInterval 30` in the host's `sshd_config` (with the default
`ClientAliveCountMax 3`) makes sshd drop a dead connection within about 90
seconds.

## Hosts enrolled before per-Mac ports

An enrollment made before per-Mac ports uses the legacy shared 8473 on both
ends and keeps working. The app never forces a migration. When you want one,
use **Update host…** in the host's row. It updates the marketplace clone and
the plugin, stores this Mac's allocated port, and rewrites this host's
ssh-config block in the same action, so the two halves always agree. Your
token is preserved: `claude plugin update` keeps the stored config, and
`--config` merges per key.

The update refreshes the marketplace and calls `plugin update`, because a bare
`plugin install` does not update. On Claude Code 2.1.220 it exits 0 with
"already installed", and `marketplace add` does not refresh an existing clone.

## Shell history and rotation

The generated install command is prefixed with a space. With
`HISTCONTROL=ignorespace` (bash) or `setopt HIST_IGNORE_SPACE` (zsh) that keeps
the token out of the host's shell history. It is a habit, not a guarantee.

If you paste the command into a shell that records it anyway, or you are not
sure, **rotate the token**. Running the setup from the app avoids shell history
altogether. The token goes through SSH stdin and never into a process argument
on this Mac. On the host, it is in that one `claude plugin install` command's
argv while it runs (see above).

### Federated herdr machines

If your local herdr 0.9 client is showing a machine from another host, localvoxtral can join the Claude Code session on that machine without an ssh process in the terminal. It reads which machine herdr selected, reaches that machine's herdr over the app-managed tunnel, and checks a short-lived panel marker on your screen. If the marker does not appear, use Settings › herdr › Saved machines › **Mic indicator in herdr panel** to add the indicator row to this Mac's herdr config, then reload config in herdr. localvoxtral cannot reload herdr for you.

The join can only pick from sessions whose hooks have reached this Mac, and a
federated view carries none of your own ssh sessions to hold the hook tunnel.
herdr's link uses your ssh config, but it may have lost the forward to a
session that has since ended (see "A second session to the same host"). Turn
on **Keep the tunnel open** in that host's row. Without it, the join abstains
with "no live session on the selected herdr session" in the log, and the
status line on the host shows a grey dot.

## tmux, screen, and window titles

September 2026 removed the window-title marker (see
"What was removed (September 2026)" in `integrations/claude-code/README.md`),
along with its setting and the tmux/screen title-passthrough advice. A remote
session joins by the tty echo (`LC_LVX_TTY`, above) or by matching the SSH
connection the focused terminal holds. The "A
plain `ssh host` session" section of that README covers the full mechanics and
their limits: jump hosts, `ControlMaster`, tmux/screen/zellij.

Without either join you get **no context from that pane at all**, not a
reduced amount. localvoxtral attaches context only to a session it positively
joined. A lookup that cannot identify the session abstains rather than
guessing, so an unjoined pane contributes nothing. herdr users need nothing
here: localvoxtral joins a herdr pane by its pane id, not by a title.

## What happens when things are missing

Everything fails open, silently. If `sh` or `curl` is missing on the host, the
tunnel is down, localvoxtral is not running, or the app does not answer, the
hook exits successfully and you get no context. This feature never blocks a
Claude Code turn, and the delay it can add is bounded: the shim's curl runs
with `--max-time 1`, so at worst it waits one second, gives up and exits 0.

Plain `ssh` to a host you have not enrolled keeps working exactly as before: no
tunnel, no token, no hooks.

One case is noisier. While a session holds the tunnel and localvoxtral is *not
running*, `ssh` on your Mac prints
`connect_to 127.0.0.1 port 8473: failed.` into the remote terminal on every
dial. That is another process's stderr, which the plugin cannot silence, so
after a failed dial the shim backs off for five minutes. Prompt submits still
try, so context returns with your first prompt once the app is back.

---

## Checking the setup

Use **Check Setup** in the enrollment sheet. It runs two read-only checks and
explains the results. To run them by hand:

### Is the tunnel live, and is localvoxtral behind it?

```
ssh -o ClearAllForwardings=yes builder 'curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" -d "{}" http://127.0.0.1:28511/v1/hook/SessionStart'
```

`ClearAllForwardings=yes` keeps this ssh from opening the tunnel itself.
Without it, the check carries your config block's `RemoteForward`, answers
through a tunnel that closes when the check does, and looks healthy on a host
where nothing else ever holds the tunnel.

`28511` is an example. Replace it with your allocated port, the one the
`RemoteForward` line in your `~/.ssh/config` block names.

**`401` is the success answer**, provided localvoxtral is listening on this
Mac. The probe sends no credential on purpose, so a refusal proves the request
crossed the tunnel and something on the Mac side answered. It does not prove
that the something was localvoxtral. If our own bind failed, whatever holds the
listener port (8473) here receives the forwarded request instead, and its
rejection looks identical from the host. Check the listener line in
Settings › Remote hosts as well. The in-app check does exactly this, which is
how it tells the two cases apart.

`000`, or a curl connection error, means nothing holds the tunnel right now:
no SSH session of yours to that host carries it, and the app is not holding it.
Turn on **Keep the tunnel open**, or run the check again without
`ClearAllForwardings` to see whether your config block opens it at all. Any
other status code means something other than localvoxtral answered on that
port. Find it and quit it.

If the host has no `curl`, the plugin can never deliver anything, however
healthy the tunnel is, because the shim is a curl one-liner. Run `command -v
curl` on the host to find out. The in-app check reports it as a separate
verdict.

### Is the plugin installed on the host?

```
ssh <alias> 'PATH="$HOME/.claude/local:$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" claude plugin list'
```

The PATH prefix is needed because a non-interactive SSH command skips your
login shell's rc files. `claude` is often off PATH here, even on a host where
it works when you log in. Look for `localvoxtral-remote` in the output.

The in-app check also looks in `~/.nvm/versions/node/*/bin`, where
npm-installed Claude Code lands. The quoted `PATH=` above cannot expand a
glob, so if `claude` lives under nvm on that host, run `command -v claude` in
a normal shell there and prepend that directory instead.

### Is the forward being requested at all?

```
ssh -v <alias> true 2>&1 | grep -i 'remote forward'
```

A failure line here is *expected* whenever another live session to that host
already holds the tunnel (see "A second session to the same host" above). The
port check gives the real answer either way, so the app does not run this one.

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
2. In Settings › Remote hosts, **Revoke** (or **Remove**) the host.

Step 2 is the one that matters. Revocation is what actually stops the host: the
token is invalidated on this Mac, not on the remote. With no active hosts left, the
listener closes its port.
