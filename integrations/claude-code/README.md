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

On each hook event, Claude Code runs `hooks/publish.sh`, which execs the
`localvoxtral-claude-hook` publisher. The publisher writes one bounded NDJSON
line to a private UNIX socket owned by the app and exits.

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

Everything goes through Claude Code's own plugin CLI.

**`~/.claude/settings.json` is never read, written, wrapped, or merged by
localvoxtral.** That file is yours and Claude Code owns its schema; the CLI is
the supported interface, and a third-party app editing it is how setups get
corrupted during an unrelated upgrade. If you prefer, run these yourself — the
app's installer runs exactly these commands and nothing else.

From an **installed app**:

```sh
claude plugin marketplace add "/Applications/localvoxtral.app/Contents/Resources/claude-code-marketplace"
claude plugin install localvoxtral@localvoxtral
```

From a **repo checkout**:

```sh
claude plugin marketplace add ./integrations/claude-code
claude plugin install localvoxtral@localvoxtral
```

Update (re-reads the marketplace, then updates the plugin):

```sh
claude plugin marketplace add "/Applications/localvoxtral.app/Contents/Resources/claude-code-marketplace"
claude plugin update localvoxtral@localvoxtral
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

### Remote / SSH sessions

The publisher is a dependency-free SwiftPM product that also builds on Linux, so
a Claude Code session on a remote host can publish through a forwarded UNIX
socket (`ssh -R`) by setting `LOCALVOXTRAL_CLAUDE_SOCKET`.

Note what the app does with those records: a forwarded connection's peer is
`sshd`, not your local session, so the broker labels it **remote**. Remote
records carry opaque context only — their working directory is reduced to a bare
label and can never reach a local filesystem collector. That separation is
enforced by the type system, not by a runtime check.

See `AGENTS.md` for the follow-up work needed to make SSH sessions fully useful.
