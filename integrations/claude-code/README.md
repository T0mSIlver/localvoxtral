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

Two mechanisms for a terminal, plus one for a browser. The resolver always
tries the terminal pair in order; the opt-in setting only controls whether
local sessions write the marker the second one looks for:

**TTY join (the default — Ghostty ≥ 1.4 [currently the tip channel], iTerm2,
and Terminal.app).** The hooks report
the session's controlling terminal device, and at dictation start the app asks
the focused terminal itself for its focused pane's `tty` over AppleScript (a
one-time Automation consent prompt per terminal). Device equality is exact,
works mid-response, and tells two sessions in the same repo apart. Inside a
[herdr](https://herdr.dev) multiplexer session the TTY can't match (herdr
interposes its own PTY per pane), so the app instead binds the surface to
herdr and asks herdr's own socket for the focused pane — an exact pane-id
join, deliberately marker-free: any ambiguity, including two live herdr
sessions, attaches nothing. Other terminals abstain entirely rather than
half-join.

**cmux surface join (opt-in).** [cmux](https://github.com/manaflow-ai/cmux)
draws its terminal with libghostty into a custom view: it exposes no
accessible text and no scripting dictionary, so neither the TTY read nor any
screen read above works there. Instead the app asks cmux's own automation
socket which surface is focused, and matches that surface id against the one
cmux injected into the session's environment — including into shells opened
with `cmux ssh`, which is the one place a REMOTE session joins by something
other than its title marker. That surface is also the only readable screen
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
`cmux socket requires password mode.` and the dictation simply falls back to
the title marker — nothing is attached on a failed join.

Two deliberate limits. The app cross-checks the surface's terminal device
against the one your session reported, and **abstains when either side does not
report one** — which is the case for opencode (its server half never claims a
pane), so opencode inside cmux does not join over this arm. And a session on a
remote host joins only while cmux itself reports that surface's workspace as a
live `cmux ssh` workspace, so a stale surface id from an earlier remote session
cannot attach itself to whatever you are looking at now.

**Title marker (opt-in local fallback, always on for SSH).** For an older
(stable-channel) Ghostty build, enable **Settings → Text Processing →
Polishing → Local Claude title fallback** and export
`CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` where Claude Code runs.
The app then replies to local hooks with
the session marker, which Claude Code writes into the window title as an OSC 2
sequence; the environment variable stops Claude Code from overwriting it with
its own conversation title mid-turn. The fallback exists for stable Ghostty
only — iTerm2 and Terminal.app expose the TTY natively and never need it, and
herdr-hosted sessions never receive a marker at all (herdr intercepts titles
per pane, so a marker could only mis-join). Remote hooks always receive the
marker regardless of this setting because it is the ONLY join for SSH
sessions: their tty names a device on another machine.

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

The marker grammar is `lvx-<hex>` and nothing else is ever emitted — an escape
sequence is code as much as data, so the marker is allowlist-validated and
length-bounded before it goes anywhere near your terminal. If anything is off,
the hook prints nothing at all.

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
        ◄──── {"terminalSequence": "\e]2;lvx-…\a"} ────────────────┘
```

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
The app answers with the session's marker as a `terminalSequence`, which Claude
Code writes to its terminal — so the marker rides the SSH PTY back into Ghostty
and the pane identifies itself. Nothing else opens a port, and nothing is
reachable from your LAN.

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
`.claude-plugin/marketplace.json`; the plugin is two JSON files and one
POSIX-sh script that needs only `sh` and `curl` on the host.

**3. Check it:**

```sh
claude plugin list
# From the remote, through the tunnel. 401 is the RIGHT answer here — it proves
# the tunnel is up and the app is answering. A connection error means the
# forward did not take.
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
  -d '{}' http://127.0.0.1:28511/v1/hook/SessionStart
```

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

## tmux / screen

A multiplexer owns the window title, so the OSC 2 marker the hook writes does not
reach Ghostty and the pane stays **unjoined** — you still get the off-screen
context (prior prompt, cwd, recent files), you just do not get the screen join.
`set -g set-titles on` in `~/.tmux.conf` lets tmux pass the title through.

## What the token can and cannot do

A host presenting a valid token can give localvoxtral **remote context**. That is
all it can ever do. It cannot make the app read a local file, and this is not a
policy — the listener tags every session it accepts as `remote` regardless of
what the payload says, and a remote working directory is reduced to a bare label
that has no path accessor to hand a collector. A *local* process that connects to
the listener gets the same treatment: connecting there can only downgrade you.

Each host's sessions are namespaced under the host id its token authenticated,
so two hosts can never collide on a session id, forge each other's sessions, or
share a marker.

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

## Plain SSH still works exactly as before

No enrollment, no tunnel, no token, no hooks. Your session is unchanged and the
pane stays screen-only and unjoined. Nothing about this feature is on by default:
with no enrolled host, the app binds no port at all.

## What crosses the tunnel

The same allowlist as the local plugin, plus two additions:

* bounded, sanitized excerpts of `Read`/`Edit`/`Write` tool input and output
  (≤512 bytes each, ≤8 kept per session)
* an allowlisted set of environment values, sent as `X-Lvx-Env-*` request
  headers rather than in the body (the body stays Claude Code's event JSON
  byte-for-byte, because the host is not assumed to have `jq`):
  `HERDR_PANE_ID`, `HERDR_SOCKET_PATH`, `HERDR_SESSION`, `CMUX_SURFACE_ID`,
  `CMUX_SOCKET_PATH`, `CLAUDE_CODE_BRIDGE_SESSION_ID`, `TMUX`, `TMUX_PANE`,
  `SSH_TTY`, and the shim's own parent pid. Each is sent only if it is
  non-empty, at most 200 characters, and made purely of ASCII alphanumerics
  plus `._:/@+,=%-`; anything else is dropped rather than escaped. They tell the
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
