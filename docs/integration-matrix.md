# Agent harness × feature matrix

What localvoxtral can do for each coding-agent harness and terminal surface,
and why the gaps are gaps. The columns are the four things a *joined* session
contributes to a dictation, plus how the app learns about the session.

- **Join** — the evidence that proves the terminal under your cursor is showing
  *that* session. No join, no context: the dictation is polished with repo
  vocabulary only. The trust rules behind every arm are in
  [`docs/agent/invariants.md`](agent/invariants.md).
- **Screen** — the text on screen, attached to polishing as an untrusted
  reference. Always behind the Terminal screen context setting (off by
  default), Accessibility, and a permitted polish endpoint.
- **Repo** — git status, uncommitted diffs, and the files the agent just
  touched, read from the local filesystem. Behind the Claude repo context
  setting (off by default).
- **Prompt** — the session's prior user prompt (and, for Claude Code, the
  labels of recently touched files), reported by the agent's own hooks.

| Harness / surface | Join keyed on | Screen | Repo | Prompt | Transport | Notes |
|---|---|---|---|---|---|---|
| Claude Code, local, **Ghostty** | focused pane's tty (AppleScript, Ghostty ≥ 1.4 / tip) matched to the hook-reported tty | raw AX grid of the focused window | yes | yes | local socket hook | two live sessions on one tty abstain |
| Claude Code, local, **iTerm2** | tty | AppleScript `contents` of the focused session (visible screen, never history) | yes | yes | local socket hook | AX capture refused: the tree is ambiguous across splits |
| Claude Code, local, **Terminal.app** | tty (selected tab) | AppleScript `contents` | yes | yes | local socket hook | |
| Claude Code, local, **cmux** | cmux surface id (`system.tree`) matched to `CMUX_SURFACE_ID`, plus a mandatory tty cross-check | `surface.read_text` viewport only | yes | yes | local socket hook + cmux control socket | extra opt-in; cmux must be in `password` socket mode |
| Claude Code, local **herdr** pane | herdr pane id, after the surface's tty binds to a herdr client; herdr's own `agent_session` claim must agree and the agent must be in the pane's foreground | herdr `pane.read` of exactly the joined pane, never the composite grid | yes | yes | local socket hook + herdr socket | two live herdr servers abstain |
| Claude Code, **remote herdr over ssh** (enrolled host) | agents-panel nonce: the app stamps a fresh `lv-mic-…` token on the pane over its own `ssh -L` and requires it in the focused window's text; argv classification of the surface's `ssh` as fallback; then pane id + `agent_session` + foreground checks | herdr `pane.read` over the forward | **no** (see below) | yes, plus bounded sanitized tool excerpts | remote HTTP over `RemoteForward` + an app-managed outbound `ssh -L` | needs the `$lvmark` row in the remote herdr config; sidebar ≥ 21 columns and tall enough for the entry to show, else the argv fallback decides |
| Claude Code, **plain ssh** (no multiplexer) | none today | none | no | no | remote HTTP | see the 0.9.0 release notes for the connection-bound join |
| Claude Code inside **tmux** (local or remote) | none | none | no | no | | `$TMUX` is transported but unread; roadmap item |
| Claude Code **Remote Control** (claude.ai/code tab in Chrome, Brave, Safari) | focused tab's `session_…` URL matched to `CLAUDE_CODE_BRIDGE_SESSION_ID` | **none, by design** (see below) | local session only | yes | local hook or remote HTTP; tab URL over AppleScript | asked only under the repo setting; Firefox has no AppleScript tab URL |
| **opencode**, local | tty via the plugin's focus declarations (45 s TTL, pid-checked); herdr pane join works unchanged | herdr `pane.read` in a herdr pane, else the terminal's route | yes | prompt, cwd, touched paths | opencode JS plugin over the local socket | no statusline; no remote path; inside cmux never joins |

Statusline / connection indicator: the local `--statusline` query for local
Claude Code sessions; the remote plugin's hook-status stamp for enrolled
hosts; nothing for opencode.

## Why the gaps

**No repo context for a remote session.** Repo context is read from the
filesystem, and a remote session's repository lives on the remote host. The
app never opens a path a remote host named: the type that carries a workspace
path cannot be built from a remote origin, so "remote cwd reaches the
filesystem" is a compile error, not a setting. What a remote session
contributes instead comes from its hooks: the prior prompt, the labels of
recently touched files, and bounded excerpts of tool output. Collecting git
state on the remote host over the app's own ssh is on the [roadmap](roadmap.md).

**No screen context for a Remote Control session, by design.** The surface is
a browser tab, not a terminal grid. Reading it would mean scraping a web
page's accessibility tree, a far wider privacy surface than a terminal, for
text the session's hooks already deliver as the prompt block. The browser is
consulted for exactly one thing, the focused tab's URL, and only when the
repo setting is on, because the screen setting alone must never automate a
browser.

**Why the join needs the herdr panel to be visible.** The remote-herdr join
must prove that the window you are looking at displays *that* server before
grounding a dictation in its focused pane. The panel token is that proof: a
whole-view herdr client renders the sidebar, an attach-mode client never
does, and nothing that did not observe the server can know the token. If the
sidebar is collapsed, narrower than 21 columns, too short for the entry to
show, or missing the `$lvmark` row, the token is not on screen. Every one of
those is a no-match, which falls back to the argv rule and otherwise joins
nothing. It can never produce a wrong join.

**The argv fallback.** When the panel proof cannot render, the app inspects
the one foreground `ssh` process on the focused surface's tty: the executable
must be a known OpenSSH binary, its destination must resolve to exactly one
enrolled host, and the remote command it was started with must be a plain
whole-view `herdr` (`herdr` or `herdr --session <name>`, nothing else). A
`herdr terminal attach` or a manual `ssh host` followed by typing `herdr` is
refused, because the command line cannot prove what the window displays.

## Not integrated

| What | Why |
|---|---|
| **codex CLI** | nothing wired; the wire knows two agents, Claude Code and opencode |
| **Remote opencode** | the remote path types every record as Claude Code |
| **kitty, WezTerm, Alacritty, Warp, Hyper, Tabby, Rio** | dictation and insertion only; no per-pane tty or screen route with transport-derived trust (WezTerm is next on the [roadmap](roadmap.md)) |
| **VS Code, Cursor, VSCodium** | insertion only; explicitly excluded from screen reads by a pinned test |
| **Firefox** for Remote Control | no AppleScript surface for the focused tab's URL |
| **tmux / screen** | roadmap item |
