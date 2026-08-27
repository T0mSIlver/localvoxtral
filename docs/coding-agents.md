# Terminals & coding agents

Most dictation tools fall apart in a terminal. localvoxtral treats it as its
primary target: prompt Claude Code — or any CLI coding agent — by voice and
watch the words stream in live. SSH sessions work too, since text is typed
into your local terminal. Terminal apps are detected automatically (Terminal,
iTerm2, Ghostty, Warp, WezTerm, kitty, Alacritty, Hyper, Tabby, Rio, and
more), and apps that embed a terminal can be added in `terminal_apps.toml`.
Live dictation adapts:

- **Prompt-safe output** — newlines and tabs are typed as spaces, so a stray
  line break never submits a half-finished prompt and a tab never triggers
  shell completion
- **Replacements without rewriting** — dictionary replacements are applied
  before text is typed; localvoxtral never backspaces over what the terminal
  has already drawn
- **Secure input handling** — if Secure Keyboard Entry is active (a `sudo`
  password prompt, say), a live session refuses to start instead of typing
  into the void, and an overlay commit falls back to copying the text to the
  clipboard

When an Overlay Buffer dictation commits, optional LLM polishing understands
how developers talk:

- **Agent prompt profile** (on by default) — when the target is a terminal,
  polishing switches to an agent-tuned prompt. Spoken symbol forms become
  written ones ("dash dash force" → `--force`, "src slash auth" →
  `src/auth`, "the dot env file" → `.env`), code-like tokens (and only
  those) get backticks, filler words are stripped, self-corrections resolve
  to the final intent, and explicit enumerations become lists
- **Model-first polishing** — polishing trusts the model's final wording and
  technical formatting, so useful Markdown and reconstructed identifiers
  survive
- **Repo vocabulary** (opt-in) — the focused repo (found from the tab title,
  or from a joined Claude Code session's own working directory) is indexed
  with a single sandboxed `git ls-files`, and up to 12 relevant terms reach
  the polisher, so "use auth dot t s" comes out as `useAuth.ts`. An ambiguous
  repo safely sends no hints, and only high-confidence, boundary-checked
  matches are corrected in the working text — everything else stays a hint,
  never a rewrite of the model's output
- **Clipboard as context** (opt-in) — the polisher sees a sanitized excerpt
  of your clipboard to ground technical spellings
- **"Paste clipboard" macro** (on by default) — say it mid-dictation and the
  clipboard content is embedded as a code block when the text commits

The overlay shows a **Polished** badge whenever the LLM touched your text,
and the raw transcript stays one click away in the menu bar popover.

## Dictating into Claude Code

localvoxtral ships a
[Claude Code plugin](../integrations/claude-code/README.md) that turns
dictation into a session-aware input method. The plugin is hooks-only — it
spends none of your tokens, adds nothing to Claude's context, and cannot slow
a turn down (every hook fails open if the app isn't running). What it does is
tell localvoxtral what your session is doing, so that when you dictate into
that session, polishing is grounded in:

- the session's **visible screen** — the exact pane you're dictating into, so
  what you and Claude are both looking at grounds what you say
- your **previous prompt** and the session's **working directory**
- the **files Claude just read or edited** — exactly the identifiers you're
  most likely to say next
- that repository's **vocabulary** (via the repo-vocabulary index above,
  using the session's own reported directory — no tab-title guessing)

The result is dictation that gets the hard part right: the misheard
`useAuth.ts`, the branch name you mentioned two turns ago, the flag Claude
just wrote into a file.

Here it is inside a [herdr](https://herdr.dev) multiplexer — the join binds
to the exact Claude pane and grounds the dictation in that pane's screen,
while the neighboring pane stays out of the prompt:

<!-- herdr demo video: recorded by record-demo.yml (terminal_agent=herdr); regenerate via that workflow and replace the URL below. -->

https://github.com/user-attachments/assets/15e71c26-3d8b-490f-90d0-f5c507daf5eb

Install is one click: **Settings → Text Processing → Claude Code plugin →
Install**. The app registers its bundled plugin marketplace through Claude
Code's own CLI and never edits `~/.claude/settings.json` behind your back.

**Working over SSH?** A second plugin, `localvoxtral-remote`, covers Claude
Code sessions on other machines: its hooks POST through an SSH
`RemoteForward` back to your Mac — nothing to install on the host beyond the
plugin itself (two JSON files and a small POSIX-sh script; it needs only `sh`
and `curl`, which every host already has), authenticated by a per-host token
you can rotate or revoke in Settings at any time. Remote context is bounded
and opaque by construction: labels and short sanitized excerpts only, and the
app never reaches into the remote filesystem.

Privacy, in one line: an allowlist of session metadata crosses a private
local socket; transcripts, file contents, and shell commands never do. The
[plugin README](../integrations/claude-code/README.md) documents the exact
fields and the threat model.

> [!NOTE]
> **Session joins work in Ghostty (≥ 1.4, today the
> [tip channel](https://ghostty.org/docs/install/pre)), iTerm2,
> Terminal.app, and [cmux](https://github.com/manaflow-ai/cmux)
> (opt-in).** localvoxtral asks the terminal itself for the focused
> pane's TTY and matches it exactly against the session's — and inside a
> [herdr](https://herdr.dev) multiplexer, the join binds to the precise pane
> and reads its screen from herdr directly, so neighboring panes never leak
> into your prompt. In cmux, the join keys on the surface id cmux itself
> injects into the session — including shells opened with `cmux ssh` — read
> over cmux's own automation socket, which you must first switch to
> `password` mode; the
> [plugin README](../integrations/claude-code/README.md) covers the
> two-step setup. Joins are exact-or-nothing: any ambiguity attaches no
> context at all. On stable (pre-1.4) Ghostty, an opt-in **window-title
> marker fallback** is available — the
> [plugin README](../integrations/claude-code/README.md) covers its setup. A
> Claude Code **Remote Control** session — where the agent runs on a machine
> of yours and [claude.ai/code](https://claude.ai/code) in a browser is the
> UI — joins from the focused browser tab instead: its `session_…` URL is
> matched exactly against the id the session's own hooks report (Chrome,
> Brave, and Safari; a browser join never reads anything on screen). First
> use asks for one Automation permission per terminal or browser.

An [opencode plugin](../integrations/opencode/README.md) exists too, with a
manual two-step install.
