# localvoxtral — Claude Code plugin

This Claude Code plugin tells the localvoxtral dictation app what your Claude
Code session is doing, so dictation can recognize technical terms it would
otherwise mishear: filenames, symbols, the thing you asked for last turn.

This directory is a **local Claude Code marketplace** and the source of truth
in the repo. `scripts/package_app.sh` copies it into the app bundle at
`Contents/Resources/claude-code-marketplace`, so an installed app can register it
without a checkout or a separate marketplace repository.

## What it does

The plugin declares **hooks only**. It ships no skill, slash command or agent,
so it uses no Claude tokens, adds no latency to your turn, and puts nothing in
Claude's context. It only passes data to the app.
One opt-in feature outside the plugin does spend tokens. With **Ask the coding
agent for each new project's terms** on, the app runs its own read-only
`claude -p` once per project, never in your session. That costs about
$0.03–0.12, or the same share of a Claude.ai plan's quota (see
[Terms from your coding agent](../../docs/dictation.md#terms-from-your-coding-agent)).
On an enrolled host, `localvoxtral-remote` runs that `claude -p` on the host
instead, when the Mac asks for a session's project
([Terms from the coding agent on a host](../../docs/remote-claude-context.md#terms-from-the-coding-agent-on-a-host)).

On each hook event, Claude Code runs `hooks/publish.sh`. It finds the
`localvoxtral-claude-hook` publisher and runs it as a **child process**, not
with `exec`. With `exec`, the publisher would replace the shim, and a publisher
that cannot start at all (wrong architecture, quarantined bundle, missing dyld
dependency) would return its failure as the hook's exit code. You would see
an error on your turn, which fail-open exists to prevent. The shim stays alive
to swallow that failure. The publisher writes one bounded NDJSON line to a
private UNIX socket owned by the app and exits.

| Hook | What localvoxtral learns |
|---|---|
| `SessionStart` | a session exists; its cwd and terminal |
| `UserPromptSubmit` | your latest prompt (the "prior prompt" when you next dictate) |
| `CwdChanged` | the session moved to another directory |
| `PostToolUse` (`Read`/`Edit`/`Write`/`NotebookEdit`) | which files were just read or edited |
| `Stop` | the turn finished |
| `SessionEnd` | the session is gone (the app evicts it immediately) |

There is no `FileChanged` hook. Claude Code fires it only for a hook that
declares `watchPaths`, and `PostToolUse` already reports every file the model
touches without watching your whole tree.

## Which terminal am I dictating into?

Every mechanism below matches ONE identifier your session's own hooks
published against the SAME identifier read off the window you are looking at.
No fallback guesses, and **no join reads your window title**. That mechanism
was removed in September 2026 (see "What was removed" below). Repo vocabulary,
a separate opt-in feature, still reads a terminal title to find a git root,
but it never picks a Claude session.

**TTY join (the default for Ghostty ≥ 1.4 [currently the tip channel], iTerm2,
and Terminal.app).** The hooks report the session's controlling terminal
device. At dictation start, the app asks the focused terminal for its focused
pane's `tty` over AppleScript (each terminal asks for Automation consent once).
Device equality is exact, works mid-response, and tells two sessions in the
same repo apart. Inside a [herdr](https://herdr.dev) multiplexer session the
TTY can't match, because herdr puts its own PTY in front of each pane. There the
app asks herdr's own socket for the focused pane and joins on the exact pane
id. Any ambiguity, including two live herdr sessions, attaches nothing. Other
terminals don't join at all rather than join halfway.

**cmux surface join (opt-in).** [cmux](https://github.com/manaflow-ai/cmux)
draws its terminal with libghostty into a custom view. It exposes no
accessible text and no scripting dictionary, so neither the TTY read nor any
screen read works there. Instead the app asks cmux's own automation socket
which surface is focused. It matches that surface id against the one cmux
injected into the session's environment, including into shells opened with
`cmux ssh`, which is one of the ways a REMOTE session can join. That surface is
also the only screen context the app can read, fetched per surface
(`surface.read_text`: the visible viewport, never the scrollback).

cmux's socket refuses outside clients by default, so set up two things:

1. In **cmux → Settings → Automation**, set the socket mode to **Password**
   and choose a socket password. (The default `cmuxOnly` mode admits only
   processes cmux itself started, which localvoxtral is not. `allowAll` is
   developer-only and is not required.)
 2. In localvoxtral, enable **Settings → Terminals → cmux → "Join sessions
    in cmux"** and enter the same password in **Socket password**. It is stored in your Keychain and sent only to cmux's
   local socket; saving an empty field removes the stored password.

If the socket refuses the app, the settings row says
`cmux socket requires password mode.` and the dictation joins nothing. A
failed join attaches nothing.

This join has two limits. First, the app cross-checks the surface's terminal
device against the one your session reported, and **abstains when either side
does not report one**. opencode's server half never claims a pane, so opencode
inside cmux does not join this way. Second, a session on a remote host joins
only while cmux reports that surface's workspace as a live `cmux ssh`
workspace, so a stale surface id from an earlier remote session cannot attach
to whatever you are looking at now.

**Browser tab join (Claude Code "Remote Control").** A Remote Control session
runs the `claude` process on one of your machines, with
[claude.ai/code](https://claude.ai/code) in a browser as its UI. There is no
pane, tty or title to join on. Since Claude Code 2.1.199 the hooks of such a
session carry `CLAUDE_CODE_BRIDGE_SESSION_ID`, whose value is exactly the
`session_…` part of that browser URL. When the frontmost app is a browser, the
app reads its focused tab's URL over AppleScript and requires the id to equal
what the session's own hooks reported. Local and remote (SSH) sessions can
both join this way, because Anthropic's bridge allocates the id and it is
globally unique, unlike a tty or pane id. Claude Code REMOVES the variable
when the Remote Control connection ends, so the join expires on the session's
next hook.

**Claude Desktop join.** Claude Desktop's Code tab shows each Claude Code
session in a web view at `https://claude.ai/epitaxy/local_…`, and exports the
same `local_…` id to the session as `CLAUDE_CODE_HOST_SESSION_ID`. When Claude
Desktop is frontmost, the app reads the address of the web view that holds
keyboard focus over Accessibility and matches the id against what the
session's hooks reported. Sessions the desktop app runs on this Mac join
through this plugin. Sessions it runs on an ssh host join through
`localvoxtral-remote` (≥ 1.11.0) on that host and need **Keep the tunnel
open** (see [Sessions nobody is sitting in front of](#sessions-nobody-is-sitting-in-front-of)),
because Claude Desktop's own ssh never carries the tunnel. Host setup turns it
on when it finds Claude Desktop on the host. Like the browser join, it reads
no screen and runs only with Claude repo context on. The Code tab does not
show Claude Code's status line, so the status-line indicator never appears
there. The overlay badge and the log's `Claude join outcome` line tell you
whether a dictation joined.

Every process inside a desktop session inherits that variable, so a
`claude -p` started from one used to report the same id and make the join
abstain. On a Linux host, `localvoxtral-remote` ≥ 1.14.0 sends the id only
from a Claude process whose parent is Claude Desktop's daemon
(`~/.claude/remote/srv/<hash>/server`). A host without `/proc` still sends it
from every hook. A session that reports the id stays joinable for seven days
without a hook, not four hours, because it sits idle while its window stays
open.

Supported browsers are **Google Chrome, Brave, and Safari**. Each needs its
OWN Automation grant the first time it is used (System Settings → Privacy &
Security → Automation → localvoxtral). The app asks for the grant only while
**Settings → Context → "Send diff, recent files and last prompt"** is on,
since that is the only feature a browser join serves. Firefox is not supported
because it exposes no AppleScript access to the focused tab's URL. A browser
join never reads anything on your screen: a web page is not a terminal grid,
and there is no verified way to capture one tab. It attaches only the
session's own off-screen context, plus the repository for a local session,
the same as a terminal join.

### A plain `ssh host` session

A Claude Code session in an ordinary `ssh` shell on an **enrolled** host, with
no herdr, cmux or Remote Control, joins on the **TCP connection** your
terminal holds.

The app tries two ways to identify your window, in this order.

### 1. The tty echo (works through jump hosts and `ControlMaster`)

**The app can set this up.** Go to Settings → Remote hosts → Plain SSH →
**Set Up…** next to "Terminal setup". It shows one consent sentence naming the
shell file, links here for details, and has a **Remove**. Once this app's
block is in the file, the row offers only **Remove**. A block an older app
wrote brings back **Update…**, which replaces that block rather than adding a
second copy. The row also reports whether a remote session has arrived
carrying the value, which you cannot tell from the file.

It refuses to write through a symlink. If your `~/.zshrc` is a link into a
dotfiles repo, an atomic write would replace the link and detach your setup.
The row says so and links here instead of offering a button, and you paste
the block yourself.

To do it by hand, add this to your shell's rc file **on your Mac**:

```sh
if [ -z "${LC_LVX_TTY:-}" ] && [ -z "${SSH_TTY:-}" ]; then
  case "$(tty 2>/dev/null)" in /dev/*) LC_LVX_TTY="$(tty)"; export LC_LVX_TTY ;; esac
fi
```

That publishes the terminal's own device name. `ssh` carries it into the
session with `SendEnv` (the enrollment block adds that line, and most
ssh_configs already send `LC_*`). `sshd` accepts it because its stock config
is `AcceptEnv LANG LC_*`. localvoxtral then joins by comparing it against the
tty of the window it can see. iTerm2 uses the same `LC_` mechanism for
`LC_TERMINAL`, and locale libraries ignore names they do not know.

Each part of that block is needed. Shorter versions were measured to fail:

* `SSH_TTY` unset means "only on this Mac", and the `LC_LVX_TTY` check means
  "do not overwrite what was sent to me". Without them, the same rc file on a
  remote host makes the remote shell replace your Mac's tty with its own.
  Nothing matches, and because the variable is then *set*, no later shell
  fixes it.
* The `case` handles shells with no terminal, where `tty` prints `not a tty`.
  The first draft of this line exported that string. The shim's charset drops
  it, but it breaks the "already set" guard for every shell that inherits it.
* It is an `if` block rather than a one-line `&&` chain because the chain's
  status becomes the rc file's status. Measured: `bash --norc -c 'set -e;
  source rc; echo SURVIVED'` printed nothing and exited 1 with the chain, and
  printed `SURVIVED` with exit 0 using the block above. `bash` sources
  `~/.bashrc` non-interactively for shells it believes sshd started, so the
  chain version could break `ssh host script` for anyone syncing dotfiles.

**Why this one and not the connection below:** ssh carries environment per
SESSION, not per connection. So it works through `ProxyJump` (where your Mac
holds no connection to the destination) and `ControlMaster` (where several
windows share one connection), the two setups the connection match cannot
handle.

If your host's `sshd` refuses `LC_*` (rare, but hardened configs do), add
this there and reload sshd:

```
AcceptEnv LC_LVX_TTY
```

The one thing that can go wrong is the value not arriving. To check it, ask
the remote side, not `--probe-surface`. That verb runs as a separate one-shot
process with its own empty session registry. It can tell you which join method
ran and why the window was or was not identified, but it never has the live
sessions this check needs:

```sh
ssh sandbox-vpn 'echo "[$LC_LVX_TTY]"'   # from a window where the rc line ran
```

An empty answer means the variable is not crossing. Check the rc line,
`SendEnv`, or a hardened `AcceptEnv`. On a dogfood build, `registry list`
reports `remoteLocalTTY` per session, the same fact seen from the app.

### 2. The connection (zero setup, no jump host)

`sshd` puts `$SSH_CONNECTION` into every session it starts: the client address
and port, then the server address and port. The remote plugin publishes it. On
your Mac, the app finds the `ssh` process running in your focused terminal,
reads that process's established socket from the kernel, and requires the two
to be the
same connection — same client port, same server address, same server port.
The client port is an ephemeral number your Mac's kernel picked, and only the
machine on the other end of that connection learns it.

Either way the app attaches the session block and, for a local session,
repository context. It never attaches your screen: a plain ssh shell's
scrollback is your whole remote session, not one pane, so neither join may
capture it.

Neither joins in these cases:

* **through a jump host, without the rc line above** (`ssh -J`, `ProxyJump`,
  or a `ProxyCommand`). Your Mac's socket goes to the jump host, while the
  machine you land on sees the jump host's port. They are two different
  connections, and only the jump host knows how they pair up, which it cannot
  tell you without root there. The app says so ("this connection goes through
  a jump host"). **The tty echo works here**, so set it up if you jump.
* **inside tmux, screen or zellij**. A multiplexer server keeps the
  `$SSH_CONNECTION` of the connection that STARTED it, so a session in a pane
  can report a connection that belongs to another of your windows. This was
  measured. herdr and cmux have their own joins, which bind the pane rather
  than the connection. tmux, screen and zellij have none.
* **when your `~/.ssh/config` may be sharing one connection**
  (`ControlMaster`), again only without the rc line. Several terminals then
  run over one TCP connection and all report the same `$SSH_CONNECTION`, so it
  no longer identifies a window. The app detects this two ways, each with its
  own reason in `--probe-surface`: the window you are dictating into holds no
  connection of its own (it is a mux client), or another `ssh` session to the
  same host does. The tty echo still works, because ssh gives each session its
  own environment even over a shared connection.
* **when anything is ambiguous**: two sessions reporting the same connection,
  two enrolled hosts matching the destination, an unreadable process table.

If nothing joins and you expect it to, check the remote plugin version. This
needs **1.7.0 or newer** on the remote host (`claude plugin update
localvoxtral-remote`). `localvoxtral --probe-surface` names the exact reason.
After adding the rc block, by hand or from Settings, open a NEW terminal
window and a NEW ssh session, because a session's environment is fixed when
it starts.

### What was removed (September 2026)

Until then there was one more mechanism. The app allocated an `lvx-<hex>`
marker per session and returned it in the hook reply. Claude Code wrote it
into the window title as an OSC 2 escape sequence, where a focused-window read
could find it. A **Local Claude title fallback** setting turned it on for
local sessions (default off) and asked you to export
`CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`. It was the only join an ordinary
`ssh host` session had.

All of it is gone: the marker, the setting, the escape sequence, the
`terminalSequence` field in the hook reply, and the tmux/screen title
passthrough advice. **The hooks now print nothing at all, ever**, and neither
the local socket nor the remote listener has any field that could put a byte
on your terminal. Everything rewrites a window title. Claude Code writes its
own conversation titles over it mid-turn, herdr and cmux rewrite their pane
titles, and you may rename a window yourself. So a marker in a title showed
where a session used to be, not what your screen shows now.

This was measured. On the owner's setup (2026-09-05), a herdr pane's title
was polled at ~325 Hz for 69.4 s across a hook event. The marker was the title
for 0.88 s in total, **1.26 %** of the time, and Claude Code's own
conversation title held it the rest of the time. A remote-herdr join that had
everything else right still failed on that check, unless the user had
exported `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`, which made it succeed
immediately. The check passed about one time in a hundred, so it could not
serve as a second binding.

**What this cost you, and what replaced it:** for one release a plain
`ssh host` session with no herdr, cmux or Remote Control had no join at all.
It joins again, on the connection itself (see "A plain `ssh host` session"
above). Nothing else changed: local sessions join by tty, herdr panes by pane
id (local and remote), cmux by surface id (local and remote), Remote Control
by bridge session id.

**If you had the setting on**, the app ignores the stored value. There is
nothing to migrate, and you can drop
`CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` from your shell profile.

## Install / update / uninstall

In the app, press **Settings → Claude Code → Plugin → Install**. That button
registers the bundled marketplace, installs the plugin, and reports one short
line. Nothing is installed until you press it.

Once installed, the plugin stays current on its own. At launch the app runs
`claude plugin update` on an installed plugin older than the one it ships.
That command never uninstalls, so a failed update leaves the old plugin
working. The app also repoints
`~/Library/Application Support/localvoxtral/claude/publisher` at its own
publisher binary. The shim tries that link before the install-time
`publisher_path`, so moving the app needs no reinstall. The row shows
**Update** only when that launch-time update failed, and no install button
while the plugin is current.

The app registers a mirror of this directory at
`~/Library/Application Support/localvoxtral/claude/marketplace`, not the app
bundle's own copy, and refreshes the mirror at launch whenever its contents
differ. Claude Code stores the marketplace as the path it was given and
re-reads it at every session start. Registering a path inside the bundle
would tie your Claude Code to wherever that app was: a `try-pr.sh` build under
`/private/tmp`, a disk image, a folder you later renamed. When that path goes
away, the plugin stops loading (`Marketplace
localvoxtral failed to load: cache-miss`, no hooks in any session), and the
only sign is a half-filled `lvx ◐` status line. The row then reads
**Installed, but not loading** and offers **Repair**. Launch does the same
repair on its own with one `claude plugin marketplace add`, which on a
directory source repoints the name (verified on Claude Code 2.1.x). It leaves
the installed plugin, its `publisher_path` and its cache untouched.

Launch only takes over a registration that cannot keep working: one that is
already gone, one inside an app bundle, or one Claude Code reports as not
loading. **A marketplace you registered from a checkout is left alone**,
because that is how you edit the shim and see the edit.

Everything the app does goes through Claude Code's own plugin CLI.

**Plugin install and uninstall never touch `~/.claude/settings.json`.**
That file is yours and Claude Code owns its schema. The CLI is the supported
interface, and third-party apps editing the file corrupt setups during
unrelated upgrades. The one exception is the next row in Settings: the opt-in
status-line installer writes only the `statusLine` key, after a one-sentence
consent. Over a status line you wrote yourself it writes only through
**Combine…**, which keeps your command and puts it back on **Remove** (see
below).

To run the commands yourself, use these, which are the same ones the button
runs. The only difference is `--config publisher_path=…`. The app knows where
its own publisher binary is and passes that path, so the plugin works for an
app in `~/Applications`, on a mounted volume, or in a dev build. Without it,
the shim falls back to guessing `/Applications` and `~/Applications` (see the
environment table below).

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

Update (re-reads the marketplace, then reinstalls). This reinstalls rather
than running `claude plugin update` because `update` accepts no `--config`.
An update that cannot reset `publisher_path` leaves the shim on a stale path
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

## Telling Claude Code you dictate

**Settings → Claude Code → Tell Claude Code you dictate → Add** puts a short
note in `~/.claude/CLAUDE.md` saying your prompts come from speech-to-text.
See [Telling the agent you dictate](../../docs/coding-agents.md#telling-the-agent-you-dictate).

## Connection indicator (opt-in status line)

Claude Code's bottom bar can show whether localvoxtral is connected to this
session.

In the app, use **Settings → Claude Code → Status line → Set Up…**. A
one-sentence consent names `~/.claude/settings.json`, and **Details** opens
this section. The app writes one `statusLine` entry pointing at its bundled
`localvoxtral-claude-hook --statusline`. Everything else in
`~/.claude/settings.json` is kept, although the app rewrites the JSON with
sorted keys and normalized formatting. **Remove** takes the entry back out
and deletes the file when nothing else is in it.

If you already have your own status line, the row offers **Combine…**
instead. The app writes `~/.claude/localvoxtral-statusline.sh`, which runs
your command and then the indicator on the same line, and points
`statusLine` at it. The script keeps your command, so **Remove** puts it back
exactly. If you delete the app, the script skips the indicator and your own
line keeps working. The app never edits a script it did not write: if you
change the combined script by hand, the row says so and offers no button.

To set it up by hand, add the same entry the button writes. Claude Code has
no plugin-owned status line, so it lives in your own settings either way. The
publisher binary's `--statusline` mode reads the status-line payload Claude
Code pipes in, asks the app's socket whether THIS session (by `session_id`)
is live in its registry, and prints one fixed line:

| Line | Meaning |
|---|---|
| `lvx ●` (green) | the app received this session's hooks |
| `lvx ◐` (yellow) | the app is listening but does not recognize this session |
| `lvx ○` (grey) | nothing is listening on the local socket |
| `lvx ✕` (red) | remote only: the Mac rejected the host token |

With `NO_COLOR` set or `TERM=dumb`, the same glyphs render without color.

In `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook --statusline"
  }
}
```

For `~/Applications` or a dev build, adjust the path. It is the same binary
`publisher_path` points at. Unlike the plugin, the status line does not follow
the app when it moves, because the path is saved in your settings. The Status
line row compares that path with the running app's, so after a move it shows
**Update…**, whether or not the old copy is still on disk. While the entry
points at this app, the row offers only **Remove**.

If you already have a status line, keep it and append ours. Buffer stdin once
and feed it to both, for example:

```sh
#!/bin/sh
input=$(cat)
printf '%s' "$input" | ~/.claude/my-statusline.sh
printf '%s' "$input" | /Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook --statusline
```

The query is read-only: asking never creates or refreshes a session. The
strings above are compile-time constants, so nothing read off the socket ever
reaches your terminal. A payload without a usable `session_id` prints nothing
rather than guessing.

## Fail-open, always

If localvoxtral is not running, not installed, or its socket is absent, the hook
drains stdin, prints nothing, and exits 0. The same goes for a missing
publisher binary, a full socket, or a slow app: the publisher gives up after
~250 ms.

Your Claude session never stalls, warns or fails because dictation context was
unavailable. Nothing in this plugin can block a turn.

## What crosses the socket

Only what this allowlist names:

* the event name, session id, timestamp, and cwd
* your prompt text (`UserPromptSubmit` only)
* absolute file paths from the tools above
* safe process metadata: pid, ppid, controlling TTY, `$TERM_PROGRAM`, and the
  multiplexer and bridge handles that say which pane the session lives in:
  `$HERDR_PANE_ID`, `$HERDR_SOCKET_PATH`, `$CMUX_SURFACE_ID`,
  `$CMUX_SOCKET_PATH`, `$CLAUDE_CODE_BRIDGE_SESSION_ID`,
  `$CLAUDE_CODE_HOST_SESSION_ID`. Never the rest of the environment.

These never cross:

* **transcript contents**. The publisher drops `transcript_path` entirely, so
  there is nothing to scrape and no pointer to it.
* **file contents**: `Write.content`, `Edit.new_string`, `Read` output.
* **command strings**. The plugin does not subscribe to `Bash`.
* **anything claiming to be trusted**. The app decides trust from UNIX peer
  credentials, never from a field on the wire.

Every field is length-capped at both ends. Hook content is never logged.

## Configuration

| Setting | Purpose |
|---|---|
| `~/Library/Application Support/localvoxtral/claude/publisher` | Link to the publisher, repointed by the app on every launch. The shim tries it right after `LOCALVOXTRAL_CLAUDE_HOOK_BIN`. |
| `publisher_path` (plugin userConfig) | Absolute path to the publisher. localvoxtral sets this for you at install time; the shim uses it when the link above is missing or dangling. The shim reads it as `CLAUDE_PLUGIN_OPTION_PUBLISHER_PATH`. |
| `LOCALVOXTRAL_CLAUDE_SOCKET` | Socket path. Defaults to `~/Library/Application Support/localvoxtral/run/claude-context.sock` (macOS) or `$XDG_RUNTIME_DIR/localvoxtral/claude-context.sock` (Linux). |
| `LOCALVOXTRAL_CLAUDE_HOOK_BIN` | Path to the publisher; overrides everything else. |

---

# Remote / SSH sessions — the `localvoxtral-remote` plugin

When you dictate into a Claude Code session running on another machine over SSH,
the local plugin cannot help, because that host has no app and no socket to
write to. `localvoxtral-remote`, the second plugin in this marketplace, covers
that case.

**Install it on the REMOTE host, not on your Mac.** The two plugins have
different transports and different trust models, and a plugin installed on
the wrong side fails open silently forever.

| | `localvoxtral` | `localvoxtral-remote` |
|---|---|---|
| Install on | the Mac running the app | the remote host |
| Transport | AF_UNIX socket, `command` hook + shim | HTTP over an SSH `RemoteForward`, `command` hook + `curl` shim |
| Authentication | kernel-verified peer UID | per-host bearer token you issue in the app |
| Needs on that host | the app's publisher binary | POSIX `sh` and `curl` only, no Python, no `jq`, no `nc`, no Node, no localvoxtral binary |
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

The remote plugin subscribes to `SessionStart`, `UserPromptSubmit`, `Stop`,
`CwdChanged`, `PostToolUse` and `SessionEnd`, so the app sees a new remote
session before its first prompt. Otherwise the events match the local table
above.

Each hook runs the plugin's bundled POSIX-sh shim (`hooks/post.sh`), which
curls the hook's event JSON to `http://127.0.0.1:<your Mac's port>/v1/hook/<Event>`
on the *remote* loopback. OpenSSH's `RemoteForward` carries that to your Mac's
loopback port 8473, where the app listens. The app **allocates that remote
port per Mac** (a stable number in 28473–30472, derived from a per-install
identity), so two Macs enrolled against one host never ask for the same bind
(see "Two Macs, one host" below).

The shim reads the token and the port from the
`CLAUDE_PLUGIN_OPTION_TOKEN` / `CLAUDE_PLUGIN_OPTION_PORT` environment variables
Claude Code injects into command-hook subprocesses, and passes the token to curl through a private tempfile
(`--header @file`) so it never appears in any process's argument list. It
needs only `sh` and `curl` on the host. It fails open, silently and printing
nothing, when either is missing, the token is unset, the tunnel is down, or
the app does not answer within a second. Declarative `http` hooks cannot do
this job. Claude Code expands their header `${VAR}`s from the process
environment only and never injects plugin userConfig options there, so an
http hook would always authenticate as an empty `Bearer` and be refused.

The app answers every hook with the same fixed body, `{"suppressOutput":true}`.
An `X-Lvx-Session` response header says `joined` or `unknown`, and `post.sh`
stores that verdict for the session's status line. `joined` means the app
recorded the hook for that session, not that a dictation will join it. That
also needs a join method that recognizes the window you dictate into. The
shim still prints only the fixed body.

Each post also sends an `X-Lvx-Plugin-Version` header with the plugin's own
version, a constant baked into `post.sh`. The app checks that it has a strict
numeric shape. It records the version for that host only once it fully
accepts the request, at the same points it notes the "last seen" time, so a
request the revocation re-check refuses records nothing. The app uses it for
one thing: showing the fixed "Update available" line and a prominent
**Update Host…** button in Settings when the host's plugin is older than the
app's. The record keeps the highest version any of the host's hooks reported
since the app launched. Claude Code applies a plugin update only when a
session restarts, so sessions already running keep the old plugin's shim and
send no header. Their hooks must not clear the flag for an update that has
already landed. Nothing else opens a port, and nothing is reachable from your
LAN.

## When the app is not running on your Mac

The shim's own failures are always silent, but one message is out of its
reach. While an SSH session holds the forward and localvoxtral is not running,
each dial makes **ssh itself, on your Mac**, print
`connect_to 127.0.0.1 port 8473: failed.`
onto the terminal, over whatever is drawn there (a herdr pane, the Claude Code
screen), once per hook. That stderr belongs to another process on another
machine, so no redirect in the plugin can reach it. Silencing it in ssh would
take `LogLevel QUIET`, which also hides host-key warnings, and the plugin
won't make that trade for you.

So the shim stops dialing instead. After a transport-level failure, every hook
except `UserPromptSubmit`, `SessionStart` and `SessionEnd` skips the tunnel for
the next 5 minutes.
`UserPromptSubmit` still dials every time. One line per submitted prompt while
the app is down tells you context is off, and your first prompt after the app
comes back gets context immediately. That completed exchange (any HTTP status,
even a 401) clears the backoff for everything else.
`SessionStart` and `SessionEnd` also dial every time. They fire once per
session and every session on the host shares the backoff, so skipping them
hid sessions started in those 5 minutes and kept ended ones joinable.

## Set it up

In **Settings → Remote hosts → Add host**, type a name and your SSH host alias
and press **Enroll…**. The app issues a token and binds the listener
immediately, with no relaunch. It then opens a sheet whose **Set Up** runs
every step in one consented flow, in order, and verifies each one:

1. the SSH config block on this Mac
2. the shell export block
3. the plugin install or update on the host, when Claude Code is there
4. the `LC_LVX_TTY` crossing check
5. the herdr agents-panel row, when herdr is installed
6. the Mistral Vibe hooks, when Vibe is there
7. the final Check Setup

It stops at the first failure and gives the exact fix. **Update Host…** in an
enrolled host's row runs the same flow. The sheet shows no token, command, or
file contents. Its **Details** link opens the complete command reference in
[docs/remote-claude-context.md](../../docs/remote-claude-context.md#how-enrollment-works).

That row lists each enrolled host and when it was last seen, with
**Update Host…**, **Rotate Token**, **Revoke** and **Remove**.
**Update Host…** hides once, since launch, the host has reported the app's
plugin version (and the app's Vibe hooks version, where the host has them),
and this Mac's SSH config and shell startup blocks are in place. At that point
the run would change nothing it can check from here. A finished update closes
its panel. The button also hides on a revoked host, and **Rotate Token**
brings it back.

The consent sentence names every local file and the SSH alias the flow may
touch. Nothing runs or is written before **Set Up**. The app runs remote work
through `ssh -o BatchMode=yes` and feeds the token over the remote shell's
stdin, so it never appears in any process's argument list **on your Mac**. On
the host it does, briefly. `claude plugin install` takes its config as a flag
and has no stdin path, so the token is in that one command's argv while it
runs. Afterwards it sits in the plugin's userConfig under `~/.claude`,
readable by anything running as you there. That holds whether the app runs
the command or you paste it (see
[docs/remote-claude-context.md](../../docs/remote-claude-context.md#3-a-token)).
The sheet reports one line per step instead of raw output.
[docs/remote-claude-context.md](../../docs/remote-claude-context.md) is the
full reference: what the token authorizes, the per-Mac port, multiplexer
limits, uninstalling.

Settings never shows the token, and this Mac stores only its hash. If setup
is interrupted, rotate the token and run **Set Up** again. The steps are:

**1. Add the tunnel to `~/.ssh/config`:**

```
# BEGIN localvoxtral claude context (h1a2b3c4)
Host builder
    RemoteForward 28511 127.0.0.1:8473
    ExitOnForwardFailure no
    SendEnv LC_LVX_TTY
# END localvoxtral claude context (h1a2b3c4)
```

`28511` is an example. The app generates *your* Mac's number and puts it in
both the block and the install command below. The two must always name the
same port. Change one alone and the hooks post into a port nothing forwards,
which fails open and looks exactly like nothing happening.

`ExitOnForwardFailure no` is the default. With `yes`, SSH refuses to open the
session at all when that port is already bound on the remote, which now
happens only when your own second window connects to the same host.
**Dictation context must never cost you the shell.** The price of `no` is that
a failed forward is silent: the hooks get connection refused, fail open, and
you get no context. Step 4 exists to catch that.

**2. Install the plugin on the remote host:**

```sh
ssh builder
claude plugin marketplace add T0mSIlver/localvoxtral
 claude plugin install localvoxtral-remote@localvoxtral --config 'token=<YOUR-TOKEN>' --config 'port=28511'
```

Note the leading space on the second line: with `HISTCONTROL=ignorespace` (bash)
or `setopt HIST_IGNORE_SPACE` (zsh) it keeps the token out of your shell history.
If it landed there anyway, rotate the token in the app.

Nothing else is installed. The marketplace add resolves the repository root's
`.claude-plugin/marketplace.json`. The plugin is two JSON files and two
POSIX-sh scripts: the hook shim, which needs only `sh` and `curl` on the
host, and the opt-in status-line renderer below, which needs only `sh`.

**3. Show the dictation indicator in herdr (optional):**

After you confirm, the app appends the agents-panel row below to the remote
host's herdr config. It does so only when the config has no agents table and
no rows key, and otherwise leaves the file unchanged:

```toml
[ui.sidebar.agents]
rows = [["state_icon", "workspace", "tab"], ["agent"], [{ token = "$lvmark", dim = true }]]
```

**4. Check it: press "Check Setup" in the sheet.**

The app runs two read-only checks over SSH and reports what they mean:

* **Connection & tunnel.** The app sends an unauthenticated
  `POST /v1/hook/SessionStart` through the forward. HTTP 401 is the pass,
  because the refusal proves the request crossed the tunnel and localvoxtral
  answered. That holds only when this Mac's listener is bound, which the app
  also knows. A 401 that arrives while the app's bind failed came from
  whatever else holds the port, and the app reports it as such. No answer
  means no live tunnel right now. A host with no `curl` gets its own verdict,
  because the plugin's shim is a curl one-liner.
* **Claude plugin on the host.** The app runs `claude plugin list` behind a
  PATH prefix, since a non-interactive SSH command skips your login rc. "Not
  installed" and "Claude Code was not found here" are separate answers with
  separate fixes.

The app shows, logs and copies no probe output, only verdicts it composed.
`claude plugin list` prints the plugin's stored config, and after a rotation
that holds a token this app no longer knows and so could not redact.

To run the equivalent commands by hand, see
[docs/remote-claude-context.md](../../docs/remote-claude-context.md#checking-the-setup).

## Connection indicator (opt-in status line)

This is the local plugin's bottom-bar indicator, adapted to a host where
everything fails open. It tells you whether hooks from this host reach
localvoxtral on your Mac, so you don't find out by dictating into nothing.

It never dials the tunnel. A status line re-runs constantly, and every dial
against a live forward with no app behind it prints ssh's
`connect_to …: failed.` onto your terminal, the flood of messages the shim's
backoff exists to stop. Instead, `post.sh` records private host and
per-session stamps. The renderer checks for both a recent connection and this
session's join:

| Line | Meaning |
|---|---|
| `lvx ●` (green) | the Mac holds this session |
| `lvx ◐` (yellow) | the Mac answers but does not hold this session |
| `lvx ○` (grey) | no recent answer, listener, or tunnel |
| `lvx ✕` (red) | the token is missing or rejected, or another HTTP error occurred |

With `NO_COLOR` set or `TERM=dumb`, the same glyphs render without color.

Set it up on the **remote host**. The plugin ships the renderer, but Claude
Code's plugin cache path changes with each version, so copy the script
somewhere stable:

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

The renderer prints only one of the fixed strings above and never echoes a
byte from the payload or either stamp. If you already run a status line on
that host, call the script from it and append its one line.

## Sessions nobody is sitting in front of

The tunnel exists only while *something* holds it, normally your own
`ssh builder` session. Anything the host starts on its own has no such
session:

* Claude Desktop sessions on the host: Desktop's ssh runs with
  `ClearAllForwardings=yes` and never carries the forward, so a host you
  reach only from Desktop has no tunnel at all. Host setup detects Desktop
  (`~/.claude/remote/srv` exists on the host) and turns the toggle below on.
* `claude remote-control` servers (systemd user services, lingering enabled)
* t3 code and other harnesses that spawn Claude Code into a worktree
* cron jobs, CI runners, anything headless
* sessions you only ever look at through a herdr 0.9 federated view. The
  link herdr holds is not a shell of yours, and it may have lost the forward
  to an earlier session that has since ended (first session wins, see
  [Sessions](../../docs/remote-claude-context.md#a-second-session-to-the-same-host))

Those sessions publish hooks like an interactive one, into a tunnel that is
not there. As always, the failure is silent: dictation gets no context.

So each enrolled host's row in Settings has **Keep the tunnel open**. With it
on, localvoxtral holds that host's forward itself:

```
ssh -N -o BatchMode=yes -o ExitOnForwardFailure=no \
    -o ForkAfterAuthentication=no -o ControlPath=none -o PermitLocalCommand=no \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -R 28511:127.0.0.1:8473 -- builder
```

It is off by default, per host, because an app that opened SSH connections
you did not ask for would be a worse bug than the one it fixes. This path
involves no token. The credential lives in the remote plugin's config, and
this process only carries bytes for it. The flags differ from the ones in your
`~/.ssh/config` block on purpose:

* **`ExitOnForwardFailure=no`**, like your config block. The process reads
  your config, so it also requests every other `RemoteForward` your `Host`
  block declares, and a refusal of one of those must not cost this tunnel. It
  watches ssh's stderr for a refusal that names its own port instead.
* **No `ClearAllForwardings`.** That option also clears the `-R` on the
  command line, so the tunnel would never be created. The duplicate of your
  block's own forward collapses into one request.
* **`ForkAfterAuthentication=no`, `ControlPath=none`, `PermitLocalCommand=no`**
  keep your config from backgrounding, multiplexing or running a local command
  under a process the app has to be able to stop.
* **`ServerAliveInterval=30` / `ServerAliveCountMax=3`**. Without them, a NAT
  or a sleeping laptop leaves a half-dead connection holding the remote bind,
  which makes the next connection fail.
* Restarts back off exponentially (0.5s, 1s, 2s… capped at 30s) and stop
  after five consecutive failures rather than hammering your SSH server. A
  **refused bind** never enters that loop. When your own session holds the
  port, the row reads **Tunnel up through an existing ssh
  session.** Otherwise it reads **Port held on that host. Checking again every 5
  min.** Either way the app dials again every five minutes.
* When the Mac wakes or its network changes, a stopped or waiting tunnel
  starts over at once.
* After a network change the host keeps the old connection's port bound until
  its sshd notices the connection is gone, and the row shows the port as held
  until then. `ClientAliveInterval 30` in the host's `sshd_config` (with the
  default `ClientAliveCountMax 3`) makes sshd drop it within about 90
  seconds.

The listener always binds before the forwards start. A forward opened into an
unbound port would give every hook connection-refused (silent, fail-open)
while making ssh print `connect_to … failed.` into your remote terminal on
every dial. Turning the toggle on or off takes effect immediately, with no
relaunch. Revoking a host, or quitting the app, stops its forward.

## Updating an enrolled host

When localvoxtral ships a newer version of this plugin, an already-enrolled host
does **not** pick it up when you re-run the setup commands. Verified on Claude
Code 2.1.220:

- `claude plugin marketplace add …` on a marketplace it already has exits 0,
  says it is already on disk, and does **not** refresh the clone.
- `claude plugin install …` on an installed plugin exits 0, says it is already
  installed, and does **not** change the version. (It *does* apply a new
  `--config token=…`, which is why rotating a token reuses that same command.)

So the update takes its own pair of commands. It keeps your token, because
`plugin update` preserves the stored config:

```sh
ssh builder 'claude plugin marketplace update localvoxtral'
ssh builder 'claude plugin update localvoxtral-remote@localvoxtral'
# Only needed once, for a host enrolled before per-Mac ports existed — and
# harmless every time after. `plugin update` has no `--config`, and `install`
# merges config per key, so this sets the port without touching your token.
ssh builder "claude plugin install localvoxtral-remote@localvoxtral --config 'port=28511'"
```

Order matters: `plugin update` installs whatever the local marketplace clone
currently offers, so without refreshing the clone first nothing updates.

In the app, a host in **Settings → Remote hosts** has an **Update Host…**
button unless it is revoked or already current (see above). Its consent
sentence names the local files and enrolled SSH alias, and **Set Up** runs the
same seven-step flow as enrollment. The app never uses the display name in
place of the alias. A host enrolled before aliases were recorded must be
re-enrolled before the app can update it.
Non-interactive SSH skips your login shell's rc, so the app's version of these
commands first sets `PATH` to the usual `claude` install locations. Add that
yourself if `claude` is off the PATH a plain `ssh host 'claude …'` sees.

## Uninstall and revoke

```sh
ssh builder 'claude plugin uninstall localvoxtral-remote@localvoxtral'
ssh builder 'claude plugin marketplace remove localvoxtral'
# then delete the BEGIN/END block from ~/.ssh/config
```

Then **revoke the host in localvoxtral**. This step matters most, because the
token dies on your Mac, not on the remote. Uninstalling the plugin only stops
the host asking. Revoking stops the app answering it, immediately and without
a restart. Rotating instead of revoking issues a new token and kills the old
one with no grace period.

## What the token can and cannot do

A host presenting a valid token can give localvoxtral **remote context**, and
nothing more. It cannot make the app read a local file, and code enforces
this, not a policy. The listener tags every session it accepts as `remote`
whatever the payload says, and reduces a remote working directory to a bare
label with no path that a collector could read. A *local* process that
connects to the listener gets the same treatment, so connecting there can
only downgrade you.

Each host's sessions are namespaced under the host id its token authenticated,
so two hosts can never collide on a session id or forge each other's
sessions.

## What this does not protect against

**A malicious process running as YOU on the remote host.** This cannot be
solved here. That process can already read `~/.claude/`, where Claude Code
keeps the plugin's configured token, so it can read the token whatever the
app does. It could just as well read your source, your keys, and your shell
history without involving localvoxtral at all. Enrolling a host means
trusting that host's user account as far as it is already trusted. The token
limits what a host can do to *localvoxtral* (remote context only, never a
local file read), not what a compromised account can do to itself.

**Two Macs enrolled against one host.** Each Mac forwards its *own* port, so
they cannot compete for one remote bind. That used to cause silent
cross-delivery. The first connection kept the forward, and the second
connected anyway (`ExitOnForwardFailure no`). Every event on that host,
bearer token included, went to the *first* Mac, which answered 401, which the
shim reads as a completed exchange. Nothing reported it (issue #215). What
per-Mac ports do **not** change: one host runs one Claude Code install storing
one `port`, so the Mac whose config was installed last receives the events.
The other Mac sees no traffic. You can see that only one Mac is served, and
no credential reaches the wrong Mac's listener.

**A process on your Mac that squats 127.0.0.1:8473 before the app binds it.**
Loopback ports on macOS go to whoever binds first, with no ownership. A
squatter cannot authenticate your hosts, because it does not have the token
hashes, which never leave the 0600 host file. But it does receive whatever
the remote sends, including the bearer token itself, before anything rejects
it. So the app reports a bind conflict instead of routing around it. Settings
says the port is in use and offers Retry, rather than quietly moving to
another port where you would never learn a squatter was there. If you see
that status, find the process (`lsof -nP -iTCP:8473 -sTCP:LISTEN`) before
assuming it is a stale copy of the app, and rotate the tokens of any host
that connected meanwhile.

**Anyone who can write your `~/.ssh/config`.** They can point the forward
somewhere else. That is true of every use of that file. For that reason the
app writes it only after showing you the exact block and getting your
confirmation, and writes only its own marker-delimited block, never the rest
of the file.

## SSH to a host you have NOT enrolled

No enrollment means no tunnel, no token, and no hooks. Your session is
unchanged and the pane stays screen-only and unjoined. Nothing about this
feature is on by default: with no enrolled host, the app binds no port at all.
An ENROLLED host's plain `ssh` session does now join, on the connection
itself (see "A plain `ssh host` session" near the top).

## What crosses the tunnel

The same allowlist as the local plugin, plus two additions:

* bounded, sanitized excerpts of `Read`/`Edit`/`Write` tool input and output
  (≤512 bytes each, ≤8 kept per session)
* an allowlisted set of environment values, sent as `X-Lvx-Env-*` request
  headers rather than in the body (the body stays Claude Code's event JSON
  byte-for-byte, because the host is not assumed to have `jq`):
  `HERDR_PANE_ID`, `HERDR_SOCKET_PATH`, `HERDR_SESSION`, `CMUX_SURFACE_ID`,
  `CMUX_SOCKET_PATH`, `CLAUDE_CODE_BRIDGE_SESSION_ID`,
  `CLAUDE_CODE_HOST_SESSION_ID`, `TMUX`, `TMUX_PANE`,
  `STY`, `ZELLIJ`, `SSH_TTY`, `SSH_CONNECTION`, `LC_LVX_TTY`, the shim's own
  parent pid, and the name of the session's repository (the basename of its
  main checkout, from `git rev-parse`, so every worktree of one repository
  keeps one set of learned terms). Each is sent only
  if it is non-empty, at most 200 characters, and made purely of ASCII
  alphanumerics plus `._:/@+,=%-`; anything else is dropped rather than
  escaped. `SSH_CONNECTION` is the one value the shim reshapes. `sshd` writes
  its four fields separated by spaces, and a space could end a header line, so
  the shim re-joins them with commas, and drops the value entirely if it is
  not exactly four fields. These values tell the app WHERE the session runs,
  so it can tell whether the pane you are dictating into is this one, never
  what the pane contains. No other environment value goes into these headers.
  On the Mac these values are only labels: they can never become a local path, a
  socket the app dials, or a process it probes.

These additions exist only for remote sessions. A local session's files are on
your Mac and the app reads them directly. A remote session's files are on a
machine the app does not reach into, so what the hook quotes is all it will
ever know. Every excerpt is stripped of control characters, C1 escapes, bidi
overrides, and zero-width characters before it is stored, so foreign text
stays text and cannot act on anything.

Transcript contents, `Bash` command strings, and anything claiming to be trusted
still never cross, exactly as locally.
