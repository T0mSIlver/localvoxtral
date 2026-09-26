# localvoxtral plugin for Codex CLI

When you dictate into a [Codex CLI](https://github.com/openai/codex) pane,
localvoxtral can ground the transcription on that session's last prompt, its
working directory and the files it just patched. It does this without reading
your screen.

Everything stays on this machine. The plugin's hooks publish bounded records
to localvoxtral's private UNIX socket, which checks the connecting user. When
the app is not running, each hook exits after one failed connect.

Before changing anything here, read `../../docs/agent/invariants.md`. Its
Codex entry says why the hooks ship as a plugin and why `hooks/hooks.json`
must not change lightly.

## Install

In localvoxtral, open **Settings → Codex → Plugin → Install**. The app runs
Codex's own commands, against a copy of this directory it keeps in
`~/Library/Application Support/localvoxtral/codex/marketplace`:

```sh
codex plugin marketplace add "$HOME/Library/Application Support/localvoxtral/codex/marketplace"
codex plugin add localvoxtral@localvoxtral
```

Codex runs a plugin's hooks only after you trust them. The next time Codex
starts, it shows **Hooks need review**; choose **Trust all and continue**, or
**Review hooks** to trust them one by one. You can also do it later with
`/hooks` inside Codex. Until then Codex skips the hooks without a word, which
is why the row's dot stays yellow until a hook has reached localvoxtral.

Trust survives app updates as long as `hooks/hooks.json` is unchanged. If an
update changes it, Codex asks again at its next start.

**Remove** runs `codex plugin remove localvoxtral@localvoxtral` and
`codex plugin marketplace remove localvoxtral`. The app never edits
`~/.codex/hooks.json` or `~/.codex/config.toml` itself.

## What the hooks send

| Codex event | Sent |
|---|---|
| `SessionStart` | session id, working directory |
| `UserPromptSubmit` | the prompt you submitted |
| `PostToolUse` on `apply_patch` | the paths the patch adds, updates or moves to |
| `Stop` | the end of the turn |
| `SessionEnd` | the end of the session |

Each record also names the Codex process, its terminal and, inside herdr or
cmux, the pane. Codex's `transcript_path`, the model name, tool output, the
patch body and its last message are dropped. Codex reads files through shell
commands, so a read names no file.

A subagent's edits count for the session it runs in. A prompt a subagent
submits is dropped, because it is not what you typed.

## Joining

A Codex session joins like a Claude Code one: on the focused terminal's tty
(Ghostty 1.4 or newer, iTerm2, Terminal.app), a herdr pane, or a cmux surface.
Remote hosts are not supported yet.
