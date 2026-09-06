# localvoxtral — Claude Code plugin

A Claude Code plugin that tells the localvoxtral dictation app what your Claude
Code session is currently doing, so dictation can ground technical terms it
would otherwise mishear (filenames, symbols, the thing you asked for last turn).

This directory is a **local Claude Code marketplace**. It is the source of truth
in the repo, and `scripts/package_app.sh` copies it into the app bundle at
`Contents/Resources/claude-code-marketplace`, so an installed app can register it
without a checkout and without a separate marketplace repository.

## What it does

The plugin declares **hooks only**. It ships no skill, no slash command, and no
agent — nothing here consumes Claude tokens, adds latency to your turn, or
appears in Claude's context. It is a data channel, not a Claude feature.

On each hook event, Claude Code runs `hooks/publish.sh`, which locates the
`localvoxtral-claude-hook` publisher and runs it as a **child process** — not
`exec`. That distinction is deliberate: `exec` would replace the shim, so a
publisher that cannot start at all (wrong architecture, quarantined bundle,
missing dyld dependency) would surface its exec failure as the hook's exit code
— a visible error on your turn, which is precisely what fail-open exists to
prevent. Staying alive to swallow that is the shim's whole job. The publisher
writes one bounded NDJSON line to a private UNIX socket owned by the app and
exits.

| Hook | What localvoxtral learns |
|---|---|
| `SessionStart` | a session exists; its cwd and terminal |
| `UserPromptSubmit` | your latest prompt (the "prior prompt" when you next dictate) |
| `CwdChanged` | the session moved to another directory |
| `PostToolUse` (`Read`/`Edit`/`Write`/`NotebookEdit`) | which files were just read or edited |
| `Stop` | the turn finished |
| `SessionEnd` | the session is gone (the app evicts it immediately) |

There is deliberately no `FileChanged` hook: Claude Code only fires it for a
hook declaring `watchPaths`, and `PostToolUse` already reports every file the
model touches without watching your whole tree.

## Which terminal am I dictating into?

Every mechanism below matches ONE identifier your session's own hooks
published against the SAME identifier read off the surface you are looking at.
There is no fallback that guesses, and in particular **no join reads your
window title** — that mechanism was removed in September 2026 (see "What was
removed" below). (Repo vocabulary, a separate opt-in feature, still reads a
terminal title to find a git root; it never picks a Claude session.)

**TTY join (the default — Ghostty ≥ 1.4 [currently the tip channel], iTerm2,
and Terminal.app).** The hooks report
the session's controlling terminal device, and at dictation start the app asks
the focused terminal itself for its focused pane's `tty` over AppleScript (a
one-time Automation consent prompt per terminal). Device equality is exact,
works mid-response, and tells two sessions in the same repo apart. Inside a
[herdr](https://herdr.dev) multiplexer session the TTY can't match (herdr
interposes its own PTY per pane), so the app instead binds the surface to
herdr and asks herdr's own socket for the focused pane — an exact pane-id
join: any ambiguity, including two live herdr
sessions, attaches nothing. Other terminals abstain entirely rather than
half-join.

