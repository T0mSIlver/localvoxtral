# Terminals and coding agents

Prompt Claude Code, or any CLI coding agent, by voice, and the words stream
in live. Most dictation tools fall apart in a terminal, and localvoxtral
makes it its main target.

SSH sessions work too, since the text is typed into your local terminal.

## Dictate into a terminal

localvoxtral detects terminal apps on its own: Terminal, iTerm2, Ghostty,
Warp, WezTerm, kitty, Alacritty, Hyper, Tabby, Rio, and more. To add an app
that embeds a terminal, open **Settings → Terminals → Add app…**.

The list lives in the app. A terminal list file from an older version is
imported once at launch.

In a terminal, live dictation changes in three ways:

- **Prompt-safe output.** Newlines and tabs are typed as spaces. A stray line
  break never submits a half-finished prompt, and a tab never triggers shell
  completion.
- **Replacements without rewriting.** Dictionary replacements apply before
  the text is typed. localvoxtral never backspaces over what the terminal has
  already drawn.
- **Secure input handling.** Secure Keyboard Entry turns on at a sudo password
  prompt, for example. While it is active, a live session refuses to start
  instead of typing into the void, and an overlay commit copies the text to
  the clipboard instead.

## Polishing

When an Overlay Buffer dictation commits, optional LLM polishing cleans it up
for how developers talk. The toggles below sit in **Settings → Text
Processing → Polishing**, except the two context sources, which sit in
**Settings → Context**.

- **Agent prompt profile in terminals and Claude Desktop** (on by default).
  In a terminal, or in a Claude Code session in Claude Desktop's Code tab,
  polishing switches to an agent-tuned prompt. The details follow this list.
- **Model-first polishing.** Polishing keeps the model's final wording and
  technical formatting, so useful Markdown and reconstructed identifiers
  survive.
