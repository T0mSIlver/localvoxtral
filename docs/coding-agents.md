# Terminals & coding agents

Most dictation tools fall apart in a terminal. localvoxtral makes it its main
target. Prompt Claude Code, or any CLI
coding agent, by voice and the words stream in live. SSH sessions work too,
since the text is typed into your local terminal. localvoxtral detects
terminal apps on its own (Terminal, iTerm2, Ghostty, Warp, WezTerm, kitty,
Alacritty, Hyper, Tabby, Rio, and more). Add apps that embed a terminal in
**Settings → Terminals → Add app…**. The list lives in the app; a legacy
`terminal_apps.toml` is imported once at launch. In a terminal, live
dictation changes in three ways:

- **Prompt-safe output.** Newlines and tabs are typed as spaces, so a stray
  line break never submits a half-finished prompt and a tab never triggers
  shell completion.
- **Replacements without rewriting.** Dictionary replacements apply before
  the text is typed. localvoxtral never backspaces over what the terminal
  has already drawn.
- **Secure input handling.** If Secure Keyboard Entry is active (a `sudo`
  password prompt, say), a live session refuses to start instead of typing
  into the void, and an overlay commit copies the text to the clipboard
  instead.

## Polishing

When an Overlay Buffer dictation commits, optional LLM polishing cleans it up
for how developers talk:

- **Agent prompt profile in terminals and Claude Desktop** (on by default).
  When the target is a terminal or a Claude Code session in Claude Desktop's
  Code tab, polishing switches to an agent-tuned prompt. Spoken symbol forms
  become written ones ("dash dash force" → `--force`, "src slash auth" →
  `src/auth`, "the dot env file" → `.env`). Code-like tokens, and only those,
  get backticks. Filler words go, self-corrections resolve to the final
  intent, and explicit enumerations become lists. Claude Desktop also hosts
  plain chat, so it gets this prompt only when the dictation joined a
  Code-tab session. That needs **Send diff, recent files and last prompt** in
  **Settings → Context**. When the polisher is not on this Mac (the Mistral
  API, say), it also needs **Send context to non-local polishing servers**.
  With either off, Claude Desktop gets the standard prompt.
- **Model-first polishing.** Polishing keeps the model's final wording and
  technical formatting, so useful Markdown and reconstructed identifiers
  survive.
- **Repo vocabulary** (opt-in). localvoxtral indexes the focused repo with a
  single sandboxed `git ls-files`, and up to 12 relevant terms reach the
  polisher, so "use auth dot t s" comes out as `useAuth.ts`. The terms in the
  repo's `.github/dictation.md` join the index (see below). An ambiguous repo
  sends no hints. Only high-confidence, boundary-checked matches are
  corrected in the working text; everything else stays a hint and never
  rewrites the model's output. The repo is the working directory of the
  Claude Code session the dictation joined, when that session runs on this
  Mac. Otherwise localvoxtral finds it from the terminal tab's title or the
  programs running in it.
- **Clipboard as context** (opt-in). The polisher sees a sanitized excerpt
  of your clipboard to get technical spellings right.
- **"Paste clipboard" macro** (on by default). Say it mid-dictation and the
  clipboard content goes in as a code block when the text commits.

The overlay shows a **Polished** badge whenever the LLM changed your text,
and the menu bar popover keeps the raw transcript one click away.

By default, clipboard, terminal screen, and project context go only to a
polisher running on this Mac. To send the enabled context sources to a
non-local polishing endpoint you configured, turn on **Send context to
non-local polishing servers** in **Settings → Context**. Use it only with an
endpoint you trust.

## Project terms in `.github/dictation.md`

With **Send repo file names** on, localvoxtral also reads the repo's
`.github/dictation.md`, the file VS Code's dictation reads too. Only its terms
are used: inline code spans, and the first words of a list item up to a dash
or colon. Headings, paragraphs and fenced blocks are ignored, and none of the
file's text reaches the polisher except a term the transcript matched.

