# localvoxtral opencode plugin

When you dictate into an [opencode](https://github.com/sst/opencode) pane,
this plugin lets localvoxtral ground the transcription on the session's prior
prompt, working directory and recently touched files, without reading your
screen. The Claude Code plugin does the same for Claude Code.

The plugin also lets localvoxtral write your dictation straight into the
pane's prompt, and submit it when you say "send it", without typing keys. A
window switch mid-dictation, Secure Keyboard Entry or the clipboard cannot
send the text elsewhere.

Everything stays on this machine. The plugin publishes bounded records over
localvoxtral's private UNIX socket, which authenticates the connecting peer.
Its one listener is the prompt relay on 127.0.0.1 (see below). There is no
telemetry. When the app is not running, every write silently does nothing.

## Install

In localvoxtral, open **Settings → opencode → Plugin →
Set Up…**. One consent sentence names both files, and **Details** opens this
page. The app copies its bundled `localvoxtral.js` into opencode's global
plugin directory and lists it in `~/.config/opencode/tui.json`. It creates
that file if it is absent and keeps everything else in it if it is present.
**Remove** reverses both. Once the installed plugin matches the app's copy,
the row offers only **Remove**. An app update that ships a new plugin brings
back **Update…**. The app writes nothing until you press the button, and it
leaves a `tui.json` alone if its `plugin` entry has an unexpected shape.

The same install by hand:

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

Restart opencode. There are no dependencies, tokens or daemons to set up.

Step 2 is needed because opencode's **server** plugin loader finds
`plugins/*.js` on its own, but its **TUI** plugin loader only loads plugins
listed in `tui.json` (checked on opencode 1.17.12). This one file holds both
halves. The server half publishes session content, and the TUI half publishes
which session your pane displays. Without step 2, session content still
arrives but no pane declares its session, so dictation cannot join your
terminal to a session and stays vocabulary-only.

## Uninstall

```sh
rm ~/.config/opencode/plugins/localvoxtral.js
```

and remove the line from `~/.config/opencode/tui.json`.

## Telling opencode you dictate

**Settings → opencode → Tell opencode you dictate → Add** puts a short note in
the instructions file opencode reads: `~/.config/opencode/AGENTS.md`, or
`~/.claude/CLAUDE.md` when that file does not exist. See
[Telling the agent you dictate](../../docs/coding-agents.md#telling-the-agent-you-dictate).

## Design invariants (why it is built this way)

- **The TTY is published only by the half that owns a pane.** One opencode
  process can host many sessions on one terminal while the TUI displays one
  at a time. Under `opencode serve` the process owns no pane at all, so a
  simple "am I attached to a TTY" check would publish a device that joins the
  wrong session. The server half never claims a TTY, and the TUI half
  only loads in the realm that renders your pane. It declares `FocusChanged`
  records ("this TTY currently displays session X") that expire, refresh on a
  heartbeat, and are retracted (`FocusCleared`) as soon as the pane leaves
  its session view. localvoxtral resolves a pane to a session only through a
  fresh declaration. It checks the declaration against the declaring
  process's pid, and the broker also checks it against the connecting
  process's pid as the kernel reports it. Anything ambiguous or stale joins
  nothing.
- **Blast radius zero.** The plugin runs inside your agent process and never
  blocks a hook on IO. It uses one `unref()`ed socket that reconnects lazily,
  writes without waiting for a reply, wraps every handler in try/catch, and
  bounds every field before it crosses the wire.
- **Nothing is ever written to your terminal.** The plugin publishes to a
  socket and prints nothing. localvoxtral has no channel into a terminal. It
  used to hand Claude Code a window-title marker over OSC 2, and that
  mechanism was removed on 2026-09-05.
- **The prompt relay appends and submits, nothing else.** A plain `opencode`
  runs no HTTP server (its TUI talks to its worker in process), so the TUI
  half listens itself: 127.0.0.1, a random port, a random 32-byte token. It
  publishes port and token only in its focus declarations, over the socket
  above. It takes `POST /tui/append-prompt` and `POST /tui/submit-prompt`
  with that token, for the session the pane displays when the call arrives,
  and forwards them through opencode's own in-process client, so a server
  password (`OPENCODE_SERVER_PASSWORD`) is never needed. Any other request is
  refused, and any refusal makes localvoxtral type the text instead.
- **Subagent sessions are filtered, fail-closed.** The plugin publishes a
  session's activity only while that session is in a bounded allowlist of
  known top-level sessions. A child (task-tool) session, or any session whose
  parent the plugin never saw, therefore never passes for the session you are
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
  process and is not published, so those panes stay vocabulary-only.
- Session transcripts, model output and file contents are never sent. The
  wire carries only the prior prompt (bounded), the cwd and touched file paths.