- **Repo vocabulary** (opt-in, **Send repo file names**). Up to 12 terms from
  the focused repository reach the polisher, so "use auth dot t s" comes out
  as "useAuth.ts". See [Repo vocabulary](#repo-vocabulary).
- **Clipboard as context** (opt-in, **Send clipboard excerpt**). The polisher
  sees a sanitized excerpt of your clipboard to get technical spellings
  right.
- **"Paste clipboard" macro** (on by default). Say "paste clipboard"
  mid-dictation, and the clipboard content goes in as a code block when the
  text commits.

The agent-tuned prompt turns spoken symbol forms into written ones. "Dash
dash force" becomes "--force", "src slash auth" becomes "src/auth", and "the
dot env file" becomes ".env".

It puts backticks around code-like tokens, and only those. Filler words go,
self-corrections resolve to the final intent, and explicit enumerations
become lists.

Claude Desktop also hosts plain chat, so it gets the agent-tuned prompt only
when the dictation joined a Code-tab session. That needs **Send diff, recent
files and last prompt** in **Settings → Context**. When the polisher is not
on this Mac (the Mistral API, say), it also needs **Send context to non-local
polishing servers**. With either off, Claude Desktop gets the standard prompt.

The overlay shows a **Polished** badge whenever the LLM changed your text,
and the menu bar popover keeps the raw transcript one click away.

By default, clipboard, terminal screen and project context go only to a
polisher running on this Mac. To send the enabled context sources to a
non-local polishing endpoint you configured, turn on **Send context to
non-local polishing servers** in **Settings → Context**. Use it only with an
endpoint you trust.

### Repo vocabulary

localvoxtral indexes the focused repository with a single sandboxed git file
listing. The terms in the repository's dictation file join the index (see
[Add project terms](#add-project-terms)).

The repository is the working directory of the Claude Code session the
dictation joined, when that session runs on this Mac. Otherwise localvoxtral
finds it from the terminal tab's title or the programs running in it. An
ambiguous repository sends no hints.

Only high-confidence, boundary-checked matches are corrected in the working
text. Everything else stays a hint and never rewrites the model's output.

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

Each **Settings → Context** toggle is named for what it sends. Here is what
each name covers.

By default, the first four sources run only while the polisher runs on this
Mac (the bundled helper). **Send context to non-local polishing
servers** is the only toggle that lifts that limit.

- **Send repo file names** reads file names from the git repository you are
  working in, with one sandboxed git file listing, and the terms in its
  dictation file. Near-miss spellings then resolve to real names. The
  repository is that of a joined Claude Code session on this Mac, Claude
  Desktop included, or else your terminal's.
- **Send clipboard excerpt** sends an excerpt of your clipboard text to the
  polisher, sanitized and length-capped, used only as a spelling reference.
- **Send agent's terminal screen** reads file and identifier names from your
  coding agent's terminal to fix spellings. When that terminal runs a joined
  Claude Code or opencode session, part of the text on screen also goes to
  the polisher, verbatim. It works in Ghostty, iTerm2, Terminal.app, cmux and
  herdr panes only. In cmux it also needs the cmux join (see
  [Join sessions in cmux](#join-sessions-in-cmux)).
- **Send diff, recent files and last prompt** sends your uncommitted changes,
  the files the agent recently touched, and the last request you sent that
  session. It needs one of these: a joined Claude Code or opencode session in
  a supported terminal, a Claude Code Remote Control session in the focused
  browser tab, or a Claude Code session focused in Claude Desktop's Code tab.
  For a session on a remote host, only the session request and the short
  excerpts its hooks report go, and no files are read from that host.
- **Send context to non-local polishing servers**, when on, also sends the
  context enabled above to the polishing endpoint you configured. Enable it
  only for an endpoint you trust, such as a server on your own network.

### How names correct your words

If a phrase you said matches a name exactly once, ignoring case and
separators, localvoxtral corrects it before the polisher runs. "Use auth dot
ts" becomes "useAuth.ts". A single spoken word is corrected only when it
differs from the name by letter case alone.

A name that only sounds like what you said goes to the polisher as a
candidate, and the polisher decides from the sentence. It gets a handful of
candidates, more for a long dictation. It never gets one with a file
extension you didn't say.

### Join sessions in cmux

The **Join sessions in cmux** toggle and its **Socket password** row sit in
**Settings → Terminals → cmux**. The
[plugin README](../integrations/claude-code/README.md#which-terminal-am-i-dictating-into)
covers their setup.

The join uses cmux's automation socket to tell which session you are
dictating into, and reads that surface as context. It works for local
surfaces and for sessions opened with cmux ssh.

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

<!-- herdr demo video: recorded by record-demo.yml (terminal_agent=herdr); regenerate via that workflow and replace the URL below. -->

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
[Remote Claude Code context over SSH](remote-claude-context.md) walks through
the setup.

The host needs nothing beyond the plugin itself, which is two JSON files and
a small POSIX shell script. The script needs only sh and curl, which every
host already has. A per-host
token authenticates the hooks, and you can rotate or revoke it in Settings at
any time.

Remote context is limited to labels and short sanitized excerpts, and the app
never reaches into the remote filesystem.

### What the plugin shares

An allowlist of session metadata crosses a private local socket.
Transcripts, file contents and shell commands never do. The
[plugin README](../integrations/claude-code/README.md) documents the exact
fields and the threat model.

### How a dictation finds its session

localvoxtral joins a dictation to a session only on an exact match. Any
ambiguity attaches no context at all, and no join ever reads a window title.

| Where the session runs | What the join matches |
|---|---|
| Ghostty 1.4 or newer (today the [tip channel](https://ghostty.org/docs/install/pre)), iTerm2, Terminal.app | localvoxtral asks the terminal for the focused pane's TTY and matches it exactly against the session's. There is no title fallback, so older Ghostty versions don't join. |
| A [herdr](../integrations/herdr/README.md) pane | The join binds to the precise pane and reads its screen from herdr directly, so neighboring panes never leak into your prompt. |
| [cmux](https://github.com/manaflow-ai/cmux) (opt-in) | The surface id that cmux itself injects into the session, including shells opened with cmux ssh. |
| A plain ssh shell on an enrolled host | The same TTY, which your shell publishes into the session. |
| Claude Code Remote Control in a browser | The session id in the focused tab's URL. |
| Claude Desktop's Code tab | The session you have focused there. |

First use asks for one Automation permission per terminal or browser.

**cmux.** localvoxtral reads the surface id over cmux's own automation
socket, which you must first switch to **Password** mode. The
[plugin README](../integrations/claude-code/README.md#which-terminal-am-i-dictating-into)
covers the two-step setup.

Once joined, the dictation goes into that surface through the same socket,
so it lands there even if you switch windows while you speak. If cmux does
not confirm the text arrived, it is not typed anywhere else and stays in
History.

**Plain ssh.** Settings offers to add the one shell block that publishes the
TTY. Unlike a network-level match, it works through jump hosts and shared
connections. Details are in
[A plain ssh host session](../integrations/claude-code/README.md#a-plain-ssh-host-session).

**Remote Control.** In a Remote Control session, the agent runs on a machine
of yours and [claude.ai/code](https://claude.ai/code) in a browser is the UI.
localvoxtral matches the session id in the focused tab's URL exactly against
the id the session's own hooks report. This works in Chrome, Brave and
Safari, and a browser join never reads anything on screen.

**Claude Desktop.** The Code tab join works whether the desktop app runs the
session on your Mac or on an ssh host. It needs no extra permission and reads
nothing on screen.

An ssh host needs the remote plugin 1.11.0 or newer and **Keep the tunnel
open**, since Claude Desktop's ssh carries no tunnel. Host setup turns it on
when it finds Desktop there.

For each agent and terminal, [the integration matrix](integration-matrix.md)
lists what a join adds and why some combinations don't join.

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
[the localvoxtral command](#the-localvoxtral-command).

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

## The localvoxtral command

A coding agent can read your dictation history, your terms and your quick
captures, propose terms of its own, and mark a capture filed, with the
localvoxtral command.

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
localvoxtral capture list --project .
localvoxtral capture show "busy herdr pane"
localvoxtral capture filed "busy herdr pane" https://github.com/you/app/issues/42
localvoxtral status
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

### Quick captures

Tell your agent "look at the capture about the busy herdr pane". The command
calls an Inbox item a capture, not an issue, so the agent asks the command
instead of searching GitHub.

- `capture list` shows each capture's id, project, kind, age, state and
  title. The title is the draft's, or the capture's first words until it has
  a draft.
- `capture show` takes the title, any unique part of it, or the id, and
  prints the draft, your dictated words, the related issue and the
  repository it files in, followed by the body **File** would send.
- The command never files. The agent opens the issue with its own `gh`,
  then runs `capture filed` with the issue's URL. The capture then shows as
  filed on the Inbox page, as after **File**. The URL must be an issue in
  the capture's repository, and a capture that is still drafting or already
  filed is refused.

### Proposed terms

A proposed term joins the project's terms the way the agent's own proposals
do (see [Dictation](dictation.md)). It applies only where repo vocabulary
may, and three dictations or a **Pin** make it yours. A name written like
code (a type or function name, a file name, a path, a flag or an environment
variable) is refused as not a term.

**Show all** under the project's terms in **Settings → Projects** lists it
as "Proposed by" the agent that ran the command. Claude Code, Codex and
opencode are detected; Vibe passes `--agent vibe`.

A proposal from the command does not use up the project's one ask. With
**Ask the coding agent for each new project's terms** on, the app still asks
the agent once.

### Let your agents find the command

Add the note from the **Tell … you dictate** row (see
[Telling the agent you dictate](#telling-the-agent-you-dictate)). It tells
your agents to propose what they create or rename.

Vibe is not detected, so its proposals read "Proposed by a coding agent". To
have them name Vibe, ask it to add `--agent vibe` in a line of
`~/.vibe/AGENTS.md` outside the note. An edit inside the note makes the row
offer **Update**, which undoes it.

## Quick capture

Quick capture saves an idea that has no place in the app you are in, and
drafts it for one of your projects. Your words never reach the focused app.
They are saved in History, then shown on the **Inbox** page of the
localvoxtral window.

To capture, press Tab during a dictation until the overlay shows **Inbox**
([Where the words go](dictation.md#where-the-words-go)). You can also set the
optional **Quick capture to Inbox** shortcut in **Settings → Dictation**.

A capture then goes through four steps.

1. **Route.** A classifier picks one of your projects (see
   [Which projects a capture can go to](#which-projects-a-capture-can-go-to)).
   When it is unsure, or two projects tie, the capture stays unplaced.
2. **First draft.** Your polishing model sorts the capture as an **Issue**, a
   **Question**, a **Task** or a **Note** and writes a draft within
   seconds (see [How the draft is written](#how-the-draft-is-written)). A
   question shows its answer. A task or a note is restated and stays in the
   Inbox; it is never filed.
3. **Check against the code**, issues only. An agent reads the code the issue
   touches, corrects the draft, and lists the files it read. The row says
   **Checked against the code** when it is done. You don't have to wait for
   it.
4. **Review.** On the Inbox page you edit the draft, move the capture to
   another project, or discard it. **File** creates the issue with your
   GitHub CLI, with your dictated words quoted under the draft. The Inbox
   fills in the project's repository (see
   [Each project's repository](#each-projects-repository)). Your coding
   agent can also file it with its own `gh` ([Quick captures](#quick-captures)).
   You can also [review it by voice](#review-a-draft-by-voice). Nothing
   else files. A draft that failed has **Draft Again**.

### Review a draft by voice

With **Tell me when an agent needs you** on, a finished draft (for an issue,
once it is checked against the code) lights the
menu bar mark and the popover says "Draft ready: Inbox for localvoxtral".
There is no banner and no sound, and the cue waits for your next break: the
end of a dictation, or the end of a turn in the agent pane you are looking
at. An agent that needs you keeps the popover line; drafts add to its count.

When no agent waits, the **Answer the agent that needs you** shortcut opens
the oldest ready draft in the overlay and starts a dictation. The overlay
shows that one draft. When you stop, what you said decides:

- "file it" files the draft as the overlay shows it. It files nothing if
  the draft changed on the Inbox page in the meantime, or if it is a
  question, a task or a note.
- "drop it" discards it.
- Anything else is a change, such as "make it only the popover part". The
  agent drafts again from your first words, the draft and your change, and
  the new draft waits for your next break.

With [Press Return with "send it"](dictation.md#press-return-with-send-it)
on, "file it" or "drop it" alone, or a change followed by "send it", stops
the dictation after 3 seconds of silence.

### Which projects a capture can go to

The classifier picks from the projects **Settings → Projects** lists:

- a checkout on this Mac that a dictation joined;
- a repository on an ssh host where a session has run, when the host runs
  the remote plugin 1.13.0 or later;
- with an older plugin, the folder a session ran in, which is a worktree's
  name when the session ran in one. It stays on the list for 7 days after
  that session's last hook.

Per-worktree projects that an older plugin left in your learned terms are
not offered
([One project per repository](dictation.md#one-project-per-repository)).

A repository checked out both on this Mac and on a host is one project
here, drafted on this Mac. Its learned terms stay listed under each
checkout.

### Projects

**Settings → Projects** lists every project a capture can go to: where
**File** sends its issues, where it is checked out, when you last used it,
and the drafts waiting on it. A warning replaces the repository for a fork
you have not picked a repository for, and for a project with no GitHub
repository.

Click a project to see its repository and checkouts, its description, its
learned terms, and its joined sessions, captures and dictations this week.
**Open Inbox** goes to its drafts.

### Each project's repository

A project's repository is the GitHub repository its `origin` remote points
at. The app reads it from a checkout on this Mac; a host sends it from
remote plugin 1.23.0 or Vibe hooks 1.8.0. A project whose `origin` is not on
GitHub, or that has none, asks for `owner/repository` on its first capture
and keeps your answer. **Set…** or **Change…** in the project's
**Repository** group edits that answer; an `origin` on GitHub is changed in
git.

A fork files in your fork, since `origin` is yours. To file its captures in
the repository it was forked from, pick that repository in the project's
**File issues here**. Until you pick one, **Settings → Projects** marks the
fork.

### Describe your projects

The classifier reads each project's name, a description, the opening of its
README, its GitHub topics, and its learned terms. It reads the README from a
checkout on this Mac, or from what a remote project's host reports.

The description is the repository's description on GitHub, which your
GitHub CLI fetches once a week and whenever **Settings → Projects** opens.
A private repository works when `gh` can read it. Without a GitHub
description, the description is one sentence of up to 200 characters that
the coding agent writes in the same run as the terms, when **Ask the coding
agent for each new project's terms** is on
([Terms from your coding agent](dictation.md#terms-from-your-coding-agent)).
Until it answers, or with that setting off, it is the README opening.

A project's sheet in **Settings → Projects** shows its description and who
wrote it. **Edit…** replaces it with your own, such as "Menu bar dictation
app: shortcuts, polishing, quick capture and its Inbox". Save an empty
field to go back to the automatic one.

### Choose the classifier

**Settings → Context → Quick capture → Route quick captures with** picks it:

- **Polishing model**, the default, routes the capture wherever polishing
  runs. That is on this Mac for the bundled helper, and at the endpoint you
  configured otherwise.
- **Jev**, with a **Jev API key** set, sends the capture text and the project
  descriptions to Jev, TypeSafe's hosted classifier. The key is TypeSafe's,
  or a Vercel AI Gateway key starting `vck_`. When Jev fails, your polishing
  model routes the capture.

With no polishing model and no Jev key, every capture waits in the Inbox for
you to place it.

### How the draft is written

**First draft.** The app gathers the project's context in its checkout: the
README's opening, the rules for issues, tests and proof in its AGENTS.md or
CLAUDE.md, `git grep` hits for the capture's longer words, and, through your
GitHub CLI, the open issues, the last 40 closed issues and the last 20 merged
pull requests. It sends that and your words to your polishing model in one
request, at its lowest reasoning effort. On Mistral's API with GLM 5.3 that
is about 7,500 tokens in and 3,000 to 8,000 out.

An issue's draft has a title under 70 characters and the sections Problem,
Scope, Constraints, Proof, Links and Open questions. The first draft has not
read the code, so it can be wrong about it until the check lands.

**Check against the code.** For an issue, the first of Claude Code, Mistral
Vibe and opencode installed runs in the background with read-only tools,
starting from the first draft. Its draft replaces the first one, unless you
edited the first one meanwhile; then yours stays and the row says so. With
no polishing model, or when the first draft fails, the same run drafts the
issue from your words alone.

The run is capped at 20 turns, 6 minutes, and $0.50 (Claude Code) or $0.30
(Vibe) of your agent plan or API key. opencode has no price cap, so its run,
on your default model, is capped at 20 steps.

For a project on an ssh host, the host gathers the context and runs the check
in its own checkout, the next time a session there sends a hook
([Quick capture on a host](remote-claude-context.md#quick-capture-on-a-host)).