**cmux surface join (opt-in).** [cmux](https://github.com/manaflow-ai/cmux)
draws its terminal with libghostty into a custom view: it exposes no
accessible text and no scripting dictionary, so neither the TTY read nor any
screen read above works there. Instead the app asks cmux's own automation
socket which surface is focused, and matches that surface id against the one
cmux injected into the session's environment — including into shells opened
with `cmux ssh`, which is one of the ways a REMOTE session can
join. That surface is also the only readable screen
context, fetched per-surface (`surface.read_text`, the visible viewport, never
the scrollback).

Two things must be set up, because cmux's socket refuses outside clients by
default:

1. In **cmux → Settings → Automation**, set the socket mode to **Password**
   and choose a socket password. (The default `cmuxOnly` mode admits only
   processes cmux itself started, which localvoxtral is not. `allowAll` is
   developer-only and is not required.)
2. In localvoxtral, enable **Settings → Text Processing → Polishing → "Join
   Claude Code sessions in cmux"** and enter the same password in **cmux
   socket password**. It is stored in your Keychain and sent only to cmux's
   local socket.

If the socket refuses the app, the settings row says
`cmux socket requires password mode.` and the dictation joins nothing —
nothing is attached on a failed join.

Two deliberate limits. The app cross-checks the surface's terminal device
against the one your session reported, and **abstains when either side does not
report one** — which is the case for opencode (its server half never claims a
pane), so opencode inside cmux does not join over this arm. And a session on a
remote host joins only while cmux itself reports that surface's workspace as a
live `cmux ssh` workspace, so a stale surface id from an earlier remote session
cannot attach itself to whatever you are looking at now.

**Browser tab join (Claude Code "Remote Control").** A Remote Control session
runs the `claude` process on one of your machines while
[claude.ai/code](https://claude.ai/code) in a browser is its UI — there is no
pane, no tty, and no title to join on. Since Claude Code 2.1.199 the hooks of
such a session carry `CLAUDE_CODE_BRIDGE_SESSION_ID`, whose value is exactly
the `session_…` component of that browser URL, so when the frontmost app is a
browser the app reads its focused tab's URL over AppleScript and matches the
id by exact equality against what the session's own hooks reported. Local and
remote (SSH) sessions can both join this way — the id is allocated by
Anthropic's bridge and is globally unique, unlike a tty or pane id. Claude Code
REMOVES the variable when the Remote Control connection ends, so the join ages
out on the session's next hook.

Supported browsers are **Google Chrome, Brave, and Safari**, and each one needs
its OWN Automation grant the first time it is used (System Settings → Privacy &
Security → Automation → localvoxtral). The grant is requested only while
**Settings → Text Processing → Polishing → Claude Code project context** is on
— that is the only feature a browser join can serve. Firefox is not supported:
it exposes no AppleScript surface for the focused tab's URL. A browser join
never reads anything on your screen (a web page is not a terminal grid, and
there is no verified per-tab capture route) — it attaches the session's own
off-screen context only, and for a local session its repository, exactly like a
terminal join does.

### A plain `ssh host` session

A Claude Code session running in an ordinary `ssh` shell on an **enrolled**
host — no herdr, no cmux, no Remote Control — joins on the **TCP connection**
your terminal is holding.

There are two ways it can identify your window, tried in that order.

### 1. The tty echo (works through jump hosts and `ControlMaster`)

**The app can do this for you.** Settings → the Claude Code pane → *Remote
Claude Code over SSH* → **Set Up…** next to "Terminal setup for plain SSH". It
shows the exact block first, writes it only after you say yes, is idempotent
(a second run replaces rather than duplicates), and has a **Remove**. The row
also reports whether a remote session has actually arrived carrying the value,
which is the half you cannot see from the file.

It refuses to write through a symlink: if your `~/.zshrc` is a link into a
dotfiles repo, an atomic write would replace the link and detach your setup, so
it tells you and you paste the block yourself.

The manual alternative — add this to your shell's rc file **on your Mac**:

```sh
if [ -z "${LC_LVX_TTY:-}" ] && [ -z "${SSH_TTY:-}" ]; then
  case "$(tty 2>/dev/null)" in /dev/*) LC_LVX_TTY="$(tty)"; export LC_LVX_TTY ;; esac
fi
```

That publishes the terminal's own device name. `ssh` carries it into the
session (`SendEnv`; the enrollment block adds the line, and most ssh_configs
already send `LC_*` anyway), `sshd` accepts it because its stock config is
`AcceptEnv LANG LC_*`, and localvoxtral joins by comparing it against the tty
of the window it can see. `LC_` is not a trick played on you: it is the same
mechanism iTerm2 uses for `LC_TERMINAL`, and locale libraries ignore names
they do not know.

Every part of that block earns its place, and a shorter version was measured
to be wrong:

* `SSH_TTY` unset means "only on this Mac", and the `LC_LVX_TTY` check means
  "do not overwrite what was sent to me". Put the same rc file on a remote host
  without them and the remote shell replaces your Mac's tty with its own —
  nothing matches, and because the variable is then *set*, no later shell fixes
  it either.
* The `case` is not decoration: in a shell with no terminal, `tty` prints
  `not a tty`, and the first draft of this line exported that string. It is
  harmless (the shim's charset drops it) but it poisons the "already set"
  guard for every shell that inherits it.
* It is an `if` block rather than a one-line `&&` chain because the chain's
  status becomes the rc file's status. Measured: `bash --norc -c 'set -e;
  source rc; echo SURVIVED'` printed nothing and exited 1 with the chain, and
  `SURVIVED` with exit 0 using the block above. `bash` sources `~/.bashrc`
  non-interactively for shells it believes sshd started, so the chain version
  could break `ssh host script` for anyone syncing dotfiles.

**Why this one and not the connection below:** ssh carries environment per
SESSION, not per connection. So it survives `ProxyJump` (where your Mac holds
no connection to the destination at all) and `ControlMaster` (where several
windows share one), which are exactly the two setups the connection match
cannot see through.

If your host's `sshd` refuses `LC_*` — rare, but it happens on hardened
configs — add this there and reload sshd:

```
AcceptEnv LC_LVX_TTY
```

To check that the value is actually arriving — the one thing that can go wrong
— ask the remote side, not `--probe-surface`. That verb runs as a separate
one-shot process with its own empty session registry, so it can tell you which
arm ran and why the SURFACE was or was not identified, but it never has the
live sessions this check needs:

```sh
ssh sandbox-vpn 'echo "[$LC_LVX_TTY]"'   # from a window where the rc line ran
```

An empty answer means the variable is not crossing (rc line, `SendEnv`, or a
hardened `AcceptEnv`). If you run a dogfood build, `registry list` reports
`remoteLocalTTY` per session, which is the same fact from the app's side.

### 2. The connection (zero setup, no jump host)

`sshd` puts `$SSH_CONNECTION` into every session it starts: the client address
and port, then the server address and port. The remote plugin publishes it, and
on your Mac the app looks at the `ssh` process running in your focused
terminal, reads that process's own established socket out of the kernel, and
requires the two to be the same connection — same client port, same server
address, same server port. The client port is an ephemeral number your Mac's
kernel picked; the only machine that learns it is the one on the other end of
that connection.

Either way it attaches the session block and (for a local session) repository
context. It never attaches your screen: a plain ssh shell's scrollback is your
whole remote session, not one pane, so no raw capture is authorized for either
join.

Neither joins in these cases:

* **through a jump host, without the rc line above** (`ssh -J`, `ProxyJump`,
  or a `ProxyCommand`): your Mac's socket goes to the jump host, while the
  machine you land on sees the jump host's port. They are two different
  connections, and only the jump host knows which is which — a fact it cannot
  tell you without root there. The app says so exactly ("this connection goes
  through a jump host"). **The tty echo has no such problem**; if you jump,
  set it up;
* **inside tmux, screen or zellij**: a multiplexer server keeps the
  `$SSH_CONNECTION` of the connection that STARTED it, so a session in a pane
  can report a connection that belongs to a different window of yours.
  Measured, not assumed. herdr and cmux have their own joins, which bind the
  pane rather than the connection; tmux, screen and zellij have none;
* **when your `~/.ssh/config` may be sharing one connection**
  (`ControlMaster`), again only without the rc line: several terminals then
  run over one TCP connection and all report the same `$SSH_CONNECTION`, so it
  no longer identifies a window. Detected two ways, each with its own reason
  in `--probe-surface`: the window you are dictating into holds no connection
  of its own (it is a mux client), or another `ssh` session to the same host
  does. The tty echo is unaffected — ssh gives each session its own
  environment even over a shared connection;
* **when anything is ambiguous**: two sessions reporting the same connection,
  two enrolled hosts matching the destination, an unreadable process table.

If nothing joins and you expect it to, check the remote plugin version: this
needs **1.7.0 or newer** on the remote host (`claude plugin update
localvoxtral-remote`). `localvoxtral --probe-surface` names the exact reason.
After adding the rc block — by hand or from Settings — you must open a NEW
terminal window and a NEW ssh session: the environment is fixed when a session
starts.

### What was removed (September 2026)

Until then there was one more mechanism: the app allocated an `lvx-<hex>`
marker per session, handed it back in the hook reply, and Claude Code wrote it
into the window title as an OSC 2 escape sequence, where a focused-window read
could find it. There was a **Local Claude title fallback** setting to turn it
on for local sessions (default off), it asked you to export
`CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`, and it was the only join an ordinary
`ssh host` session had.

It is gone, all of it — the marker, the setting, the escape sequence, the
`terminalSequence` field in the hook reply, and the tmux/screen title
passthrough advice that went with it. **The hooks now print nothing at all,
ever**, and neither the local socket nor the remote listener has any field that
could put a byte on your terminal. The reason is that a window title is a
channel everything rewrites — Claude Code writes its own conversation titles
over it mid-turn, herdr and cmux rewrite their pane titles, and you may rename
a window yourself — so a marker sitting in a title said where a session used to
be, not what your screen is showing now.

That is measured, not assumed. On the owner's setup (2026-09-05) a herdr pane's
captured title was polled at ~325 Hz for 69.4 s across a hook event: the marker
was the title for 0.88 s in total, **1.26 %** of the window, and Claude Code's
own conversation title held it the rest of the time. A remote-herdr join that
had everything else right still failed on that check — unless the user had
exported `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`, which made it succeed
immediately. The check was a one-in-a-hundred lottery, not a second binding.

**What this cost you, and what replaced it:** for one release a plain
`ssh host` session with no herdr, no cmux and no Remote Control had no join at
all. It joins again, on the connection itself — see "A plain `ssh host`
session" above. Everything else was unaffected throughout: local sessions join
by tty, herdr panes by pane id (local and remote), cmux by surface id (local
and remote), Remote Control by bridge session id.

**If you had the setting on**, the stored value is simply ignored — there is
nothing to migrate, and you can drop
`CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` from your shell profile.

## Install / update / uninstall

The app way: **Settings → Text Processing → Polishing → "Claude Code plugin
(this Mac)" → Install or Update**. That button registers the bundled marketplace
and installs the plugin, then reports one short line. Nothing is installed until
you press it — the app never touches your Claude Code setup at launch or on a
timer.

Everything it does goes through Claude Code's own plugin CLI.

**`~/.claude/settings.json` is never read, written, wrapped, or merged by
localvoxtral.** That file is yours and Claude Code owns its schema; the CLI is
the supported interface, and a third-party app editing it is how setups get
corrupted during an unrelated upgrade.

If you prefer to run the commands yourself, these are the same ones the button
runs. The only difference is `--config publisher_path=…`: the app knows where
its own publisher binary is and passes that path, which is how the plugin works
for an app in `~/Applications`, on a mounted volume, or in a dev build. Omit it
and the shim falls back to guessing `/Applications` and `~/Applications` (see
the environment table below).

From an **installed app**:

```sh
claude plugin marketplace add "/Applications/localvoxtral.app/Contents/Resources/claude-code-marketplace"
claude plugin install localvoxtral@localvoxtral \
  --config 'publisher_path=/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook'
```

From a **repo checkout**:

```sh
claude plugin marketplace add ./integrations/claude-code
claude plugin install localvoxtral@localvoxtral
```

Update (re-reads the marketplace, then reinstalls). This is a reinstall rather
than `claude plugin update` because `update` accepts no `--config`, and an
update that cannot re-pin `publisher_path` strands the shim on a stale path
whenever the app has moved:

```sh
claude plugin marketplace add "/Applications/localvoxtral.app/Contents/Resources/claude-code-marketplace"
claude plugin uninstall localvoxtral@localvoxtral
claude plugin install localvoxtral@localvoxtral \
  --config 'publisher_path=/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook'
```

Uninstall (removes the plugin, then deregisters the marketplace so nothing of
ours is left in your Claude Code config):

```sh
claude plugin uninstall localvoxtral@localvoxtral
claude plugin marketplace remove localvoxtral
```

Verify:

```sh
claude plugin list
```

## Connection indicator (opt-in status line)

One glance at Claude Code's bottom bar answers the question this plugin
otherwise leaves silent: *is localvoxtral connected to this session?*

Claude Code has no plugin-owned status line, and localvoxtral never writes
`~/.claude/settings.json` — so this is wired by **you**, once, in your own
settings. The publisher binary has a `--statusline` mode that reads the
status-line payload Claude Code pipes in, asks the app's socket whether THIS
session (by `session_id`) is live in its registry, and prints exactly one of
three fixed lines:

| Line | Meaning |
|---|---|
| `● localvoxtral connected` (green) | the app is running and this session's hooks are reaching it |
| `○ localvoxtral not connected` (yellow) | the app is running but has no live record of this session — plugin not installed, or the app started after this session's last hook (it catches up on your next prompt) |
| `○ localvoxtral not running` (dim) | nothing is listening on the socket |

In `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook --statusline"
  }
}
```

(Adjust the path for `~/Applications` or a dev build — it is the same binary
`publisher_path` points at.) If you already have a status line, keep it and
append ours: buffer stdin once and feed both, e.g.

```sh
#!/bin/sh
input=$(cat)
printf '%s' "$input" | ~/.claude/my-statusline.sh
printf '%s' "$input" | /Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook --statusline
```

The query is read-only by construction: asking never creates a session and
never refreshes one. The three strings above are
compile-time constants — nothing read off the socket is ever echoed into
your terminal — and a payload without a usable `session_id` prints nothing
rather than guessing.

## Fail-open, always

If localvoxtral is not running, not installed, or its socket is absent, the hook
drains stdin, prints nothing, and exits 0. Same for a missing publisher binary,
a full socket, or a slow app: the publisher gives up after ~250 ms.

Your Claude session must never stall, warn, or fail because a dictation nicety
was unavailable. Nothing in this plugin can block a turn.

## What crosses the socket

An allowlist, not a filter:

* the event name, session id, timestamp, and cwd
* your prompt text (`UserPromptSubmit` only)
* absolute file paths from the tools above
* safe process metadata: pid, ppid, controlling TTY, `$TERM_PROGRAM`, and the
  multiplexer/bridge handles that say which pane the session lives in —
  `$HERDR_PANE_ID`, `$HERDR_SOCKET_PATH`, `$CMUX_SURFACE_ID`,
  `$CMUX_SOCKET_PATH`, `$CLAUDE_CODE_BRIDGE_SESSION_ID`. Never the rest of the
  environment.

What never crosses, by construction:

* **transcript contents** — the publisher drops `transcript_path` entirely, so
  there is nothing to scrape and no pointer to it
* **file contents** — `Write.content`, `Edit.new_string`, `Read` output
* **command strings** — `Bash` is not even subscribed to
* **anything claiming to be trusted** — trust is decided by the app from UNIX
  peer credentials, never from a field on the wire

Every field is length-capped at both ends. Hook content is never logged.

## Configuration

| Setting | Purpose |
|---|---|
| `publisher_path` (plugin userConfig) | Absolute path to the publisher. localvoxtral sets this for you at install time, which is how the plugin finds an app in `~/Applications`, on a mounted volume, or in a dev build. The shim reads it as `CLAUDE_PLUGIN_OPTION_PUBLISHER_PATH`. |
| `LOCALVOXTRAL_CLAUDE_SOCKET` | Socket path. Defaults to `~/Library/Application Support/localvoxtral/run/claude-context.sock` (macOS) or `$XDG_RUNTIME_DIR/localvoxtral/claude-context.sock` (Linux). |
| `LOCALVOXTRAL_CLAUDE_HOOK_BIN` | Path to the publisher; overrides everything else. |

---

# Remote / SSH sessions — the `localvoxtral-remote` plugin

When you dictate into a Claude Code session running on another machine over SSH,
the local plugin cannot help: there is no app on that host and no socket to write
to. `localvoxtral-remote` is the second plugin in this marketplace, and it is for
exactly that case.

**Install it on the REMOTE host, not on your Mac.** The two plugins are not modes
of each other — they have different transports and different trust models, and a
plugin installed on the wrong side fails open silently forever.

| | `localvoxtral` | `localvoxtral-remote` |
|---|---|---|
| Install on | the Mac running the app | the remote host |
| Transport | AF_UNIX socket, `command` hook + shim | HTTP over an SSH `RemoteForward`, `command` hook + `curl` shim |
| Authentication | kernel-verified peer UID | per-host bearer token you issue in the app |
| Needs on that host | the app's publisher binary | POSIX `sh` and `curl` only — no Python, no `jq`, no `nc`, no Node, no localvoxtral binary |
| Context it delivers | full: cwd authorizes local repository reads | opaque: labels and bounded excerpts only |

## How it works

```
remote host                            your Mac
┌───────────────────────┐              ┌────────────────────────────┐
│ Claude Code           │              │ localvoxtral               │
│   command hook (curl)►│ 127.0.0.1:28511             ▲             │
│   Bearer <token>      │   │          │              │             │
└───────────────────────┘   │          │   ClaudeRemoteContextListener
                            └── ssh RemoteForward ────┘             │
        ◄──────────── {"suppressOutput":true} ───────────────────┘
```

The remote plugin subscribes to `UserPromptSubmit`, `Stop`, `CwdChanged`,
`PostToolUse` and `SessionEnd` — **not** `SessionStart`, which is why a remote
session first becomes visible to the app on the prompt you submit, rather than
when you start Claude Code. Everything else about the events matches the local
table above.

Each hook runs the plugin's bundled POSIX-sh shim (`hooks/post.sh`), which
curls the hook's event JSON to `http://127.0.0.1:<your Mac's port>/v1/hook/<Event>`
on the *remote* loopback; OpenSSH's `RemoteForward` carries that to your Mac's
loopback port 8473, where the app is listening. That remote port is **allocated
per Mac** (a stable number in 28473–30472, derived from a per-install identity)
so two Macs enrolled against one host can never ask for the same bind — see
"Two Macs, one host" below. The shim reads the token and the port from the
`CLAUDE_PLUGIN_OPTION_TOKEN` / `CLAUDE_PLUGIN_OPTION_PORT` environment variables
Claude Code injects into command-hook subprocesses, and passes it to curl through a private tempfile
(`--header @file`) so it never appears in any process's argument list. It
needs only `sh` and `curl` on the host, and fails open — silently, printing
nothing — when either is missing, the token is unset, the tunnel is down, or
the app does not answer within a second. (Declarative `http` hooks cannot do
this: Claude Code expands their header `${VAR}`s from the process environment
only and never injects plugin userConfig options there, so an http hook would
always authenticate as an empty `Bearer` and be refused.)
The app answers every hook with the same fixed body, `{"suppressOutput":true}`
— a constant, not a function of anything the request said, and carrying no
field that could put a byte on your terminal. The shim refuses to print
anything else. Nothing else opens a port, and nothing is reachable from your
LAN.

## When the app is not running on your Mac

The shim's own failures are always silent, but there is one message it cannot
reach: while an SSH session holds the forward and localvoxtral is not running,
each dial makes **ssh itself, on your Mac**, print
`connect_to 127.0.0.1 port 8473: failed.`
onto the terminal — over whatever is drawn there (a herdr pane, the Claude Code
screen), once per hook. That stderr belongs to another process on another
machine; no plugin-side redirect can touch it, and silencing it in ssh would
take `LogLevel QUIET`, which also hides host-key warnings — not a trade this
plugin will make for you.

So the shim stops dialing instead: after a transport-level failure, every hook
except `UserPromptSubmit` skips the tunnel for the next 5 minutes.
`UserPromptSubmit` still dials every time — one line per submitted prompt while
the app is down is the honest signal that context is off, and it means your
first prompt after the app comes back is grounded immediately; that completed
exchange (any HTTP status, even a 401) clears the backoff for everything else.

## Set it up

In **Settings → Text Processing → Polishing → "Remote Claude Code over SSH"**,
type a name and your SSH host alias and press **Enroll…**. The app issues a
token, shows it once alongside every command below with a Copy button on each,
and binds the listener immediately — there is no relaunch step. The list in that
row shows each enrolled host, when it was last seen, and gives you **Update
Plugin…**, **Rotate Token**, **Revoke** and **Remove**.

The app hands you every command as copyable text, and can also do the two
steps for you — **only after showing you exactly what will happen and asking
you to confirm**: *Insert into ~/.ssh/config* previews the exact block (an
idempotent, marker-delimited splice; the rest of the file is never touched)
before atomically writing it, and *Run on SSH host* previews the commands
(token redacted) before running them through `ssh -o BatchMode=yes` with the
token fed over stdin — it never appears in any process's argument list, on
either machine. Nothing runs or is written without that explicit confirmation,
and the Copy buttons remain if you prefer to do it yourself.

The token is shown exactly once, because only its hash is stored. If you lose it,
rotate — that is what rotation is for. Then:

**1. Add the tunnel to `~/.ssh/config`:**

```
# BEGIN localvoxtral claude context (h1a2b3c4)
Host builder
    RemoteForward 28511 127.0.0.1:8473
    ExitOnForwardFailure no
# END localvoxtral claude context (h1a2b3c4)
```

`28511` is an example — the app generates *your* Mac's number and puts it in
both the block and the install command below. The two must always name the same
port: change one alone and the hooks post into a port nothing forwards, which
fails open, which looks exactly like nothing happening.

`ExitOnForwardFailure no` is deliberate and is the default. With `yes`, SSH
refuses to open the session at all when that port is already bound on the remote
— now only by your own second window to the same host. **A dictation nicety must
never cost you the shell.** The price of `no` is that a failed forward is
silent: the hooks get connection refused, fail open, and you simply get no
context. This is where you see whether it took:

```sh
ssh -v builder true 2>&1 | grep -q 'remote port forwarding failed' \
  && echo 'port 28511 is already held on builder' \
  || echo 'port 28511 forwards cleanly'
```

**2. Install the plugin on the remote host:**

```sh
ssh builder
claude plugin marketplace add T0mSIlver/localvoxtral
 claude plugin install localvoxtral-remote@localvoxtral --config 'token=<YOUR-TOKEN>' --config 'port=28511'
```

Note the leading space on the second line: with `HISTCONTROL=ignorespace` (bash)
or `setopt HIST_IGNORE_SPACE` (zsh) it keeps the token out of your shell history.
If it landed there anyway, rotate the token in the app — that is what rotation is
for.

Nothing else is installed. The marketplace add resolves the repository root's
`.claude-plugin/marketplace.json`; the plugin is two JSON files and two
POSIX-sh scripts — the hook shim, which needs only `sh` and `curl` on the
host, and the opt-in status-line renderer below, which needs only `sh`.

**3. Check it:**

```sh
claude plugin list
# From the remote, through the tunnel. 401 is the RIGHT answer here — it proves
# the tunnel is up and the app is answering. A connection error means the
# forward did not take.
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
  -d '{}' http://127.0.0.1:28511/v1/hook/SessionStart
```

## Connection indicator (opt-in status line)

The same bottom-bar indicator the local plugin offers, adapted to a host
where everything fails open by design: it tells you whether hooks from this
host are actually reaching localvoxtral on your Mac, instead of you finding
out by dictating into nothing.

It never dials the tunnel — a status line re-runs constantly, and every dial
against a live forward with no app behind it prints ssh's
`connect_to …: failed.` onto your terminal (the exact storm the shim's
backoff exists to end). Instead, `post.sh` records the outcome of each hook
delivery in a private one-line stamp, and a tiny renderer script turns that
into one fixed line. The indicator is exactly as fresh as this host's hook
traffic, which is also what re-runs the status line:

| Line | The last hook dial saw |
|---|---|
| `● localvoxtral connected` (green) | a 200 from the app, through the tunnel, within the last 15 minutes |
| `○ localvoxtral no recent hooks` (dim) | a 200 too — but a while ago. The green light expires rather than vouch for an app that may have gone away since; your next prompt dials and restores the truth either way |
| `○ localvoxtral unreachable` (dim) | no listener — tunnel down, Mac asleep, or the app not running |
| `○ localvoxtral token rejected` (yellow) | a 401 — rotate the token, or finish an interrupted rotation |
| `○ localvoxtral token not configured` (yellow) | the plugin has no `token` in its config at all |
| `○ localvoxtral not connected` (yellow) | some other completed HTTP error |
| `○ localvoxtral no hooks yet` (dim) | nothing — no hook has fired since this host last booted (the stamp lives in the runtime dir) |

Set it up on the **remote host** (the plugin ships the renderer; Claude Code's
versioned plugin cache is no place for a settings path, so copy it somewhere
stable):

```sh
cp ~/.claude/plugins/marketplaces/localvoxtral/integrations/claude-code/plugins/localvoxtral-remote/hooks/statusline.sh \
   ~/.claude/localvoxtral-statusline.sh
```

and in the host's `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "sh ~/.claude/localvoxtral-statusline.sh"
  }
}
```

The copy does not go stale in any way that matters: the renderer is
deliberately dumb (read stamp, print fixed string) and the smart half lives
in `post.sh`, which updates with the plugin. Like everything else on this
path, the renderer's stdout fails closed: the stamp's first token only ever
selects one of the strings above — no byte of the stamp file is ever
echoed into your status line. If you already run a status line on that host,
call the script from it and append its one line.

## Sessions nobody is sitting in front of

The tunnel exists only while *something* holds it, and normally that something
is your own `ssh builder` session. Anything the host starts on its own has no
such session:

* `claude remote-control` servers (systemd user services, lingering enabled)
* t3 code and other harnesses that spawn Claude Code into a worktree
* cron jobs, CI runners, anything headless

Those sessions publish hooks exactly like an interactive one — into a tunnel
that is not there. The result is silent, as always: dictation just is not
grounded.

So each enrolled host's row in Settings has **Keep the tunnel open**. With it
on, localvoxtral holds that host's forward itself:

```
ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ClearAllForwardings=yes \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -R 28511:127.0.0.1:8473 -- builder
```

It is off by default, per host — an app that opened SSH connections you did not
ask for would be a worse bug than the one it fixes. No token is involved
anywhere on this path; the credential lives in the remote plugin's config and
this process only carries bytes for it. Notes on the flags, since they differ
from the ones in your `~/.ssh/config` block deliberately:

* **`ExitOnForwardFailure=yes`** — the opposite of your config block, on
  purpose. Your block says `no` because a dictation nicety must never cost you
  a shell; this process *is* the nicety and nothing else, so a forward it
  cannot bind is a process with no reason to live. The exit is the signal: the
  row then reads **Port already held on the host.** with a **Retry** button,
  instead of pretending to work.
* **`ClearAllForwardings=yes`** — your config block already declares this
  forward for this alias. Without this flag the process would request the port
  twice, and the second request failing would kill it under the line above.
* **`ServerAliveInterval=30` / `ServerAliveCountMax=3`** — a NAT or a sleeping
  laptop otherwise leaves a half-dead connection holding the remote bind, which
  is precisely the state that makes the next connection fail.
* Restarts back off exponentially (0.5s, 1s, 2s… capped at 30s) and give up
  after five consecutive failures rather than hammering your SSH server
  forever. A **refused bind never retries at all** — something else holds that
  port and will keep holding it.

The listener binds first and the forwards start second, always: a forward
opened into an unbound port would give every hook connection-refused (silent,
fail-open) while making ssh print `connect_to … failed.` into your remote
terminal on every dial. Turning the toggle on or off takes effect immediately —
there is no relaunch step — and revoking a host, or quitting the app, stops its
forward.

## Updating an enrolled host

When localvoxtral ships a newer version of this plugin, an already-enrolled host
does **not** pick it up by re-running the setup commands. Verified on Claude Code
2.1.220:

- `claude plugin marketplace add …` on a marketplace it already has exits 0,
  says it is already on disk, and does **not** refresh the clone.
- `claude plugin install …` on an installed plugin exits 0, says it is already
  installed, and does **not** change the version. (It *does* apply a new
  `--config token=…`, which is why rotating a token reuses that same command.)

So the update is its own pair, and it keeps your token — `plugin update`
preserves the stored config:

```sh
ssh builder 'claude plugin marketplace update localvoxtral'
ssh builder 'claude plugin update localvoxtral-remote@localvoxtral'
# Only needed once, for a host enrolled before per-Mac ports existed — and
# harmless every time after. `plugin update` has no `--config`, and `install`
# merges config per key, so this sets the port without touching your token.
ssh builder "claude plugin install localvoxtral-remote@localvoxtral --config 'port=28511'"
```

Order matters: `plugin update` installs whatever the local marketplace clone
currently offers, so refreshing the clone first is what makes it an update at
all. In the app, each row in **Remote Claude Code over SSH** has an **Update
Plugin…** button that shows these two commands with a Copy button, and can run
them over SSH after you confirm. One-click runs against the **SSH alias you
enrolled with**, which is recorded with the host — the display name is never
used as a substitute, since the two are separate fields and can name different
machines. A host enrolled before localvoxtral recorded aliases has none on file:
its commands are copy-only (and so is its rotation sheet) until you re-enroll it.
Non-interactive SSH skips your login shell's
rc, so the app's version of these commands sets `PATH` to the usual `claude`
install locations first; add that yourself if `claude` is off the PATH a plain
`ssh host 'claude …'` sees.

## Uninstall and revoke

```sh
ssh builder 'claude plugin uninstall localvoxtral-remote@localvoxtral'
ssh builder 'claude plugin marketplace remove localvoxtral'
# then delete the BEGIN/END block from ~/.ssh/config
```

Then **revoke the host in localvoxtral**. That is the part that matters: the
token dies on your Mac, not on the remote. Uninstalling the plugin only stops
the host asking; revoking stops it being answered, immediately and without a
restart. Rotating instead of revoking issues a new token and kills the old one
with no grace period.

## What the token can and cannot do

A host presenting a valid token can give localvoxtral **remote context**. That is
all it can ever do. It cannot make the app read a local file, and this is not a
policy — the listener tags every session it accepts as `remote` regardless of
what the payload says, and a remote working directory is reduced to a bare label
that has no path accessor to hand a collector. A *local* process that connects to
the listener gets the same treatment: connecting there can only downgrade you.

Each host's sessions are namespaced under the host id its token authenticated,
so two hosts can never collide on a session id or forge each other's
sessions.

## What this does not protect against

Stated plainly, because a security note that only lists wins is not a threat
model.

**A malicious process running as YOU on the remote host.** This is not solvable
here and we do not claim otherwise. That process can already read
`~/.claude/`, which is where Claude Code keeps the plugin's configured token —
so it can read the token regardless of anything the app does, and it could
equally well read your source, your keys, and your shell history without
involving localvoxtral at all. Enrolling a host means trusting that host's user
account to the extent it is already trusted. What the token bounds is what a
host can do to *localvoxtral* (remote context only, never a local file read),
not what a compromised account can do to itself.

**Two Macs enrolled against one host.** Each Mac forwards its *own* port, so
they cannot contend for one remote bind — which used to be a silent
cross-delivery: the first connection kept the forward, the second connected
anyway (`ExitOnForwardFailure no`) and every event on that host, bearer token
included, went to the *first* Mac, which 401'd it, which the shim reads as a
completed exchange. Nothing reported it (issue #215). What per-Mac ports do
**not** change: one host runs one Claude Code install storing one `port`, so the
most recently installed config is the Mac that receives events. The other one
simply sees no traffic — visible single tenancy, not someone else's credential
in someone else's listener.

**A process on your Mac that squats 127.0.0.1:8473 before the app binds it.**
Loopback ports are first-come, first-served on macOS; there is no ownership. A
squatter cannot authenticate your hosts — it does not have the token hashes,
which never leave the 0600 host file — but it does receive whatever the remote
sends, including the bearer token itself, before anything rejects it. The app
therefore treats a bind conflict as a condition to *report*, not to route
around: Settings says the port is in use and offers Retry, rather than quietly
sliding to another port where you would never learn a squatter was there. If you
see that status, find the process (`lsof -nP -iTCP:8473 -sTCP:LISTEN`) before
assuming it is a stale copy of the app, and rotate the tokens of any host that
connected meanwhile.

**Anyone who can write your `~/.ssh/config`.** They can point the forward
somewhere else. That is true of every use of that file and is why the app only
ever writes it after showing you the exact block and getting your confirmation
— and only its own marker-delimited block, never the rest of the file.

## SSH to a host you have NOT enrolled

No enrollment, no tunnel, no token, no hooks. Your session is unchanged and the
pane stays screen-only and unjoined. Nothing about this feature is on by default:
with no enrolled host, the app binds no port at all. (An ENROLLED host's plain
`ssh` session does now join — on the connection itself; see "A plain `ssh host`
session" near the top.)

## What crosses the tunnel

The same allowlist as the local plugin, plus two additions:

* bounded, sanitized excerpts of `Read`/`Edit`/`Write` tool input and output
  (≤512 bytes each, ≤8 kept per session)
* an allowlisted set of environment values, sent as `X-Lvx-Env-*` request
  headers rather than in the body (the body stays Claude Code's event JSON
  byte-for-byte, because the host is not assumed to have `jq`):
  `HERDR_PANE_ID`, `HERDR_SOCKET_PATH`, `HERDR_SESSION`, `CMUX_SURFACE_ID`,
  `CMUX_SOCKET_PATH`, `CLAUDE_CODE_BRIDGE_SESSION_ID`, `TMUX`, `TMUX_PANE`,
  `STY`, `ZELLIJ`, `SSH_TTY`, `SSH_CONNECTION`, `LC_LVX_TTY`, and the shim's own
  parent pid. Each is sent only
  if it is non-empty, at most 200 characters, and made purely of ASCII
  alphanumerics plus `._:/@+,=%-`; anything else is dropped rather than
  escaped. `SSH_CONNECTION` is the one value the shim reshapes: `sshd` writes
  its four fields separated by spaces, and a space could end a header line, so
  the shim re-joins them with commas — and drops the value entirely if it is
  not exactly four fields. They tell the
  app WHERE the session runs so it can tell whether the pane you are dictating
  into is this one — never what it contains. The rest of the environment is not
  read, and these values are labels on the Mac: they can never become a local
  path, a socket the app dials, or a process it probes.

These exist only for remote sessions. A local session's files are on your Mac
and the app reads them properly; a remote session's are on a machine the app has
no business reaching into, so what the hook quotes is all it will ever know.
Every excerpt is stripped of control characters, C1 escapes, bidi overrides, and
zero-width characters before it is stored — foreign text is treated as text, never
as something that can act.

Transcript contents, `Bash` command strings, and anything claiming to be trusted
still never cross, exactly as locally.
