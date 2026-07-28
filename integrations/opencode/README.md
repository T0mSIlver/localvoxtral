# localvoxtral opencode plugin

Off-screen dictation context for [opencode](https://github.com/sst/opencode)
sessions, the same way the Claude Code plugin provides it for Claude Code:
when you dictate into an opencode pane, localvoxtral can ground transcription
on the session's prior prompt, working directory, and recently touched files —
without reading your screen.

Everything is local: the plugin publishes bounded records over localvoxtral's
private, peer-authenticated UNIX socket on this machine. No network, no
telemetry, and when the app is not running every write silently does nothing.

## Install (manual, two steps)

1. Copy `localvoxtral.js` into opencode's global plugin directory:

```sh
mkdir -p ~/.config/opencode/plugins
cp localvoxtral.js ~/.config/opencode/plugins/
```

2. List it in `~/.config/opencode/tui.json` (create the file if it does not
   exist; merge the `plugin` entry if it does):

```json
{
  "plugin": ["./plugins/localvoxtral.js"]
}
```

Restart opencode. Nothing else: no dependencies, no tokens, no daemons.

Why two steps: opencode auto-discovers `plugins/*.js` for its **server**
plugin loader, but its **TUI** plugin loader only loads plugins explicitly
listed in `tui.json` (verified on opencode 1.17.12). This plugin is one file
with both halves — the server half publishes session content, the TUI half
publishes which session your pane currently displays. Skipping step 2 keeps
session content flowing but leaves panes undeclared, so dictation cannot join
your terminal to a session and stays vocabulary-only.

## Uninstall

```sh
rm ~/.config/opencode/plugins/localvoxtral.js
```

and remove the line from `~/.config/opencode/tui.json`.

## Design invariants (why it is built this way)

- **The TTY is published only by the half that owns a pane.** One opencode
  process can host many sessions on one terminal while the TUI displays one
  at a time — and under `opencode serve` the process owns no pane at all, so
  a naive "am I attached to a TTY" check would publish a device that
  mis-joins. The server half therefore never claims a TTY; the TUI half —
  which only loads in the realm that renders your pane — declares
  `FocusChanged` records ("this TTY currently displays session X"),
  freshness-bounded, heartbeat-refreshed, and explicitly retracted
  (`FocusCleared`) the moment the pane leaves its session view. localvoxtral
  resolves a pane to a session only through a fresh declaration,
  cross-checked against the declaring process's pid (and, at the broker,
  against the kernel-verified pid of the connecting process), and abstains
  on anything ambiguous or stale.
- **Blast radius zero.** The plugin runs inside your agent process. It never
  blocks a hook on IO: one lazily reconnected, `unref()`ed socket,
  fire-and-forget writes, every handler wrapped in try/catch, all fields
  bounded before they cross the wire. It never writes to the terminal.
- **No title markers.** opencode owns and rewrites its window title mid-turn,
  so the title channel Claude Code uses cannot work here; localvoxtral never
  sends this plugin one.
- **Subagent sessions are filtered, fail-closed.** The plugin publishes a
  session's activity only while it is in a bounded allowlist of known
  top-level sessions, so a child (task-tool) session — or any session whose
  parentage it never observed — never masquerades as the session you are
  typing into.
- **herdr panes keep working.** The plugin forwards the herdr pane identity
  it inherited from the environment, so localvoxtral's existing herdr join
  applies to opencode panes unchanged.

## What does not publish (deliberate)

- `opencode run` and `opencode serve`: their main-realm server finds the TUI
  module shape and skips the plugin (a line in opencode's log, nothing else).
  There is no pane to dictate into in `run`, and a serve process must never
  publish a TTY. Sessions viewed through `opencode attach` get focus
  declarations from the attach TUI, but their content lives in the serve
  process and is not published — those panes stay vocabulary-only.
- Session transcripts, model output, file contents: never sent. The wire
  carries the prior prompt (bounded), the cwd, and touched file paths only.