```markdown
- Voxtral — the speech model
- **Claude Code**: the agent
- `useAuth.ts`
```

A coding agent can add a term by editing this file, and the next dictation in
that repo uses it.

## Telling the agent you dictate

Each agent's pane in Settings (Claude Code, opencode, Mistral Vibe) has a
**Tell … you dictate** row. **Add** puts a short note in that agent's
user-level instructions file, saying your prompts come from speech-to-text:
the agent should fix an obvious transcription error itself and ask before
acting when a likely error changes the request, and should propose what it
creates or renames with [the `localvoxtral` command](#the-localvoxtral-command).
**Remove** takes it out. A note added by an older version reads as another
version, with an **Update** button.

| Agent | File |
|---|---|
| Claude Code | `~/.claude/CLAUDE.md` |
| opencode | `~/.config/opencode/AGENTS.md`, or `~/.claude/CLAUDE.md` when that file does not exist |
| Mistral Vibe | `~/.vibe/AGENTS.md` |

opencode reads only the first of its two files that exists, so creating
`~/.config/opencode/AGENTS.md` would stop it from reading your CLAUDE.md. For
that reason the note goes into whichever file opencode reads today, and
Claude Code and opencode then share it.

The note sits between `<!-- begin localvoxtral dictation note -->` and
`<!-- end localvoxtral dictation note -->`. The app writes only between those
lines, and only when you press the button. A file that is a symlink, or that
holds only one of the two lines, is left alone; the row then says so. The
app does not see `VIBE_HOME` or `CLAUDE_CONFIG_DIR`; if you moved either
directory, copy the note by hand.

## Polish context: what each toggle sends

Each **Settings → Context** toggle is named for what it sends. Here is what
each name covers.

The first four sources share one default: they run only while the polisher
runs on this Mac (the bundled helper). **Send context to non-local polishing
servers** is the only toggle that lifts that limit.

- **Send repo file names** reads file names from the git repo you are
  working in (one sandboxed `git ls-files`) and the terms in its
  `.github/dictation.md`, so near-miss spellings resolve to real names. That
  is the repo of a joined Claude Code session on this Mac, Claude Desktop
  included, or else your terminal's.
- **Send clipboard excerpt** sends an excerpt of your clipboard text to the
  polisher, sanitized and length-capped, used only as a spelling reference.
- **Send agent's terminal screen** reads file and identifier names from your
  coding agent's terminal to fix spellings. When that terminal runs a joined
  Claude Code or opencode session, part of the text on screen also goes to
  the polisher, verbatim. It works in Ghostty, iTerm2, Terminal.app, cmux,
  and herdr panes only. In cmux it also needs the cmux join (see below).
- **Send diff, recent files and last prompt** sends your uncommitted
  changes, the files the agent recently touched, and the last request you
  sent that session. For a session on a remote host, only the session
  request and the short excerpts its hooks report go, and no files are read
  from that host. It needs one of these: a joined Claude Code or opencode
  session in a supported terminal, a Claude Code Remote Control session in
  the focused browser tab, or a Claude Code session focused in Claude
  Desktop's Code tab.
- **Send context to non-local polishing servers**, when on, also sends the
  context enabled above to the polishing endpoint you configured. Enable it
  only for an endpoint you trust, such as a server on your own network.

How the names are used: if a phrase you said matches a name exactly once
case and separators are ignored ("use auth dot ts" → `useAuth.ts`), it is
corrected before the polisher runs. A single spoken word is corrected only
when it differs from the name by letter case alone. A name that only sounds
like what you said goes to the polisher as a candidate, and the polisher
decides from the sentence. It gets a handful of candidates, more for a long
dictation, and never one with a file extension you didn't say.

The **Join sessions in cmux** toggle and its **Socket password** row (both on
**Settings → Terminals → cmux**) are covered in the
[plugin README](../integrations/claude-code/README.md#which-terminal-am-i-dictating-into).
The join uses cmux's automation socket to tell which session you are
dictating into and reads that surface as context, for local surfaces and for
sessions opened with `cmux ssh`. Your Keychain stores the socket password,
and localvoxtral sends it only to cmux's local socket. Saving an empty field
removes it.

## Dictating into Claude Code

localvoxtral ships a
[Claude Code plugin](../integrations/claude-code/README.md) that tells
localvoxtral what your Claude Code session is doing. The plugin is
hooks-only. It spends none of your tokens, adds nothing to Claude's context,
and cannot slow a turn down (every hook fails open if the app isn't running).
When you dictate into that session, polishing draws on:

- the session's **visible screen**: the exact pane you're dictating into, the
  one you and Claude are both looking at
- your **previous prompt** and the session's **working directory**
- the **files Claude just read or edited**, which hold the identifiers you're
  most likely to say next
- that repository's **vocabulary**, from the repo-vocabulary index above,
  using the directory the session reports instead of guessing from the tab
  title

So a misheard `useAuth.ts`, the branch name you mentioned two turns ago, or
the flag Claude just wrote into a file come out spelled right.

Here it is inside a [herdr](https://herdr.dev) multiplexer. The join binds
to the exact Claude pane and uses that pane's screen as context, while the
neighboring pane stays out of the prompt:

<!-- herdr demo video: recorded by record-demo.yml (terminal_agent=herdr); regenerate via that workflow and replace the URL below. -->

https://github.com/user-attachments/assets/15e71c26-3d8b-490f-90d0-f5c507daf5eb

To install, click **Settings → Claude Code → Plugin → Install or
update**. The app registers its bundled plugin
marketplace through Claude Code's own CLI. The same pane offers the opt-in
status-line indicator. After a one-sentence consent, it writes exactly the
`statusLine` key in `~/.claude/settings.json`, and never over your own
script.

**Working over SSH?** A second plugin, `localvoxtral-remote`, covers Claude
Code sessions on other machines. Its hooks POST through an SSH
`RemoteForward` back to your Mac. The host needs nothing beyond the plugin
itself: two JSON files and a small POSIX-sh script that needs only `sh` and
`curl`, which every host already has. A per-host token authenticates the
hooks, and you can rotate or revoke it in Settings at any time. Remote
context is limited to labels and short sanitized excerpts, and the app never
reaches into the remote filesystem.

An allowlist of session metadata crosses a private local socket;
transcripts, file contents, and shell commands never do. The
[plugin README](../integrations/claude-code/README.md) documents the exact
fields and the threat model.

> [!NOTE]
> **Session joins work in Ghostty (≥ 1.4, today the
> [tip channel](https://ghostty.org/docs/install/pre)), iTerm2,
> Terminal.app, and [cmux](https://github.com/manaflow-ai/cmux)
> (opt-in).** localvoxtral asks the terminal itself for the focused
> pane's TTY and matches it exactly against the session's. Inside a
> [herdr](https://herdr.dev) multiplexer, the join binds to the precise pane
> and reads its screen from herdr directly, so neighboring panes never leak
> into your prompt.
>
> In cmux, the join keys on the surface id that cmux itself injects into the
> session, including shells opened with `cmux ssh`. localvoxtral reads it
> over cmux's own automation socket, which you must first switch to
> `password` mode. The
> [plugin README](../integrations/claude-code/README.md) covers the
> two-step setup. Once joined, the dictation goes into that surface through
> the same socket, so it lands there even if you switch windows while you
> speak. If cmux does not confirm the text arrived, it is not typed anywhere
> else; it stays in History.
>
> Joins are exact-or-nothing: any ambiguity attaches no context at all. No
> join ever reads a window title. The TTY arm needs Ghostty 1.4 or newer (or
> iTerm2 / Terminal.app), and there is no title fallback under it.
>
> A Claude Code session in a plain `ssh host` shell on an enrolled host joins
> on that same tty, which your shell publishes into the session. Settings
> offers to add the one block that does it. Unlike a network-level match, it
> works through jump hosts and shared connections.
>
> A Claude Code **Remote Control** session, where the agent runs on a machine
> of yours and [claude.ai/code](https://claude.ai/code) in a browser is the
> UI, joins from the focused browser tab instead. localvoxtral matches the
> tab's `session_…` URL exactly against the id the session's own hooks
> report. This works in Chrome, Brave, and Safari, and a browser join never
> reads anything on screen.
>
> A session in **Claude Desktop**'s Code tab joins the same way from the
> session you have focused there, whether the desktop app runs it on your Mac
> or on an ssh host. That host needs the remote plugin 1.11.0 or newer and
> **Keep the tunnel open**, since Claude Desktop's ssh carries no tunnel;
> host setup turns it on when it finds Desktop there. This join needs no
> extra permission and reads nothing on screen.
>
> First use asks for one Automation permission per terminal or browser.

An [opencode plugin](../integrations/opencode/README.md) installs from
**Settings → opencode**. It copies the plugin and adds the `tui.json`
entry, and the same row reverses both.

[Mistral Vibe hooks](../integrations/vibe/README.md) install from
**Settings → Mistral Vibe**: a hook script under `~/.vibe/localvoxtral/` and
a marked block in `~/.vibe/hooks.toml`, both removed by the same row. Vibe has
no session-start hook, so localvoxtral learns about a Vibe session at its
first file read or edit, or when its first turn ends.

A [Codex plugin](../integrations/codex/README.md) installs from
**Settings → Codex**, through Codex's own `codex plugin` commands. Codex runs
a plugin's hooks only after you trust them: when Codex next starts, it shows
**Hooks need review**, and **Trust all and continue** turns them on. The
row's dot turns green once a Codex hook has reached localvoxtral. A Codex
session then joins like a Claude Code one, on its terminal's tty or its herdr
or cmux pane, with its last prompt, working directory and the files it
patched.

## The `localvoxtral` command

A coding agent can read your dictation history and your terms, and propose
terms of its own, with the `localvoxtral` command. Install it from
**Settings → General → Command-line tool**: it links
`/usr/local/bin/localvoxtral` to the copy inside the app, so app updates
update it too. macOS asks for your password when `/usr/local/bin` is not
yours to write.

```text
localvoxtral history search "mac queue" --since yesterday --project .
localvoxtral history last
localvoxtral terms list --project .
localvoxtral terms propose Featherline QuillDoc --project .
localvoxtral status
```

Every command takes `--json`. `--project` takes a directory, which counts
every worktree of its repository, or a project name. `--since` takes `today`,
`yesterday`, `3d`, `12h`, `30m`, `2w` or a date. Under **History → Don't
keep**, `history` answers with nothing.

A proposed term joins the project's terms the way the agent's own proposals
do (see [Dictation](dictation.md)): it applies only where repo vocabulary
may, and three dictations or a **Pin** make it yours. **Settings → Text
Processing → Terms learned from polishing → Show** lists it as "Proposed by"
the agent that ran the command. Claude Code, Codex and opencode are detected;
Vibe passes `--agent vibe`. Unlike the headless run, a proposal from the
command does not count as the project's one ask.

The command talks to the running app over the same private socket the hooks
use. It opens no network port, and only processes running as you can reach
it. It needs the app running, and exits 3 when it is not.

To let your agents find it, add the note from the **Tell … you dictate** row
(see [Telling the agent you dictate](#telling-the-agent-you-dictate)): it
tells them to propose what they create or rename. Vibe is not detected, so
its proposals read "Proposed by a coding agent". To have them name Vibe, ask
it to add `--agent vibe` in a line of `~/.vibe/AGENTS.md` outside the note;
an edit inside the note makes the row offer **Update**, which undoes it.
