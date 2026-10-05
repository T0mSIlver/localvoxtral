# Integration matrix

What localvoxtral can do for each coding-agent harness and terminal, and why
the gaps exist.

## What the columns mean

Join, Screen, Repo and Prompt are what a *joined* session adds to a
dictation. Transport is how the app learns about the session.

- **Join.** The evidence that the terminal under your cursor shows *that*
  session. Without a join there is no context, and the app polishes the
  dictation with repo vocabulary only. The trust rules behind each way of
  joining are in the [invariants guide](agent/invariants.md).
- **Screen.** The text on screen, sent to polishing as an untrusted
  reference. It always needs **Send agent's terminal screen** (off by
  default), Accessibility, and a permitted polish endpoint.
- **Repo.** Git status, uncommitted diffs, and the files the agent just
  touched, read from the local filesystem. It needs **Send diff, recent files
  and prompts** (off by default).
- **Prompt.** The session's prior user prompt, reported by the agent's own
  hooks. For Claude Code it also carries the labels of recently touched
  files.

[Polish context: what each toggle sends](coding-agents.md#polish-context-what-each-toggle-sends)
explains each setting.

## The matrix

| Harness / surface | Join keyed on | Screen | Repo | Prompt | Transport | Notes |
|---|---|---|---|---|---|---|
| Claude Code, local, **Ghostty** | the focused pane's tty, read over AppleScript (Ghostty 1.4 or newer, or tip), matched to the tty the hook reports | the focused window's raw text grid, read over Accessibility | yes | yes | hook over a local socket | two live sessions on one tty: no join |
| Claude Code, local, **iTerm2** | tty | the focused session's contents over AppleScript: the visible screen, never history | yes | yes | hook over a local socket | the app refuses the Accessibility read, because the Accessibility tree is ambiguous across splits |
| Claude Code, local, **Terminal.app** | tty of the selected tab | the tab's contents over AppleScript | yes | yes | hook over a local socket | |
| Claude Code, local, **cmux** | the cmux surface id from cmux's surface tree, matched to the surface id cmux gives the session, plus a mandatory tty cross-check | the surface's visible text only | yes | yes | hook over a local socket, plus cmux's control socket | an extra opt-in; cmux's socket must be in password mode |
| Claude Code, local **herdr** pane | the herdr pane id, once the surface's tty binds to a herdr client. herdr's own claim of which agent session runs in the pane must agree, and the agent must be in the pane's foreground | herdr's read of exactly the joined pane, never the composite grid | yes | yes | hook over a local socket, plus herdr's socket | two live herdr servers: no join |
| Claude Code, **remote herdr over ssh** (enrolled host) | a token in the agents panel. The app stamps a fresh lv-mic-… token on the pane over its own ssh forward and requires it in the focused window's text. If it is missing, the command line of the surface's ssh process decides. Then the pane id, herdr's session claim and foreground checks apply | herdr's read of the pane, over the forward | **no** (see below) | yes, plus bounded, sanitized tool excerpts | HTTP to the Mac over a reverse ssh forward, plus an outbound ssh forward the app manages | needs localvoxtral's marker row in the host's herdr config, which host setup adds ([How enrollment works](remote-claude-context.md#how-enrollment-works)). The sidebar must be at least 21 columns wide and tall enough for the entry to show, else the command line decides |
| Claude Code, **plain ssh** (no multiplexer) | your LOCAL tty. Your shell exports it as LC_LVX_TTY, and ssh carries it into the session (SendEnv on your Mac, AcceptEnv LC_* on the host), and it must equal the focused window's tty, pinned to the enrolled host the surface's ssh goes to. Without the variable, the app falls back to the TCP connection: its socket ports against the session's ssh connection | none | no | yes, plus bounded, sanitized tool excerpts | HTTP to the Mac | the tty echo works through jump hosts and shared connections (ProxyJump and ControlMaster), because the variable travels with each session channel. The connection fallback does not. Neither joins inside tmux, screen or zellij. Setup is [one line in your shell rc](../integrations/claude-code/README.md#1-the-tty-echo-works-through-jump-hosts-and-controlmaster) and needs remote plugin 1.7.0 or newer |
| Claude Code inside **tmux** (local or remote) | none | none | no | no | | the session reports that it runs in tmux, and the app uses that to refuse the plain-ssh connection join, because a tmux server keeps the first attaching connection's ssh details. It refuses screen and zellij the same way. A tmux join is still on the roadmap |
| Claude Code **Remote Control** (claude.ai/code tab in Chrome, Brave, Safari) | the focused tab's session URL, matched to the Remote Control session id the hooks report | **none, by design** (see below) | local session only | yes | local hook or HTTP from the host; the tab URL over AppleScript | the app asks the browser only when the repo setting is on; Firefox gives AppleScript no tab URL |
| Claude Code in **Claude Desktop**'s Code tab (sessions on this Mac or on an ssh host) | the address of the focused session's web view (a claude.ai/epitaxy/local_… address, read over Accessibility), matched to the host session id the hooks report | **none, by design** (see below) | local session only | yes | local hook or HTTP from the host | the app asks only when the repo setting is on. Remote hosts need plugin 1.11.0 or newer, and 1.14.0 or newer so a `claude -p` inside a session cannot make it ambiguous. They also need **Keep the tunnel open**, because Desktop's ssh clears every forward; host setup turns it on when it finds Desktop. Both ids are undocumented Desktop internals |
| **opencode**, local | tty, from the focus declarations the plugin sends (valid 45 s, checked against the process id). The herdr pane join works unchanged | herdr's read of the pane in a herdr pane, else the terminal's route | yes | prompt, working directory, touched paths | opencode's JavaScript plugin over the local socket | no status line; no remote path; never joins inside cmux |
| **Mistral Vibe**, local | tty of the Vibe process, which the hook finds by walking out of the detached session Vibe starts hooks in. herdr and cmux pane joins work unchanged | the terminal's route, as for Claude Code | yes | prompt (the session log's last user message; none on Vibe's Unified Harness), working directory, touched paths | command hooks in Vibe's hooks file, over the local socket | the app learns of a session only at its first file-tool call or the end of its first turn; no session-end event; no status line |
| **Codex CLI**, local | tty of the Codex process, which the hook finds by walking out of the detached session Codex starts hooks in. herdr and cmux pane joins work unchanged | the terminal's route, as for Claude Code | yes | prompt, working directory, and the files Codex's patch tool edited. Codex reads through shell commands, so reads name no file | a Codex plugin's command hooks over the local socket | runs only after you trust the hooks at Codex's **Hooks need review** prompt; no status line; no remote path |
| **Mistral Vibe** on an **enrolled ssh host** | the remote joins Claude Code uses: the local tty echo, the ssh connection, the remote herdr pane | herdr's read of the pane in a herdr pane, else none | no | prompt (none on Vibe's Unified Harness), working directory, touched paths, plus bounded, sanitized tool excerpts | Vibe command hooks, a Python compactor and curl on the host, over the enrollment tunnel | host setup installs them when Vibe is there. The host needs Vibe, curl and the Python that Vibe runs on. A background watcher on the host reports the session's end |

## See whether a dictation joined

Claude Code's status line shows the connection. A local session gets it from
the app's local status-line query. A session on an enrolled host gets it
from the status the remote plugin's hooks record.

opencode, Mistral Vibe and Codex show nothing. Vibe has no status line to
extend.

Claude Desktop's Code tab does not render Claude Code's status line, so a
Desktop session shows no indicator. There, the overlay badge (Overlay Buffer
mode) and the `Claude join outcome` line in the log say whether a dictation
joined.

**Settings → Terminals** shows this matrix for your Mac. It has one pane per
terminal app, with the row's status dot and the capabilities spelled out as
**Dictation**, **Session join** and **Screen context** rows.

The panes report what this table and the terminal allowlists on this Mac
allow. They do not widen them.

## Why the gaps

### No repo context for a remote session

The app reads repo context from the local filesystem, and a remote session's
repository lives on the remote host.

The app never opens a path a remote host named. The type that carries a
workspace path cannot be built from a remote origin, so code that let a
remote working directory reach the filesystem would fail to compile. No
setting can turn it on.

A remote session instead contributes what its hooks send: the prior prompt,
the labels of recently touched files, and bounded excerpts of tool output.
Collecting git state on the remote host over the app's own ssh is on the
[roadmap](roadmap.md).

### No screen context for a Remote Control session

This gap is by design. The session runs in a browser tab, not a terminal
grid. Reading it would mean scraping a web page's accessibility tree, which
exposes far more private data than a terminal, for text the session's hooks
already deliver as the prompt block.

The app asks the browser for one thing only, the focused tab's URL. It asks
only when the repo setting is on, because the screen setting alone must never
automate a browser.

### No screen context for a Claude Desktop session

The reason is the same. The window shows the whole conversation, not a
terminal grid, and the session's hooks already deliver the prompt.

The app reads one thing from Claude Desktop, the address of the web view
holding keyboard focus.

### Why the join needs the herdr panel to be visible

Before the app uses a remote herdr server's focused pane for a dictation, it
must prove that the window you are looking at displays *that* server. The
panel token is the proof.

A whole-view herdr client renders the sidebar, and an attach-mode client
never does. Nothing that did not observe the server can know the token.

The token is not on screen if the sidebar is collapsed, narrower than 21
columns, too short for the entry to show, or missing localvoxtral's marker
row. Each of those cases is a no-match. The app falls back to the command
line rule, and otherwise joins nothing. A missing token can never produce a
wrong join.

### The command line fallback

When the panel token is not on screen, the app inspects the one foreground
ssh process on the focused surface's tty. It requires all of the following:

- the executable is a known OpenSSH binary,
- its destination resolves to exactly one enrolled host, and
- the remote command it started with is a plain whole-view herdr: `herdr` or
  `herdr --session <name>`, nothing else.

The app refuses `herdr terminal attach`, or a manual `ssh host` followed by
typing `herdr`, because the command line cannot prove what the window
displays.

## Not integrated

| What | Why |
|---|---|
| **Remote Codex** | the remote listener accepts Claude Code and Mistral Vibe only |
| **Remote opencode** | the remote listener accepts Claude Code and Mistral Vibe only |
| **Vibe in VS Code or another ACP client, `vibe -p`** | the hooks publish, but there is no terminal pane to join |
| **kitty, WezTerm, Alacritty, Warp, Hyper, Tabby, Rio** | dictation and insertion only. They offer no per-pane tty or screen route whose trust comes from the transport. WezTerm is next on the [roadmap](roadmap.md) |
| **VS Code, Cursor, VSCodium** | insertion only; a pinned test excludes them from screen reads |
| **Firefox** for Remote Control | AppleScript cannot read the focused tab's URL |
| **tmux / screen** | on the roadmap |
