# Terminals and coding agents

Prompt Claude Code, or any CLI coding agent, by voice, and the words stream
in live. Most dictation tools fall apart in a terminal, and localvoxtral
makes it its main target.

SSH sessions work too, since the text is typed into your local terminal.

## Dictate into a terminal

localvoxtral detects terminal apps on its own: Terminal, iTerm2, Ghostty,
Warp, WezTerm, kitty, Alacritty, Hyper, Tabby, Rio, and more. To add an app
that embeds a terminal, open **Settings → Terminals → Add app…**; the app's
own pane there removes it again.

The list lives in the app. A terminal list file from an older version is
imported once at launch.

In a terminal, live dictation changes in two ways:

- **Prompt-safe output.** Newlines and tabs are typed as spaces. A stray line
  break never submits a half-finished prompt, and a tab never triggers shell
  completion.
- **Secure input handling.** Secure Keyboard Entry turns on at a sudo password
  prompt, for example. While it is active, a live session refuses to start
  instead of typing into the void, and an overlay commit copies the text to
  the clipboard instead.

## Jump to the agent that needs you

The needs-you cue, Tab to a waiting agent, and the voice commands that name,
reach and send to sessions are in
[Work with several agents](agents.md).

## Polishing

When an Overlay Buffer dictation commits, optional LLM polishing cleans it up
for how developers talk. The toggles below sit in **Settings → Text
Processing → Polishing**, except context, which sits in **Settings →
Context**.

- **Polish while you speak** (on by default with the bundled helper, off
  with Mistral API or an external URL). A long dictation is polished a few
  sentences at a time while you speak, so the stop waits about 1 s instead of
  4 s with the bundled helper. Each piece resends the polishing instructions,
  so a long dictation sends about 3 times the input tokens, which a paid
  endpoint bills. With it off, the whole text is polished at the stop. About 1 word in
  100 comes out differently because each piece is polished without the words
  that follow it.
- **Agent prompt profile in terminals and Claude Desktop** (on by default).
  In a terminal, or in a Claude Code session in Claude Desktop's Code tab,
  polishing switches to an agent-tuned prompt, described below.
- **Model-first polishing.** Polishing keeps the model's final wording and
  technical formatting, so useful Markdown and reconstructed identifiers
  survive.
