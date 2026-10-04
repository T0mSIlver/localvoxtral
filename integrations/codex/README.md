# localvoxtral plugin for Codex CLI

The Codex plugin lets localvoxtral use what your
[Codex CLI](https://github.com/openai/codex) session is doing to transcribe
your dictation. It works on this Mac only.

## What you get

When you dictate into a Codex pane, localvoxtral grounds the transcription on
that session's last prompt, its working directory and the files it just
patched. It does this without reading your screen.

A Codex session joins like a Claude Code one, on one of these:

- the focused terminal's tty, in Ghostty 1.4 or newer, iTerm2 or Terminal.app;
- a [herdr](https://t0msilver.github.io/localvoxtral/integrations/herdr/) pane;
- a cmux surface.

## Install

1. In localvoxtral, open **Settings → Codex → Plugin → Install**. The app
   keeps a copy of this directory in
   `~/Library/Application Support/localvoxtral/codex/marketplace` and runs
   Codex's own commands against it:

    ```sh
    codex plugin marketplace add "$HOME/Library/Application Support/localvoxtral/codex/marketplace"
    codex plugin add localvoxtral@localvoxtral
    ```

2. Start Codex. It shows **Hooks need review**, because Codex runs a plugin's
   hooks only after you trust them.
3. Choose **Trust all and continue**, or **Review hooks** to trust them one
   by one. You can also do it later with `/hooks` inside Codex.

Until you trust the hooks, Codex skips them without a word. The row's dot
stays yellow until a hook has reached localvoxtral.

Trust survives app updates as long as the plugin's
[hook list](plugins/localvoxtral/hooks/hooks.json) is unchanged. If an update
changes it, Codex asks again at its next start.

The app never edits `~/.codex/hooks.json` or `~/.codex/config.toml` itself.

## Tell Codex you dictate

**Settings → Codex → Tell Codex you dictate → Add** puts a short note in the
instructions file Codex reads. That file is `~/.codex/AGENTS.override.md`
when it holds anything, else `~/.codex/AGENTS.md`. See
[Telling the agent you dictate](https://t0msilver.github.io/localvoxtral/docs/coding-agents/#telling-the-agent-you-dictate).

## Teach Codex to check dictation

**Settings → Codex → Teach Codex to check dictation → Add** installs a
skill in ~/.codex/skills that names `localvoxtral doctor` and `localvoxtral logs`. See
[Teaching the agent to check dictation](https://t0msilver.github.io/localvoxtral/docs/coding-agents/#teaching-the-agent-to-check-dictation).

## What it sends

Everything stays on this machine. The plugin's hooks publish bounded records
to localvoxtral's private UNIX socket, which checks the connecting user. When
the app is not running, each hook exits after one failed connect.

| Codex event | Sent |
|---|---|
| A session starts | the session id and working directory |
| You submit a prompt | the prompt you submitted |
| Codex applies a patch | the paths the patch adds, updates or moves to |
| A turn ends | the end of the turn |
| Codex asks for your approval | that the session waits for your approval, nothing about the tool call |
| A session ends | the end of the session |

Each record also names the Codex process, its terminal and, inside herdr or
cmux, the pane, and carries the session's name from Codex's
`~/.codex/session_index.jsonl`, the one Codex shows in its session list.

The hooks drop the transcript's path, the model name, tool output, the patch
body and Codex's last message. Codex reads files through shell commands, so
a read names no file.

A subagent's edits count for the session it runs in. The hooks drop a prompt
a subagent submits, because it is not what you typed.

## What doesn't work

- **Remote hosts.** A Codex session on an ssh host does not join yet.
- **File reads.** Codex reads files through shell commands, so localvoxtral
  never learns which files a session read.

## Uninstall

Press **Remove** in **Settings → Codex → Plugin**. It runs:

```sh
codex plugin remove localvoxtral@localvoxtral
codex plugin marketplace remove localvoxtral
```

## Fix common problems

- **The row's dot stays yellow.** Codex skips hooks you have not trusted.
  Run `/hooks` inside Codex and trust the localvoxtral hooks.
- **Codex asks to review the hooks again after an app update.** The update
  changed the plugin's hook list. Trust the hooks again.

## How it is built

Before changing anything here, read the
[invariants](../../docs/agent/invariants.md). Its Codex entry says why the
hooks ship as a plugin and why the plugin's
[hook list](plugins/localvoxtral/hooks/hooks.json) must not change lightly.
