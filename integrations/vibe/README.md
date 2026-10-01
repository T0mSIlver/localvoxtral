# localvoxtral hooks for Mistral Vibe

The Vibe hooks let localvoxtral use what your
[Mistral Vibe](https://docs.mistral.ai/vibe/code/cli/install-setup) session
is doing to transcribe your dictation. They work on this Mac and on an ssh
host.

## What you get

When you dictate into a Vibe pane, localvoxtral grounds the transcription on
that session's last prompt, its working directory and the files it just
touched. It does this without reading your screen.

## Install

1. In localvoxtral, open **Settings → Mistral Vibe → Hooks → Set up…**. One
   consent sentence names both files the app writes.
2. Confirm. The app copies its bundled [hook script](publish.sh) to
   `~/.vibe/localvoxtral/` and adds its marked [block of hooks](hooks.toml)
   to `~/.vibe/hooks.toml`.
3. Start a new Vibe session. Vibe reads its hooks when a session starts, so
   sessions already running keep their old hooks.

The app creates the hooks file when it is absent, and writes only between the
block's two markers. After an app update, the next launch refreshes an
existing install.

The app refuses to write when:

- `~/.vibe` or either file is a symlink;
- `~/.vibe/hooks.toml` has an unpaired marker, a marker inside a multi-line
  string, or a string left open;
- `~/.vibe/hooks.toml` defines its hooks as a plain array or table;
- a hook named `localvoxtral-files` or `localvoxtral-turn` exists outside the
  block;
- a key follows the block before the next table header;
- the file changed while the app was editing it.

The row then reads "hooks.toml needs a manual fix." or reports the failure.

### Install by hand

1. Copy [the hook script](publish.sh):

    ```sh
    mkdir -p ~/.vibe/localvoxtral
    cp publish.sh ~/.vibe/localvoxtral/publish.sh
    ```

2. Append the block in [hooks.toml](hooks.toml) to `~/.vibe/hooks.toml`,
   creating the file if it does not exist. The block is two `[[hooks]]`
   tables between `# >>> localvoxtral >>>` and `# <<< localvoxtral <<<`.

3. Start a new Vibe session.

The block is valid at the end of a file whose hooks are `[[hooks]]` tables
too. If yours are written as `hooks = [...]` or under `[hooks]`, rewrite them
as `[[hooks]]` tables first, because TOML cannot mix the two.

If you set `VIBE_HOME`, use that directory instead of `~/.vibe` in both steps
and in the block's two command lines.

## On an ssh host

For a Vibe running on a host you ssh into:

1. Enroll the host first
   ([remote setup](../../docs/remote-claude-context.md)). The host's setup run
   installs the Vibe hooks when it finds Vibe there, next to the Claude Code
   plugin.
2. If you enrolled the host before you installed Vibe on it, press
   **Update Host…** on its row in **Settings → Remote hosts**. The remote
   setup page lists the four ssh commands this step runs.

The host needs Vibe, curl 7.55 or newer, and the Python interpreter Vibe runs
on. Nothing is installed with pip, because
[the compaction script](remote/compact.py) uses the standard library only.

One machine can hold both blocks, the one for this Mac and the one for a
host. Their markers and hook names differ.

### What the host hook does

On the host, each hook runs [the host hook script](remote/post.sh). It prints
nothing and always exits 0.

- **It keeps the token out of sight.** It reads the token and port from 0600
  files next to it. The token goes into a shell variable that was unset
  first, then into a private header file for curl. It is in no command line
  and in no child's environment.
- **It cuts payloads down.** A file-tool hook's payload contains whole files.
  The compaction script, run on the interpreter that runs Vibe, keeps the
  session id, the working directory, the file path, and up to 2048
  characters each of the edit strings or the file read. It drops the rest.
- **It reads your last prompt** from the session log, under the same rules as
  on the Mac (see [What it sends](#what-it-sends)).
- **It posts at most two small requests** to the tunnel, marked as coming
  from Vibe, one second each. The Mac's reply says whether it wants project
  terms, a README or a quick-capture draft; the header names are in
  [post.sh](remote/post.sh). After a failed dial it skips file hooks for
  five minutes, so a Mac that is asleep does not make ssh print errors over
  your terminal.
- **It watches for the session's end.** The first time a session's hook
  reaches the Mac, it leaves one background shell that waits for that Vibe
  process to exit and then tells the Mac the session ended. Vibe has no hook
  for that, and the Mac cannot check a process on another machine.
- **It fetches project terms when the Mac asks.** It then starts a detached
  helper, once per project per 24 hours, and returns. The helper runs a
  read-only, non-interactive Vibe in the project and posts its answer, the
  project's own names, to the Mac
  ([Terms from the coding agent on a host](../../docs/remote-claude-context.md#terms-from-the-coding-agent-on-a-host)).
- **The terms run stays out of your Vibe.** The helper runs under a Vibe home
  of its own, under `~/.vibe/localvoxtral/remote/vibe-home/`, so none of your
  hooks fire and the run stays out of your Vibe history.
- **It helps with quick capture when the Mac asks.** It starts a detached
  helper that posts the first 16 KiB of the project's README, or drafts a
  quick capture with a read-only, non-interactive Vibe in the project and
  posts the draft
  ([Quick capture on a host](../../docs/remote-claude-context.md#quick-capture-on-a-host)).

To turn off the background shell, set `LOCALVOXTRAL_VIBE_WATCHER=off` in
Vibe's environment. Sessions then expire after four idle hours.

## Tell Mistral Vibe you dictate

**Settings → Mistral Vibe → Tell Mistral Vibe you dictate → Add** puts a short
note in `~/.vibe/AGENTS.md` saying your prompts come from speech-to-text. See
[Telling the agent you dictate](../../docs/coding-agents.md#telling-the-agent-you-dictate).

## Teach Mistral Vibe to check dictation

**Settings → Mistral Vibe → Teach Mistral Vibe to check dictation → Add** installs a
skill in ~/.vibe/skills that names `localvoxtral doctor` and `localvoxtral logs`. See
[Teaching the agent to check dictation](../../docs/coding-agents.md#teaching-the-agent-to-check-dictation).

## What it sends

Everything stays on this machine. The hooks publish bounded records to
localvoxtral's private UNIX socket, which checks the connecting user. When
the app is not running, each hook exits after one failed connect.

Vibe 2.25 has three hook types, which fire before a tool runs, after a tool
runs, and when the agent's turn ends. This integration uses the last two.

| Vibe hook | When | Record sent |
|---|---|---|
| After a file read, write or edit | the tool ran | the file's path, marked read or edited |
| End of turn | a turn ended | the turn ended |

Both also send the session id, the working directory, the Vibe process id and
start time, its terminal device, and the herdr or cmux pane handle when there
is one.

### The two hook runners

Vibe has two hook runners and picks one per account through a server-side
rollout. localvoxtral supports both. They differ in what a hook receives:

| | Legacy runner | Unified Harness |
|---|---|---|
| File tools | read file, write file, edit | the file-system read file, write file and search-and-replace |
| Session id | in the payload | none, so the session is named after the Vibe process (pid and start time) |
| Session log path | in the payload | none, so no prompt is sent |
| Subagent marker | a parent session id | none |
| Edit excerpts (ssh host only) | the edit's old and new strings, cut short | none, because search-and-replace keeps them in a part of the payload that is not read |

To choose a runner by hand, start Vibe with `vibe --legacy-harness` or
`vibe --experimental-harness`.

### Your prompt

No Vibe hook payload carries your prompt. On the legacy runner, the publisher
reads it from the session's message log, whose path Vibe passes to every
hook.

It reads the last 512 KiB of that file and keeps one thing: the newest
message you typed (role user, not injected by Vibe), cut to 8 KiB. It does
not parse lines that lack the user-role marker, which covers assistant
messages, reasoning, tool calls and tool results. It never sends the file
path.

If the read takes longer than 250 ms, the hook publishes without a prompt.

### What is never sent

File contents, tool output and shell commands are never sent. A file-tool
hook's payload contains the tool's output, and the publisher discards it
after parsing.

### Project terms

With **Ask the coding agent for each new project's terms** on, the app also
runs its own read-only, non-interactive Vibe once per project, never in your
session. It bills your Mistral key, capped at $0.30 a run (about $0.05 to
$0.10 measured). It runs under a Vibe home the app owns, so none of your
hooks fire. See
[Terms from your coding agent](../../docs/dictation.md#terms-from-your-coding-agent).

## What doesn't work

These limits come from Vibe's hook set.

- **No context on a session's first dictation.** Vibe has no session-start
  hook. localvoxtral learns about a session at its first file-tool call or
  when its first turn ends, so the first dictation into a new session has no
  session context.
- **No session-end hook.** A session ends for localvoxtral when its process
  exits or after the registry's idle timeout. The app compares the process
  start time as well as the pid, so a reused pid does not revive a finished
  session.
- **Subagent files on the Unified Harness.** Hooks fire for subagents too. On
  the legacy runner the publisher drops any payload that names a parent
  session, so a subagent's files never count as yours. The Unified Harness
  does not mark them, so there a subagent's files count toward the session of
  the pane it runs in.
- **No prior prompt on the Unified Harness.** Its session context has none.
- **No join for the VS Code extension and other ACP clients.** They have no
  terminal pane. Their sessions publish, but nothing can join a dictation to
  them. A non-interactive Vibe run typed into a pane keeps that pane's
  terminal, so it joins while it runs.

## Uninstall

Press **Remove** in **Settings → Mistral Vibe → Hooks**. It deletes the
block, the blank line before it and the hook script.

By hand, delete the marked block from `~/.vibe/hooks.toml` and remove
`~/.vibe/localvoxtral/`.

## Fix common problems

- **The row reads "hooks.toml needs a manual fix."** Your hooks file hits
  one of the cases the app refuses to write in (see [Install](#install)).
  Fix that case in the file.
- **A running session gets no context.** Vibe read its hooks when the session
  started. Start a new session.

## How it is built

Before changing anything here, read the
[invariants](../../docs/agent/invariants.md). Its Vibe entry states what the
session log read is limited to.

- **The hook script prints nothing and always exits 0.** Vibe reports a
  hook's non-zero exit or non-JSON output as a warning on your turn.
- **Neither hook is strict.** A strict hook turns its own failure into a
  denied tool call.
- **Each hook command discards errors and always succeeds.** A hooks file
  that still names a deleted script then does not fail every turn.
- **The hook script does not replace itself with the publisher.** If that
  replacement failed, its failure would become the hook's exit status.
- **The publisher finds the Vibe process by walking up.** Vibe starts each
  hook in a new session with no controlling terminal, and the shell it spawns
  the hook through may or may not still exist as the hook's parent. The
  publisher walks up from the hook script's parent process until it leaves
  the hook's own session, and publishes that process as the Vibe process.