- **Context** (opt-in). File names from your repository, your clipboard,
  the agent's screen and its session can reach the polisher to get
  technical spellings right. See
  [Polish context: what each toggle sends](#polish-context-what-each-toggle-sends).
- **"Paste clipboard" macro** (on by default). Say "paste clipboard"
  mid-dictation, and the clipboard content goes in as a code block when the
  text commits.

The agent-tuned prompt turns spoken symbol forms into written ones. "Dash
dash force" becomes "--force", "src slash auth" becomes "src/auth", and "the
dot env file" becomes ".env". An issue or PR number becomes a GitHub
reference the agent can look up: "PR seven twelve" becomes "PR #712".

It puts backticks around code-like tokens, and only those. Filler words go,
self-corrections resolve to the final intent, and explicit enumerations
become lists.

Claude Desktop also hosts plain chat, so it gets the agent-tuned prompt only
when the dictation joined a Code-tab session or goes to a Claude project's
page. That needs **Send diff, recent
files and prompts** in **Settings → Context**. When the polisher is not
on this Mac (the Mistral API, say), it also needs **Send context to non-local
polishing servers**. With either off, Claude Desktop gets the standard prompt.

### Repo vocabulary

Turn on **Send repo file names** in **Settings → Context**. localvoxtral
then indexes the focused repository with a single sandboxed git file
listing, and up to 12 of its terms reach the polisher, so "use auth dot t s"
comes out as "useAuth.ts". The terms in the repository's dictation file join
the index (see [Add project terms](#add-project-terms)).

The repository is the working directory of the Claude Code session the
dictation joined, when that session runs on this Mac, Claude Desktop
included. Otherwise localvoxtral finds it from the terminal tab's title or
the programs running in it. An ambiguous repository sends no hints.

If a phrase you said matches a name exactly once, ignoring case and
separators, localvoxtral corrects it before the polisher runs. A single
spoken word is corrected only when it differs from the name by letter case
alone.

A name that only sounds like what you said goes to the polisher as a
candidate, and the polisher decides from the sentence. It gets a handful of
candidates, more for a long dictation. It never gets one with a file
extension you didn't say, and a candidate never rewrites the model's output.

## Add project terms

With **Send repo file names** on, localvoxtral also reads the repository's
`.github/dictation.md`, the file VS Code's dictation reads too. Write the
terms your project uses there:

```markdown
- Voxtral — the speech model
- **Claude Code**: the agent
- `useAuth.ts`
```

localvoxtral uses only the file's terms, which are inline code spans and the
first words of a list item up to a dash or colon. Headings, paragraphs and fenced blocks are
ignored.

None of the file's text reaches the polisher except a term the transcript
matched.

A coding agent can add a term by editing this file, and the next dictation in
that repository uses it.

## Polish context: what each toggle sends

Each **Settings → Context** toggle is named for what it sends.

By default, the first four sources run only while the polisher runs on this
Mac (the bundled helper). **Send context to non-local polishing
servers** is the only toggle that lifts that limit.

- **Send repo file names** reads file names from the git repository you are
  working in, and the terms in its dictation file
  ([Repo vocabulary](#repo-vocabulary)).
- **Send clipboard excerpt** sends an excerpt of your clipboard text to the
  polisher, sanitized and length-capped, used only as a spelling reference.
- **Send agent's terminal screen** reads file and identifier names from your
  coding agent's terminal to fix spellings. When that terminal runs a joined
  Claude Code or opencode session, part of the text on screen also goes to
  the polisher, verbatim. It works in Ghostty, iTerm2, Terminal.app, cmux and
  herdr panes only. In cmux it also needs the cmux join (see
  [Join sessions in cmux](#join-sessions-in-cmux)).
- **Send diff, recent files and prompts** sends your uncommitted changes,
  the files the agent recently touched, the last request you sent that
  session and, for a Claude Code session with the localvoxtral mod, what
  its prompt box holds unsent. It needs one of these: a joined Claude Code or opencode session in
  a supported terminal, a Claude Code Remote Control session in the focused
  browser tab, or a Claude Code session focused in Claude Desktop's Code tab.
  For a session on a remote host, only the session request and the short
  excerpts its hooks report go, and no files are read from that host.
- **Send context to non-local polishing servers**, when on, also sends the
  context enabled above to the polishing endpoint you configured. Enable it
  only for an endpoint you trust, such as a server on your own network.

### Join sessions in cmux

The **Join sessions in cmux** toggle and its **Socket password** row sit in
**Settings → Terminals → cmux**. The
[plugin README](../integrations/claude-code/README.md#which-terminal-am-i-dictating-into)
covers their setup.

The join uses cmux's automation socket, which you must first switch to
**Password** mode, to read the surface id cmux gives the session. It reads
that surface as context, and works for local surfaces and for sessions
opened with cmux ssh.

Once joined, the dictation goes into that surface through the same socket,
so it lands there even if you switch windows while you speak. If cmux does
not confirm the text arrived, it is not typed anywhere else and stays in
History.

Your Keychain stores the socket password, and localvoxtral sends it only to
cmux's local socket. Saving an empty field removes it.

## Dictating into Claude Code

localvoxtral ships a
[Claude Code plugin](../integrations/claude-code/README.md) that tells
localvoxtral what your Claude Code session is doing. When you dictate into
that session, polishing draws on:

- the session's **visible screen**: the exact pane you're dictating into, the
  one you and Claude are both looking at;
- your **previous prompt** and the session's **working directory**;
- the **files Claude just read or edited**, which hold the identifiers you're
  most likely to say next;
- that repository's **vocabulary**, from the
  [repo vocabulary](#repo-vocabulary) index, using the directory the session
  reports instead of guessing from the tab title.

So a misheard "useAuth.ts", the branch name you mentioned two turns ago, or
the flag Claude just wrote into a file come out spelled right.

The plugin is hooks-only. It spends none of your tokens, adds nothing to
Claude's context, and cannot slow a turn down, because every hook fails open
if the app isn't running.

Here it is inside a [herdr](../integrations/herdr/README.md) multiplexer.
The join binds to the exact Claude pane and uses that pane's screen as
context, while the neighboring pane stays out of the prompt:

<!-- herdr demo video: recorded by the old herdr scene of record-demo.yml, replaced by the story in #1847; its clips replace this URL once published. -->

https://github.com/user-attachments/assets/15e71c26-3d8b-490f-90d0-f5c507daf5eb

### Install the Claude Code plugin

1. Open **Settings → Claude Code → Plugin**.
2. Click **Install or update**. The app registers its bundled plugin
   marketplace through Claude Code's own CLI.

The same pane offers the opt-in status-line indicator. After a one-sentence
consent, it writes exactly the status line setting in your Claude Code
settings file, and never over your own script.

### Work over SSH

A second plugin, localvoxtral-remote, covers Claude Code sessions on other
machines. Its hooks report through an SSH port forward back to your Mac.
[Remote Claude Code context over SSH](remote-claude-context.md) covers the
setup, what a host can and cannot send, and its token.

### What the plugin shares

An allowlist of session metadata crosses a private local socket.
Transcripts, file contents and shell commands never do. The
[plugin README](../integrations/claude-code/README.md) documents the exact
fields and the threat model.

### How a dictation finds its session

localvoxtral joins a dictation to a session only on an exact match. Any
ambiguity attaches no context at all, and no join ever reads a window title.
What each join matches is in [the integration matrix](integration-matrix.md),
with the reasons some combinations don't join.

What you set up depends on where the session runs:

- **Ghostty, iTerm2 or Terminal.app**: allow the Automation permission the
  first dictation asks for. Ghostty needs 1.4 or newer (today the
  [tip channel](https://ghostty.org/docs/install/pre)).
- **A [herdr](../integrations/herdr/README.md) pane**: nothing.
- **[cmux](https://github.com/manaflow-ai/cmux)**: turn on
  [Join sessions in cmux](#join-sessions-in-cmux).
- **A plain ssh shell on an enrolled host**: add the shell block Settings
  offers, which publishes your terminal's TTY into the session. It works
  through jump hosts and shared connections
  ([A plain ssh host session](../integrations/claude-code/README.md#a-plain-ssh-host-session)).
- **Claude Code Remote Control** (the agent runs on a machine of yours and
  [claude.ai/code](https://claude.ai/code) in Chrome, Brave or Safari is the
  UI): allow the Automation permission for the browser.
- **Claude Desktop's Code tab**, with the session on your Mac or on an ssh
  host: nothing on this Mac. An ssh host needs
  [Keep the tunnel open](remote-claude-context.md#keep-the-tunnel-open-for-sessions-with-no-terminal).

## Connect opencode, Mistral Vibe and Codex

**opencode.** Install the [opencode plugin](../integrations/opencode/README.md)
from **Settings → opencode**. The row copies the plugin and adds its entry to
opencode's TUI config, and the same row reverses both.

**Mistral Vibe.** Install the
[Mistral Vibe hooks](../integrations/vibe/README.md) from **Settings →
Mistral Vibe**. The row adds a hook script and a marked block in Vibe's
hooks file, and the same row removes both.

Vibe has no session-start hook. localvoxtral learns about a Vibe session at
its first file read or edit, or when its first turn ends.

**Codex.** Install the [Codex plugin](../integrations/codex/README.md) from
**Settings → Codex**, which runs Codex's own plugin commands. Codex runs a
plugin's hooks only after you trust them:

1. Start Codex. It shows **Hooks need review**.
2. Choose **Trust all and continue** to turn the hooks on.

The row's dot turns green once a Codex hook has reached localvoxtral. A Codex
session then joins like a Claude Code one, on its terminal's TTY or its herdr
or cmux pane. The join brings its last prompt, working directory and the
files it patched.

## Telling the agent you dictate

Each agent's pane in Settings (Claude Code, opencode, Mistral Vibe, Codex)
has a **Tell … you dictate** row. **Add** puts a short note in that agent's
user-level instructions file, saying your prompts come from speech-to-text.

The note asks the agent to fix an obvious transcription error itself, and to
ask before acting when a likely error changes the request. It also asks the
agent to propose what it creates or renames with
[the localvoxtral command](#the-localvoxtral-command), and names
`localvoxtral doctor` for when dictation misbehaves.

**Remove** takes the note out. A note added by an older version reads as
another version, with an **Update** button.

| Agent | File |
|---|---|
| Claude Code | `~/.claude/CLAUDE.md` |
| opencode | `~/.config/opencode/AGENTS.md`, or `~/.claude/CLAUDE.md` when that file does not exist |
| Mistral Vibe | `~/.vibe/AGENTS.md` |
| Codex | `~/.codex/AGENTS.override.md` when it is not blank, else `~/.codex/AGENTS.md` |

opencode reads only the first of its two files that exists, so creating
`~/.config/opencode/AGENTS.md` would stop it from reading your
`~/.claude/CLAUDE.md`. For that reason the note goes into whichever file
opencode reads today, and Claude Code and opencode then share it.

Likewise, Codex reads only its override while that file is not blank, so the
note goes into the override then.

The note sits between `<!-- begin localvoxtral dictation note -->` and
`<!-- end localvoxtral dictation note -->`. The app writes only between those
lines, and only when you press the button.

A file that is a symlink, or that holds only one of the two lines, is left
alone, and the row then says so. The app does not see `VIBE_HOME`,
`CODEX_HOME` or `CLAUDE_CONFIG_DIR`. If you moved one of those directories,
copy the note by hand.

## Teaching the agent to check dictation

Each agent's pane also has a **Teach … to check dictation** row. **Add**
installs a skill named `localvoxtral-doctor` in that agent's skills
directory. A skill is a file the agent loads only when a task needs it; until
then, only its one-line description sits in the agent's context. This one
names `localvoxtral doctor` and `localvoxtral logs` and says what each
reports, so an agent asked why a dictation did not join runs them without
being told.

| Agent | Skill |
|---|---|
| Claude Code | `~/.claude/skills/localvoxtral-doctor/SKILL.md` |
| opencode | `~/.config/opencode/skills/localvoxtral-doctor/SKILL.md` |
| Mistral Vibe | `~/.vibe/skills/localvoxtral-doctor/SKILL.md` |
| Codex | `~/.codex/skills/localvoxtral-doctor/SKILL.md` |

opencode also loads Claude Code's skills, so with only Claude Code's row set
up, opencode has the skill too. **Remove** deletes the file, and its
directory unless you put another file there. A skill you edited, or one from
an older version, reads as another version, with an **Update** button that
replaces it. The remote Claude Code plugin ships the same skill, so a
session on an enrolled host has it without this row.

## The localvoxtral command

A coding agent can read your dictation history and your terms, propose terms
of its own, and find out why dictation misbehaves, with the localvoxtral
command.

### Install the command

1. Open **Settings → General → Command-line tool**.
2. Click **Install…**. The app links /usr/local/bin/localvoxtral to the copy inside
   the app, so app updates update it too.

macOS asks for your password when /usr/local/bin is not yours to write.

### Use the command

```text
localvoxtral history search "mac queue" --since yesterday --project .
localvoxtral history last
localvoxtral terms list --project .
localvoxtral terms propose Featherline QuillDoc --project .
localvoxtral status
localvoxtral doctor
localvoxtral logs --join --since 3h
```

- Every command takes `--json`.
- `--project` takes a directory or a project name. A directory stands for its
  whole repository, so passing any worktree gives the same answer as passing
  the main checkout.
- `--since` takes `today`, `yesterday`, `3d`, `12h`, `30m`, `2w` or a date.

Under **History → Don't keep**, `history` answers with nothing.

The command talks to the running app over the same private socket the hooks
use. It opens no network port, and only processes running as you can reach
it. It needs the app running, and exits with status 3 when it is not.

### Find out what is wrong

`doctor` prints numbered checks: which copy of the app runs and where
/usr/local/bin/localvoxtral points, the microphone and Accessibility
permissions, the speech and polish engines, the Claude Code and Codex
plugins, the opencode plugin, the Vibe hooks, the note in each agent's file,
each remote host with its sessions still on an older plugin, and the
sessions the last five dictations joined. Each problem comes with the step
that fixes it, and `--json` gives each check a stable `id`. It changes
nothing. It prints no dictated text and no key, but it names your remote
hosts and their sessions' folders. It exits with status 4 when a check
failed.

`logs` reads the app's lines from the macOS unified log, and works while the
app is not running: one line per dictation saying which session it joined
and why (`--join`), and without `--join`, the app's errors too. It covers the
last hour unless `--since` says otherwise. It prints what `log show` prints,
so a value the app logs as private stays `<private>`, and the app never logs
dictated text in the clear.

### On a remote host

On an enrolled host, only `localvoxtral doctor` runs. What it checks there
is in [Checking the setup](remote-claude-context.md#checking-the-setup).

### Proposed terms

A proposed term joins the project's terms like the agent's own proposals,
under the same rules
([Terms from your coding agent](dictation.md#terms-from-your-coding-agent)).
The note from [Telling the agent you dictate](#telling-the-agent-you-dictate)
tells your agents to propose what they create or rename.

The project's terms in **Settings → Projects** list it as "Proposed by" the
agent that ran the command. Claude Code, Codex and opencode are detected.
Vibe is not, so its proposals read "Proposed by a coding agent". To have
them name Vibe, ask it to add `--agent vibe` in a line of
`~/.vibe/AGENTS.md` outside the note. An edit inside the note makes the row
offer **Update**, which undoes it.

A proposal from the command does not use up the project's one ask. With
**Ask the coding agent for each new project's terms** on, the app still asks
the agent once.

## Projects

**Settings → Projects** lists every project localvoxtral has terms for, under
its repository's name, or `owner/repository` when two share a name: its
repository, where it is checked out, when you last used it and how many terms
it holds. The projects are:

- a checkout on this Mac that a dictation joined;
- a repository on an ssh host where a session has run, when the host runs
  the remote plugin 1.13.0 or later. A repository no hook names for 90 days
  is dropped;
- with an older plugin, the folder a session ran in, which is a worktree's
  name when the session ran in one. It stays on the list for 7 days after
  that session's last hook;
- a repository with an `origin` that Claude Code worked in during the last
  30 days, on this Mac or on an ssh host with remote plugin 1.32.0 or
  later, read from Claude Code's session history. It leaves the list 30
  days after that work unless a dictation used it since.

A repository checked out both on this Mac and on a host is one project. How
checkouts and worktrees make one project is in
[One project per repository](dictation.md#one-project-per-repository).
The terms outside every project close the table as **No project**.

Click a project to see its repository and checkouts, its learned terms
([Terms learned from polishing](dictation.md#terms-learned-from-polishing)),
and its joined sessions and dictations this week.

**Forget Project…** in a project's sheet deletes its records and learned
terms, on every checkout of its repository. It comes back the next time you
dictate there or a session on an ssh host reports it; Claude Code working
in it is not enough. `forgotten-projects.json` remembers it until then.
If that file can't be read, **Settings → Projects** says so and agents add
no project until you choose **Start Over…**, which renames the file.
**Ignore Project…** also forgets it, then keeps it out: localvoxtral learns
nothing there and its coding agent is never asked for its terms. Dictation
there works as before. Both ask first and offer **Export Terms…** when the
project has terms. Ignored projects are listed under **Ignored**, at the
bottom of **Settings → Projects**, each with **Un-ignore**. The list is kept
in `ignored-projects.json`, beside `learned-terms.json`.

### Keep work and personal projects apart

The **Group** column puts a project in **Work** or **Personal**. A dictation
joined to a project in a group then reads only that group's projects
wherever it reads more than its own: the project names every polish
carries and the confirmed terms the second pass sends. A dictation with no
join, or joined to a project in no group, reads every project, as before.

### Each project's repository

A project's repository is the GitHub repository its `origin` remote points
at. The app reads it from a checkout on this Mac; a host sends it from
remote plugin 1.23.0 or Vibe hooks 1.8.0 (an `origin` off GitHub needs
1.26.0 or 1.11.0 to join its Mac checkout). A project whose `origin` is not
on GitHub, or that has none, shows **None**; an `origin` is changed in git.
