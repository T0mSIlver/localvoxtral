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

In localvoxtral, open **Settings → Mistral Vibe → Hooks → Set up…**. One
consent sentence names both files. The app copies its bundled `publish.sh` to
`~/.vibe/localvoxtral/` and adds the marked block to `~/.vibe/hooks.toml`,
creating that file when it is absent and writing only between its two markers.
**Remove** deletes the block, the blank line before it and the script. After
an app update, the next launch refreshes an existing install.

The app refuses to write when:

- `~/.vibe` or either file is a symlink;
- `hooks.toml` has an unpaired marker, a marker inside a multi-line string, or
  a string left open;
- `hooks.toml` defines `hooks` as a plain array or table;
- a hook named `localvoxtral-files` or `localvoxtral-turn` exists outside the
  block;
- a key follows the block before the next table header;
- the file changed while the app was editing it.

The row then reads "hooks.toml needs a manual fix." or reports the failure.

The same install by hand:

1. Copy the shim:

```sh
mkdir -p ~/.vibe/localvoxtral
cp publish.sh ~/.vibe/localvoxtral/publish.sh
```

2. Append the block in `hooks.toml` to `~/.vibe/hooks.toml`, creating the file
   if it does not exist. The block is two `[[hooks]]` tables between
   `# >>> localvoxtral >>>` and `# <<< localvoxtral <<<`. It is valid at the end
   of a file whose hooks are `[[hooks]]` tables too. If yours are written as
   `hooks = [...]` or under `[hooks]`, rewrite them as `[[hooks]]` tables first:
   TOML cannot mix the two.

Vibe reads `hooks.toml` when a session starts. Sessions already running keep
their old hooks.

If you set `VIBE_HOME`, use that directory instead of `~/.vibe` in both steps
and in the two `command` lines.

## On an ssh host

For a Vibe running on a host you ssh into, enroll the host first
([remote setup](../../docs/remote-claude-context.md)). The host's setup run
installs the Vibe hooks when it finds `vibe` there, next to the Claude Code
plugin. For a host enrolled before Vibe was installed on it, press **Update Host…**
on its row in **Settings → Remote hosts**. That page lists the four ssh commands
the step runs.

The host needs `vibe`, `curl` 7.55 or newer, and the Python interpreter Vibe
runs on. Nothing is installed with pip: `remote/compact.py` uses the standard
library only.

On the host, each hook runs `remote/post.sh`:

1. It reads the token and port from 0600 files next to it. The token goes into a
   shell variable that was unset first, then into a private header file for
   curl. It is in no command line and in no child's environment.
2. It runs `compact.py` on the interpreter that is running Vibe. A `post_tool`
   payload contains whole files, so the script keeps the session id, the working
   directory, the file path and up to 2048 characters each of the edit strings
   or the file read, and drops the rest. It reads the last user message from the
   session log under the rules above.
3. It posts at most two small requests to the tunnel, with `X-Lvx-Agent: vibe`,
   one second each. After a failed dial it skips file hooks for five minutes, so
   a Mac that is asleep does not make ssh print errors over your terminal.
4. The first time a session's hook reaches the Mac, it leaves one background
   shell that waits for that Vibe process to exit and then tells the Mac the
   session ended. Vibe has no hook for that, and the Mac cannot check a process
   on another machine. Set `LOCALVOXTRAL_VIBE_WATCHER=off` in Vibe's environment
   to turn it off. Sessions then expire after four idle hours.
5. When the Mac's reply carries `X-Lvx-Terms: wanted`, it starts `terms.sh`
   detached, once per project per 24 hours, and returns. `terms.sh` runs a
   read-only `vibe -p` in the project and posts its answer, the project's own
   names, to the Mac
   ([Terms from the coding agent on a host](../../docs/remote-claude-context.md#terms-from-the-coding-agent-on-a-host)).
   It runs under a Vibe home of its own, under `~/.vibe/localvoxtral/remote/vibe-home/`, so
   none of your hooks fire and the run stays out of your Vibe history.

It prints nothing and always exits 0.

One machine can hold both blocks, the local one and the remote one. Their
markers and hook names differ.

## Uninstall

Delete the marked block from `~/.vibe/hooks.toml` and remove
`~/.vibe/localvoxtral/`.

## Telling Vibe you dictate

**Settings → Mistral Vibe → Tell Mistral Vibe you dictate → Add** puts a short
note in `~/.vibe/AGENTS.md` saying your prompts come from speech-to-text. See
[Telling the agent you dictate](../../docs/coding-agents.md#telling-the-agent-you-dictate).

## What is published

Vibe 2.25 has three hook types: `pre_tool`, `post_tool` and `post_agent`. This
integration uses two.

| Vibe hook | When | Record sent |
|---|---|---|
| `post_tool` on a file read, write or edit | the tool ran | the file's path, marked read or edited |
| `post_agent` | a turn ended | the turn ended |

Both also send the session id, the working directory, the Vibe process id and
start time, its terminal device, and the herdr or cmux pane handle when there is one.

Vibe has two hook runners and picks one per account through a server-side
rollout. localvoxtral supports both. They differ in what a hook receives:

| | Legacy runner | Unified Harness |
|---|---|---|
| File tools | `read_file`, `write_file`, `edit` | `file_system.read_file`, `file_system.write_file`, `file_system.search_replace` |
| Session id | in the payload | none, so the session is named after the Vibe process (pid and start time) |
| Session log path | in the payload | none, so no prompt is sent |
| Subagent marker | `parent_session_id` | none |
| Edit excerpts (ssh host only) | the edit's old and new strings, cut short | none: `search_replace` keeps them in `blocks`, which is not read |

`vibe --legacy-harness` and `vibe --experimental-harness` choose a runner by hand.

No Vibe hook payload carries your prompt. On the legacy runner the publisher
reads it from the session's `messages.jsonl`, whose path Vibe passes to every hook. It reads the
last 512 KiB of that file and keeps one thing: the newest message with role
`user` and `injected: false`, cut to 8 KiB. It does not parse lines that lack
the user-role marker, which covers assistant messages, reasoning, tool calls
and tool results, and it never sends the file path. If the read takes longer
than 250 ms, the hook publishes without a prompt.

File contents, tool output and shell commands are never sent. A `post_tool`
payload contains the tool's output, and the publisher discards it after
parsing.

With **Ask the coding agent for each new project's terms** on, the app also
runs its own read-only `vibe -p` once per project, never in your session. It
bills your Mistral key, capped at $0.30 a run (about $0.05–0.10 measured), and
runs under an app-owned `VIBE_HOME` so none of your hooks fire; see
[Terms from your coding agent](../../docs/dictation.md#terms-from-your-coding-agent).

## Limits that come from Vibe's hook set

- Vibe has no session-start hook. localvoxtral learns about a session at its
  first file-tool call or when its first turn ends, so the first dictation into
  a new session has no session context.
- Vibe has no session-end hook. A session ends for localvoxtral when its
  process exits or after the registry's idle timeout. The app compares the
  process start time as well as the pid, so a reused pid does not revive a
  finished session.
- Hooks fire for subagents too. On the legacy runner the publisher drops any
  payload with a `parent_session_id`, so a subagent's files never count as
  yours. The Unified Harness does not mark them, so there a subagent's files
  count toward the session of the pane it runs in.
- On the Unified Harness the session context has no prior prompt.
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
