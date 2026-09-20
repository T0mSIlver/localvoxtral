# localvoxtral hooks for Mistral Vibe

When you dictate into a [Mistral Vibe](https://docs.mistral.ai/vibe/code/cli/install-setup)
pane, localvoxtral can ground the transcription on that session's last prompt,
its working directory and the files it just touched. It does this without
reading your screen.

Everything stays on this machine. The hooks publish bounded records to
localvoxtral's private UNIX socket, which checks the connecting user. When the
app is not running, each hook exits after one failed connect.

Before changing anything here, read `../../docs/agent/invariants.md`. The Vibe
entry there states what the session log read is limited to.

## Install

1. Copy the shim:

```sh
mkdir -p ~/.vibe/localvoxtral
cp publish.sh ~/.vibe/localvoxtral/publish.sh
```

2. Append the block in `hooks.toml` to `~/.vibe/hooks.toml`, creating the file
   if it does not exist. The block is two `[[hooks]]` tables between
   `# >>> localvoxtral >>>` and `# <<< localvoxtral <<<`, so it is valid at the
   end of any existing file.

Vibe reads `hooks.toml` when a session starts. Sessions already running keep
their old hooks.

If you set `VIBE_HOME`, use that directory instead of `~/.vibe` in both steps
and in the two `command` lines.

## Uninstall

Delete the marked block from `~/.vibe/hooks.toml` and remove
`~/.vibe/localvoxtral/`.

## What is published

Vibe 2.25 has three hook types: `pre_tool`, `post_tool` and `post_agent`. This
integration uses two.

| Vibe hook | When | Record sent |
|---|---|---|
| `post_tool` on `read_file`, `write_file`, `edit` | the tool ran | the file's path, marked read or edited |
| `post_agent` | a turn ended | the turn ended |

Both also send the session id, the working directory, the Vibe process id and
start time, its terminal device, and the herdr or cmux pane handle when there is one.

No Vibe hook payload carries your prompt, so the publisher reads it from the
session's `messages.jsonl`, whose path Vibe passes to every hook. It reads the
last 512 KiB of that file and keeps one thing: the newest message with role
`user` and `injected: false`, cut to 8 KiB. It does not parse lines that lack
the user-role marker, which covers assistant messages, reasoning, tool calls
and tool results, and it never sends the file path. If the read takes longer
than 250 ms, the hook publishes without a prompt.

File contents, tool output and shell commands are never sent. A `post_tool`
payload contains the tool's output, and the publisher discards it after
parsing.

## Limits that come from Vibe's hook set

- Vibe has no session-start hook. localvoxtral learns about a session at its
  first file-tool call or when its first turn ends, so the first dictation into
  a new session has no session context.
- Vibe has no session-end hook. A session ends for localvoxtral when its
  process exits or after the registry's idle timeout. The app compares the
  process start time as well as the pid, so a reused pid does not revive a
  finished session.
- Hooks fire for subagents too. The publisher drops any payload with a
  `parent_session_id`, so a subagent's files never count as yours.
- The VS Code extension and other ACP clients have no terminal pane. Their
  sessions publish, but nothing can join a dictation to them. A `vibe -p` run
  typed into a pane keeps that pane's terminal, so it joins while it runs.

## Why the shim looks the way it does

- It prints nothing and always exits 0. Vibe reports a hook's non-zero exit or
  non-JSON output as a warning on your turn.
- Neither hook sets `strict = true`. A strict hook turns its own failure into a
  denied tool call.
- Each `command` ends in `2>/dev/null || :`, so a `hooks.toml` that still names
  a deleted script does not fail every turn.
- It does not `exec` the publisher. A failed `exec` would become the hook's
  exit status.
- Vibe starts each hook in a new session with no controlling terminal, and the
  shell it spawns the hook through may or may not still exist as the hook's
  parent. The publisher walks up from the shim's `$PPID` until it leaves the
  hook's own session, and publishes that process as the Vibe process.
