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

The app allocates a marker per session and replies with it on the socket. The
publisher then asks Claude Code to write that marker into the window title (an
OSC 2 sequence), with `suppressOutput` so it never appears in your transcript.
That is how the app tells two Claude sessions in the same repo apart.

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

Update (re-reads the marketplace, then updates the plugin):

```sh
claude plugin marketplace add "/Applications/localvoxtral.app/Contents/Resources/claude-code-marketplace"
claude plugin update localvoxtral@localvoxtral \
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
* safe process metadata: pid, ppid, controlling TTY, `$TERM_PROGRAM`

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
| Transport | AF_UNIX socket, `command` hook + shim | HTTP over an SSH `RemoteForward`, declarative `http` hooks |
| Authentication | kernel-verified peer UID | per-host bearer token you issue in the app |
| Needs on that host | the app's publisher binary | **nothing** — no Python, no `jq`, no `nc`, no Node, no binary |
| Context it delivers | full: cwd authorizes local repository reads | opaque: labels and bounded excerpts only |

## How it works

```
remote host                            your Mac
┌───────────────────────┐              ┌────────────────────────────┐
│ Claude Code           │              │ localvoxtral               │
│   http hook  ────────►│ 127.0.0.1:8473              ▲             │
│   Bearer <token>      │   │          │              │             │
└───────────────────────┘   │          │   ClaudeRemoteContextListener
                            └── ssh RemoteForward ────┘             │
        ◄──── {"terminalSequence": "\e]2;lvx-…\a"} ────────────────┘
```

Claude Code is the HTTP client. It POSTs each hook's event JSON to
`http://127.0.0.1:8473/v1/hook/<Event>` on the *remote* loopback; OpenSSH's
`RemoteForward` carries that to your Mac's loopback, where the app is listening.
The app answers with the session's marker as a `terminalSequence`, which Claude
Code writes to its terminal — so the marker rides the SSH PTY back into Ghostty
and the pane identifies itself. Nothing else opens a port, and nothing is
reachable from your LAN.

## Set it up

In **Settings → Text Processing → Polishing → "Remote Claude Code over SSH"**,
type a name and your SSH host alias and press **Enroll…**. The app issues a
token, shows it once alongside every command below with a Copy button on each,
and binds the listener immediately — there is no relaunch step. The list in that
row shows each enrolled host, when it was last seen, and gives you **Rotate
Token**, **Revoke** and **Remove**.

The app **does not edit `~/.ssh/config` and does not run anything on the remote
host.** It hands you the text. Those files are yours and are load-bearing for
work that has nothing to do with dictation.

The token is shown exactly once, because only its hash is stored. If you lose it,
rotate — that is what rotation is for. Then:

**1. Add the tunnel to `~/.ssh/config`:**

```
# BEGIN localvoxtral claude context (h1a2b3c4)
Host builder
    RemoteForward 8473 127.0.0.1:8473
    ExitOnForwardFailure no
# END localvoxtral claude context (h1a2b3c4)
```

`ExitOnForwardFailure no` is deliberate and is the default. With `yes`, SSH
refuses to open the session at all when the remote's 8473 is already bound —
usually by your own second window to the same host. **A dictation nicety must
never cost you the shell.** The price of `no` is that a failed forward is
silent: the hooks get connection refused, fail open, and you simply get no
context. `ssh -v builder true 2>&1 | grep -i 'remote forward'` is where you see
whether it took.

**2. Install the plugin on the remote host:**

```sh
ssh builder
claude plugin marketplace add T0mSIlver/localvoxtral
 claude plugin install localvoxtral-remote@localvoxtral --config 'token=<YOUR-TOKEN>'
```

Note the leading space on the second line: with `HISTCONTROL=ignorespace` (bash)
or `setopt HIST_IGNORE_SPACE` (zsh) it keeps the token out of your shell history.
If it landed there anyway, rotate the token in the app — that is what rotation is
for.

Nothing else is installed. The marketplace add resolves the repository root's
`.claude-plugin/marketplace.json`; the plugin is two JSON files.

**3. Check it:**

```sh
claude plugin list
# From the remote, through the tunnel. 401 is the RIGHT answer here — it proves
# the tunnel is up and the app is answering. A connection error means the
# forward did not take.
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
  -d '{}' http://127.0.0.1:8473/v1/hook/SessionStart
```

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
somewhere else. That is true of every use of that file and is why the app will
not write it for you.

## Plain SSH still works exactly as before

No enrollment, no tunnel, no token, no hooks. Your session is unchanged and the
pane stays screen-only and unjoined. Nothing about this feature is on by default:
with no enrolled host, the app binds no port at all.

## What crosses the tunnel

The same allowlist as the local plugin, plus one addition:

* bounded, sanitized excerpts of `Read`/`Edit`/`Write` tool input and output
  (≤512 bytes each, ≤8 kept per session)

These exist only for remote sessions. A local session's files are on your Mac
and the app reads them properly; a remote session's are on a machine the app has
no business reaching into, so what the hook quotes is all it will ever know.
Every excerpt is stripped of control characters, C1 escapes, bidi overrides, and
zero-width characters before it is stored — foreign text is treated as text, never
as something that can act.

Transcript contents, `Bash` command strings, and anything claiming to be trusted
still never cross, exactly as locally.
