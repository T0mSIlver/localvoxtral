# localvoxtral opencode plugin

The opencode plugin lets localvoxtral use what your
[opencode](https://github.com/sst/opencode) session is doing to transcribe
your dictation, and write the words straight into the session's prompt. The
[Claude Code plugin](../claude-code/README.md) does the same for Claude Code.

## What you get

**Context from the session.** When you dictate into an opencode pane,
localvoxtral grounds the transcription on the session's prior prompt, its
working directory and the files it touched recently. It does this without
reading your screen.

**Words that land in the prompt.** localvoxtral writes your dictation into the
pane's prompt, and submits it when you say "send it", without typing keys. A
window switch mid-dictation, Secure Keyboard Entry or the clipboard cannot
send the text elsewhere.

**No tokens spent.** The plugin itself spends none. Two features outside it
do, each through a read-only opencode run the app starts on its own, never in
your session, with your default model:

- With **Ask the coding agent for each new project's terms** on, the app runs
  it once per project. See
  [Terms from your coding agent](../../docs/dictation.md#terms-from-your-coding-agent).
- When neither Claude Code nor Mistral Vibe is installed, a
  [quick capture](../../docs/coding-agents.md#quick-capture) routed to a
  project on this Mac runs it once to draft the issue.

## Install

1. In localvoxtral, open **Settings → opencode → Plugin → Set Up…**. One
   consent sentence names both files the app writes, and **Details** opens
   this page.
2. Confirm. The app copies its bundled plugin into opencode's global plugin
   directory and lists it in `~/.config/opencode/tui.json`.
3. Restart opencode.

The app creates that file if it is absent, and keeps everything else in it if
it is present. It writes nothing until you press the button. It leaves the
file alone if its plugin list has an unexpected shape.

Once the installed plugin matches the app's copy, the row offers only
**Remove**. An app update that ships a new plugin brings back **Update…**.

### Install by hand

1. Copy [the plugin file](localvoxtral.js) into opencode's global plugin
   directory:

    ```sh
    mkdir -p ~/.config/opencode/plugins
    cp localvoxtral.js ~/.config/opencode/plugins/
    ```

2. List it in `~/.config/opencode/tui.json`. Create the file if it does not
   exist, or merge the entry into it if it does:

    ```json
    {
      "plugin": ["./plugins/localvoxtral.js"]
    }
    ```

3. Restart opencode. There are no dependencies, tokens or daemons to set up.

Step 2 matters because opencode loads the plugin's two halves differently
(checked on opencode 1.17.12). Its server loader finds the plugin directory
on its own, but its TUI loader only loads plugins listed in that file. The
server half publishes session content, and the TUI half publishes which
session your pane displays.

Without step 2, session content still arrives but no pane declares its
session. Dictation then cannot join your terminal to a session and stays
vocabulary-only.

## Tell opencode you dictate

**Settings → opencode → Tell opencode you dictate → Add** puts a short note in
the instructions file opencode reads. That file is
`~/.config/opencode/AGENTS.md`, or `~/.claude/CLAUDE.md` when the first one
does not exist. See
[Telling the agent you dictate](../../docs/coding-agents.md#telling-the-agent-you-dictate).

## What it sends

Everything stays on this machine, and there is no telemetry. The plugin
publishes bounded records over localvoxtral's private UNIX socket, which
authenticates the connecting peer. When the app is not running, every write
silently does nothing.

The records carry only the prior prompt (bounded), the working directory and
the paths of touched files. Session transcripts, model output and file
contents are never sent.

When a session asks for a permission or asks you a question, the plugin sends
only which of the two it is, so localvoxtral can tell you the session needs
you. The command, patterns and question text stay in opencode.

The plugin's one listener is the prompt relay on 127.0.0.1, described under
[How it is built](#how-it-is-built).

## What doesn't work

- `opencode run` and `opencode serve` publish nothing. Their main-realm server
  finds the TUI module shape and skips the plugin, which leaves a line in
  opencode's log and nothing else. There is no pane to dictate into in a run,
  and a serve process must never publish a TTY.
- Sessions viewed through an opencode attach get focus declarations from the
  attach TUI, but their content lives in the serve process and is not
  published. Those panes stay vocabulary-only.

## Uninstall

Press **Remove** in **Settings → opencode → Plugin**. It deletes the plugin
and its line in the config file. By hand:

```sh
rm ~/.config/opencode/plugins/localvoxtral.js
```

Then remove the plugin's line from `~/.config/opencode/tui.json`.

## Fix common problems

- **Dictation gets the project's vocabulary but never joins the session.**
  The plugin is missing from `~/.config/opencode/tui.json`. Add it (step 2 of
  [Install by hand](#install-by-hand)) and restart opencode.
- **The row offers Update… again.** An app update shipped a new plugin. Press
  **Update…**.

## How it is built

- **The TTY is published only by the half that owns a pane.** One opencode
  process can host many sessions on one terminal, while the TUI displays one
  at a time. A serve process owns no pane at all, so a
  simple "am I attached to a TTY" check would publish a device that joins the
  wrong session. The server half never claims a TTY, and the TUI half only
  loads in the realm that renders your pane.
- **A pane declares its session, and the declaration expires.** The TUI half
  declares "this TTY currently displays session X". Each declaration expires,
  refreshes on a heartbeat, and is retracted as soon as the pane leaves its
  session view. localvoxtral resolves a pane to a session only through a
  fresh declaration.
- **Declarations are checked against the process.** localvoxtral checks each
  declaration against the declaring process's pid. The broker also checks it
  against the connecting process's pid as the kernel reports it. Anything
  ambiguous or stale joins nothing.
- **A plugin failure cannot stall your agent.** The plugin runs inside your
  agent process and never blocks a hook on IO. It uses one socket that does not keep the process alive
  and reconnects lazily. It writes without waiting for a reply, catches every
  error in its handlers, and bounds every field before it crosses the wire.
- **Nothing is ever written to your terminal.** The plugin publishes to a
  socket and prints nothing, and localvoxtral has no channel into a terminal.
  localvoxtral used to hand Claude Code a window-title marker, and that
  mechanism was removed on 2026-09-05.
- **The prompt relay appends and submits, nothing else.** A plain opencode
  runs no HTTP server, because its TUI talks to its worker in process. So the
  TUI half listens itself, on 127.0.0.1 with a random port and a random
  32-byte token, and publishes the port and token only in its focus
  declarations over the socket.
- **The relay goes through opencode's own client.** The relay takes two
  requests with that token, append to the prompt and submit the prompt, for
  the session the pane displays when the call arrives. It forwards them
  through opencode's own in-process client, so a server password is never
  needed. It refuses any other request, and any refusal makes localvoxtral
  type the text instead.
- **The plugin skips subagent sessions and any session it cannot place.**
  It publishes a session's activity only while that session is in a bounded allowlist of
  known top-level sessions. A child (task-tool) session, or any session whose
  parent the plugin never saw, therefore never passes for the session you are
  typing into.
- **herdr panes keep working.** The plugin forwards the herdr pane identity
  it inherited from the environment, so localvoxtral's
  [herdr](../herdr/README.md) join applies to opencode panes unchanged.
