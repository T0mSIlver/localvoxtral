# Claude Code plugins

These two Claude Code plugins tell localvoxtral what your Claude Code session
is doing. Dictation then recognizes technical terms it would otherwise
mishear: filenames, symbols, the thing you asked for last turn.

The local plugin goes on the Mac that runs the app. The remote plugin goes on
a host where you run Claude Code over ssh.

This directory is a local Claude Code marketplace and the source of truth in
the repo. The [packaging script](../../scripts/package_app.sh) copies it into
the app bundle, so an installed app can register it without a checkout or a
separate marketplace repository.

## Install the plugin on your Mac

The local plugin declares hooks only. It ships no skill, slash command or
agent, so it uses no Claude tokens, adds no latency to your turn, and puts
nothing in Claude's context. It only passes data to the app.

1. In the app, open **Settings → Claude Code → Plugin**.
2. Press **Install**.

The button registers the bundled marketplace, installs the plugin, and
reports one short line. Nothing is installed until you press it.

### Install by hand

These are the commands the button runs. The button also passes the path of
the app's own publisher binary, so the plugin works for an app in
~/Applications, on a mounted volume, or in a dev build. Without that path, the
hook script guesses /Applications and ~/Applications (see
[Configuration](#configuration)).

From an **installed app**:

```sh
claude plugin marketplace add "/Applications/localvoxtral.app/Contents/Resources/claude-code-marketplace"
claude plugin install localvoxtral@localvoxtral \
  --config 'publisher_path=/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook'
```

From a **repo checkout**:

```sh
claude plugin marketplace add ./integrations/claude-code
claude plugin install localvoxtral@localvoxtral
```

### Check the install

```sh
claude plugin list
```

For a check you can see on every turn, set up the
[connection indicator](#connection-indicator-opt-in-status-line).

### What costs tokens

One opt-in feature outside the plugin does spend tokens. With **Ask the
coding agent for each new project's terms** on, the app runs its own
read-only, one-shot Claude Code run once per project, never in your session.
That costs about $0.03 to $0.12, or the same share of a Claude.ai plan's quota
(see [Terms from your coding agent](../../docs/dictation.md#terms-from-your-coding-agent)).

On an enrolled host, the remote plugin runs that one-shot run on the host
instead, when the Mac asks for a session's project
([Terms from the coding agent on a host](../../docs/remote-claude-context.md#terms-from-the-coding-agent-on-a-host)).

The remote plugin also drafts a quick capture routed to one of that host's
projects. It has the same caps as the Mac's own draft, $0.50 at most
([Quick capture on a host](../../docs/remote-claude-context.md#quick-capture-on-a-host)).

## Which terminal am I dictating into?

Every join below matches ONE identifier your session's own hooks published
against the SAME identifier read off the window you are looking at. The app
makes no fallback guesses, and **no join reads your window title**. That
mechanism was removed in September 2026 (see
[What was removed](#what-was-removed-september-2026)).

Repo vocabulary, a separate opt-in feature, still reads a terminal title to
find a git root. It never picks a Claude session.

### Ghostty, iTerm2 and Terminal.app

These terminals join by tty, the terminal device. It is the default for
Ghostty 1.4 or newer (currently the tip channel), iTerm2 and Terminal.app.

The hooks report the session's controlling terminal device. At dictation
start, the app asks the focused terminal for its focused pane's tty over
AppleScript. Each terminal asks for Automation consent once.

Device equality is exact. It works mid-response and tells two sessions in the
same repo apart. Other terminals don't join at all rather than join halfway.

Inside a [herdr](https://herdr.dev) multiplexer session the tty can't match,
because herdr puts its own terminal device in front of each pane. There the
app asks herdr's own socket for the focused pane and joins on the exact pane
id. Any ambiguity, including two live herdr sessions, attaches nothing.

### cmux (opt-in)

[cmux](https://github.com/manaflow-ai/cmux) draws its terminal with libghostty
into a custom view. It exposes no accessible text and no scripting
dictionary, so neither the tty read nor any screen read works there.

Instead the app asks cmux's own automation socket which surface is focused.
It matches that surface id against the one cmux put into the session's
environment. cmux does that in shells opened with `cmux ssh` too, which is one
of the ways a remote session can join.

That surface is also the only screen context the app can read. It fetches it
per surface, and reads the visible viewport, never the scrollback.

cmux's socket refuses outside clients by default, so set up two things:

1. In **cmux → Settings → Automation**, set the socket mode to **Password**
   and choose a socket password. The default mode admits only processes cmux
   itself started, which localvoxtral is not. The allow-all mode is for
   developers and is not required.
2. In localvoxtral, turn on **Settings → Terminals → cmux → Join sessions in
   cmux** and enter the same password in **Socket password**. The app stores
   it in your Keychain and sends it only to cmux's local socket. Saving an
   empty field removes the stored password.

If the socket refuses the app, the settings row says **cmux socket requires
password mode.** and the dictation joins nothing. A failed join attaches
nothing.

This join has two limits:

* **The app cross-checks terminal devices.** It compares the surface's
  terminal device with the one your session reported, and abstains when
  either side does not report one. opencode's server half never claims a
  pane, so opencode inside cmux does not join this way.
* **A remote session needs a live cmux ssh workspace.** A session on a remote
  host joins only while cmux reports that surface's workspace as a live
  `cmux ssh` workspace. A stale surface id from an earlier remote session
  cannot attach to whatever you are looking at now.

### A browser tab (Claude Code Remote Control)

A Remote Control session runs Claude Code on one of your machines, with
[claude.ai/code](https://claude.ai/code) in a browser as its UI. There is no
pane, tty or title to join on.

Since Claude Code 2.1.199, the hooks of such a session carry a bridge session
id. Its value is exactly the part of that browser URL that starts with
"session_". When the frontmost app is a browser, the app reads its focused
tab's URL over AppleScript and requires the id to equal what the session's
own hooks reported.

Local and remote (ssh) sessions can both join this way. Anthropic's bridge
allocates the id and it is globally unique, unlike a tty or pane id.

Claude Code removes the id from the session's environment when the Remote
Control connection ends, so the join expires on the session's next hook.

Supported browsers are **Google Chrome, Brave, and Safari**. Each needs its
OWN Automation grant the first time it is used, under **System Settings →
Privacy & Security → Automation → localvoxtral**.

The app asks for the grant only while **Settings → Context → Send diff,
recent files and last prompt** is on, since that is the only feature a
browser join serves. Firefox is not supported, because it exposes no
AppleScript access to the focused tab's URL.

A browser join never reads anything on your screen. A web page is not a
terminal grid, and there is no verified way to capture one tab. It attaches
only the session's own off-screen context, plus the repository for a local
session, the same as a terminal join.

### Claude Desktop

Claude Desktop's Code tab shows each Claude Code session in a web view whose
address on claude.ai ends in a "local_" session id. It exports the same id to
the session. When Claude Desktop is frontmost, the app reads the address of
the web view that holds keyboard focus over Accessibility, and matches the id
against what the session's hooks reported.

Sessions the desktop app runs on this Mac join through the local plugin.
Sessions it runs on an ssh host join through the remote plugin, version
1.11.0 or newer, on that host. They also need **Keep the tunnel open** (see
[Keep the tunnel open for sessions nobody sits at](#keep-the-tunnel-open-for-sessions-nobody-sits-at)),
because Claude Desktop's own ssh never carries the tunnel. Host setup turns
it on when it finds Claude Desktop on the host.

Like the browser join, it reads no screen and runs only with Claude repo
context on.

The Code tab does not show Claude Code's status line, so the status-line
indicator never appears there. The overlay badge and the log's "Claude join
outcome" line tell you whether a dictation joined.

Every process inside a desktop session inherits the id. So a one-shot Claude
Code run started from one used to report the same id and make the join
abstain.

On a Linux host, the remote plugin 1.14.0 or newer sends the id only from a
Claude process whose parent is Claude Desktop's daemon on that host. A host
without /proc still sends it from every hook.

A session that reports the id stays joinable for seven days without a hook,
not four hours, because it sits idle while its window stays open.

### A plain `ssh host` session

A Claude Code session in an ordinary ssh shell on an **enrolled** host, with
no herdr, cmux or Remote Control, joins on the TCP connection your terminal
holds. The app tries two ways to identify your window, in this order.

### 1. The tty echo (works through jump hosts and `ControlMaster`)

Your Mac's shell publishes the terminal's own device name, and ssh carries it
into the remote session. localvoxtral then joins by comparing it against the
tty of the window it can see.

**Set it up from the app.**

1. Open **Settings → Remote hosts → Plain SSH**.
2. Press **Set Up…** next to **Terminal setup**. It shows one consent
   sentence naming the shell file, and links here for details.
3. Open a NEW terminal window and a NEW ssh session. A session's environment
   is fixed when it starts.

Once this app's block is in the file, the row offers only **Remove**. A block
an older app wrote brings back **Update…**, which replaces that block rather
than adding a second copy.

The row also reports whether a remote session has arrived carrying the value,
which you cannot tell from the file.

The app refuses to write through a symlink. If your ~/.zshrc is a link into a
dotfiles repo, an atomic write would replace the link and detach your setup.
The row says so and links here instead of offering a button, and you paste
the block yourself.

**Set it up by hand.** Add this to your shell's rc file **on your Mac**, then
open a new window and a new ssh session:

```sh
if [ -z "${LC_LVX_TTY:-}" ] && [ -z "${SSH_TTY:-}" ]; then
  case "$(tty 2>/dev/null)" in /dev/*) LC_LVX_TTY="$(tty)"; export LC_LVX_TTY ;; esac
fi
```

ssh carries the value into the session with its SendEnv option. The
enrollment block adds that line, and most ssh configs already send every LC_
variable. The host's sshd accepts it, because its stock config accepts LANG
and every LC_ variable.

iTerm2 uses the same LC_ mechanism for its own terminal name, and locale
libraries ignore names they do not know.

**Why each part of the block is there.** Shorter versions were measured to
fail:

* **The two emptiness checks.** SSH_TTY unset means "only on this Mac", and
  the LC_LVX_TTY check means "do not overwrite what was sent to me". Without
  them, the same rc file on a remote host makes the remote shell replace your
  Mac's tty with its own. Nothing matches, and because the variable is then
  set, no later shell fixes it.
* **The case line.** It handles shells with no terminal, where tty prints
  "not a tty". The first draft exported that string. The hook script's
  character filter drops it, but it breaks the "already set" check for every
  shell that inherits it.
* **An if block, not a one-line chain.** A chain's exit status becomes the rc
  file's status. Sourced under a shell that exits on the first error, the
  chain version exited 1 before the next line ran, and the block version ran
  on and exited 0. bash reads ~/.bashrc non-interactively for shells it
  believes sshd started, so the chain could break a remote script run over
  ssh for anyone syncing dotfiles.

**Why this join comes first.** ssh carries environment per SESSION, not per
connection. So it works through a jump host, where your Mac holds no
connection to the destination, and through a shared connection, where several
windows use one. Those are the two setups the connection match cannot handle.

If your host's sshd refuses LC_ variables (rare, but hardened configs do),
add this line to the host's sshd config and reload sshd:

```
AcceptEnv LC_LVX_TTY
```

**Check that the value arrives.** That is the one thing that can go wrong.
Run this from a window where the rc block ran:

```sh
ssh builder 'echo "[$LC_LVX_TTY]"'
```

An empty answer means the variable is not crossing. Check the rc block, the
SendEnv line, or a hardened sshd.

Ask the remote side, not `localvoxtral --probe-surface`. That command runs as
a separate one-shot process with its own empty session registry. It tells you
which join ran and why the window was or was not identified, but it never has
the live sessions this check needs.

On a debug or UI Smoke build, the registry list command reports each
session's remote local tty, the same fact seen from the app.

### 2. The connection (zero setup, no jump host)

sshd puts the connection into every session it starts: the client address
and port, then the server address and port. The remote plugin publishes it.

On your Mac, the app finds the ssh process running in your focused terminal
and reads that process's established socket from the kernel. It requires the
two to be the
same connection — same client port, same server address, same server port.
The client port is an ephemeral number your Mac's kernel picked, and only the
machine on the other end of that connection learns it.

Either join attaches the session block and, for a local session, repository
context. Neither attaches your screen. A plain ssh shell's scrollback is your
whole remote session, not one pane, so neither join may capture it.

Neither joins in these cases:

* **through a jump host, without the rc line above** (ssh -J, ProxyJump, or a
  ProxyCommand). Your Mac's socket goes to the jump host, while the machine
  you land on sees the jump host's port. They are two different connections,
  and only the jump host knows how they pair up. It cannot tell you without
  root there. The app says "this connection goes through a jump host". **The
  tty echo works here**, so set it up if you jump.
* **inside tmux, screen or zellij**. A multiplexer server keeps the
  connection of the ssh session that STARTED it, so a session in a pane can
  report a connection that belongs to another of your windows. This was
  measured. herdr and cmux have their own joins, which bind the pane rather
  than the connection. tmux, screen and zellij have none.
* **when your ~/.ssh/config may be sharing one connection** (ControlMaster),
  again only without the rc line. Several terminals then run over one TCP
  connection and all report the same connection, so it no longer identifies a
  window. The app detects this two ways, each with its own reason in the probe
  output: the window you are dictating into holds no connection of its own
  (it is a multiplexing client), or another ssh session to the same host
  does. The tty echo still works, because ssh gives each session its own
  environment even over a shared connection.
* **when anything is ambiguous**: two sessions reporting the same connection,
  two enrolled hosts matching the destination, an unreadable process table.

**If nothing joins and you expect it to**, check the remote plugin version.
This join needs **1.7.0 or newer** on the remote host. Update it with
`claude plugin update localvoxtral-remote` there. `localvoxtral
--probe-surface` names the exact reason a join failed.

### What was removed (September 2026)

Until then there was one more join. The app allocated a marker per session
(lvx- followed by hex digits) and returned it in the hook reply. Claude Code wrote it into the window title
with a terminal escape sequence, where a focused-window read could find it.

A **Local Claude title fallback** setting turned it on for local sessions
(default off). It asked you to export
`CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` in your shell profile. It was the only join an ordinary ssh session to a host
had.

All of it is gone: the marker, the setting, the escape sequence, the reply
field that carried it, and the advice about title passthrough in
multiplexers. **The hooks now print nothing at all, ever.** Neither the local
socket nor the remote listener has any field that could put a byte on your
terminal.

It went because everything rewrites a window title. Claude Code writes its
own conversation titles over it mid-turn, herdr and cmux rewrite their pane
titles, and you may rename a window yourself. So a marker in a title showed
where a session used to be, not what your screen shows now.

This was measured. On the owner's setup (2026-09-05), a herdr pane's title was
polled about 325 times a second for 69.4 s across a hook event. The marker was
the title for 0.88 s in total, **1.26 %** of the time, and Claude Code's own
conversation title held it the rest of the time.

A remote herdr join that had everything else right still failed on that
check, unless the user had exported that variable, which made it succeed
immediately. The check passed about one time in a hundred, so
it could not serve as a second binding.

**What this cost you, and what replaced it.** For one release, a plain ssh
session with no herdr, cmux or Remote Control had no join at all. It joins
again, on the connection itself (see
[A plain ssh host session](#a-plain-ssh-host-session)).

Nothing else changed. Local sessions join by tty, herdr panes by pane id
(local and remote), cmux by surface id (local and remote), Remote Control by
bridge session id.

**If you had the setting on**, the app ignores the stored value. There is
nothing to migrate, and you can drop
`CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` from your shell profile.

## Connection indicator (opt-in status line)

Claude Code's bottom bar can show whether localvoxtral is connected to this
session.

### From the mod plugin

The **Install** button also installs a third plugin, `localvoxtral-mod`. It is
a Claude Code mod: a plugin whose hooks are functions running inside Claude
Code. It shows the indicator below as its own status line, with no entry in
~/.claude/settings.json, beside your own status line. It skips the indicator
when your settings already show it.

Mods are early access in Claude Code, and load only where Claude Code enables
them. Where they do not load, this plugin does nothing and the `localvoxtral`
plugin keeps working; use the setting below instead. By hand:

```sh
claude plugin install localvoxtral-mod@localvoxtral \
  --config 'publisher_path=/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook'
```

### From your settings

1. In the app, open **Settings → Claude Code → Status line**.
2. Press **Set Up…**. A one-sentence consent names ~/.claude/settings.json,
   and **Details** opens this section.

The app writes one status-line entry pointing at its bundled publisher
binary in status-line mode. Everything else in ~/.claude/settings.json is
kept, although the app rewrites the JSON with sorted keys and normalized
formatting. **Remove** takes the entry back out and deletes the file when
nothing else is in it.

The indicator shows one fixed line:

| Line | Meaning |
|---|---|
| lvx ● (green) | the app received this session's hooks |
| lvx ◐ (yellow) | the app is listening but does not recognize this session |
| lvx ○ (grey) | nothing is listening on the local socket |
| lvx ✕ (red) | remote only: the Mac rejected the host token |

With NO_COLOR set or a dumb terminal, the same glyphs render without color.

The publisher reads the status-line payload Claude Code pipes in. It asks the
app's socket whether THIS session, by its session id, is live in the app's
registry. The query is read-only, so asking never creates or refreshes a
session.

The lines are compile-time constants, so nothing read off the socket ever
reaches your terminal. A payload without a usable session id prints nothing
rather than guessing.

### Combine it with your own status line

If you already have your own status line, the row offers **Combine…**
instead of **Set Up…**. The app writes ~/.claude/localvoxtral-statusline.sh,
which runs your command and then the indicator on the same line, and points
the status line at it.

The script keeps your command, so **Remove** puts it back exactly. If you
delete the app, the script skips the indicator and your own line keeps
working. The app never edits a script it did not write. If you change the
combined script by hand, the row says so and offers no button.

### Set it up by hand

Claude Code has no plugin-owned status line, so the entry lives in your own
settings either way. Add the same entry the button writes to
~/.claude/settings.json:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook --statusline"
  }
}
```

For ~/Applications or a dev build, adjust the path. It is the same binary the
plugin's publisher path points at.

To keep your own status line, read the payload once and feed it to both
commands, for example:

```sh
#!/bin/sh
input=$(cat)
printf '%s' "$input" | ~/.claude/my-statusline.sh
printf '%s' "$input" | /Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook --statusline
```

### After you move the app

Unlike the plugin, the status line does not follow the app when it moves,
because the path is saved in your settings. The **Status line** row compares
that path with the running app's. After a move it shows **Update…**, whether
or not the old copy is still on disk. While the entry points at this app, the
row offers only **Remove**.

## Tell Claude Code you dictate

**Settings → Claude Code → Tell Claude Code you dictate → Add** puts a short
note in ~/.claude/CLAUDE.md saying your prompts come from speech-to-text. See
[Telling the agent you dictate](../../docs/coding-agents.md#telling-the-agent-you-dictate).

## Set up a remote host

When you dictate into a Claude Code session running on another machine over
ssh, the local plugin cannot help. That host has no app and no socket to
write to. The remote plugin, the second plugin in this marketplace, covers
that case.

**Install it on the REMOTE host, not on your Mac.** The two plugins have
different transports and different trust models. A plugin installed on the
wrong side fails open silently forever.

| | Local plugin | Remote plugin |
|---|---|---|
| Install on | the Mac running the app | the remote host |
| Transport | a UNIX socket, through a hook script | HTTP over an ssh reverse forward, through a hook script that calls curl |
| Authentication | peer user id, verified by the kernel | a bearer token per host, issued in the app |
| Needs on that host | the app's publisher binary | POSIX `sh` and `curl` only, no Python, no jq, no nc, no Node, no localvoxtral binary |
| Context it delivers | full: the working directory authorizes local repository reads | opaque: labels and bounded excerpts only |

### Set it up

1. Open **Settings → Remote hosts → Add host**.
2. Type a name and your ssh host alias, and press **Enroll…**. The app issues
   a token and binds its listener immediately, with no relaunch.
3. In the sheet that opens, press **Set Up**. It runs every step in one
   consented flow, in order, and verifies each one:
   1. the ssh config block on this Mac
   2. the shell export block
   3. the plugin install or update on the host, when Claude Code is there
   4. the check that LC_LVX_TTY crosses
   5. the herdr agents-panel row, when herdr is installed
   6. the Mistral Vibe hooks, when Vibe is there
   7. the final **Check Setup**

The flow stops at the first failure and gives the exact fix. The sheet shows
no token, command or file contents, only one line per step. Its **Details**
link opens [Remote Claude Code over SSH](../../docs/remote-claude-context.md),
whose [Commands the app runs](../../docs/remote-claude-context.md#commands-the-app-runs)
lists every command.

The consent sentence names every local file and the ssh alias the flow may
touch. Nothing runs or is written before **Set Up**.

The app runs remote work through ssh in batch mode and feeds the token over
the remote shell's standard input. So the token never appears in any
process's argument list **on your Mac**.

On the host it does, briefly. The plugin install command takes its config as
a flag and has no other input path, so the token is in that one command's
arguments while it runs. Afterwards it sits in the plugin's config under
~/.claude, readable by anything running as you there. That holds whether the
app runs the command or you paste it (see
[A token](../../docs/remote-claude-context.md#3-a-token)).

[Remote Claude Code context over SSH](../../docs/remote-claude-context.md) is
the full reference: what the token authorizes, the per-Mac port, multiplexer
limits, uninstalling.

#### Manage an enrolled host

The **Remote hosts** row lists each enrolled host and when it was last seen,
with **Update Host…**, **Rotate Token**, **Revoke** and **Remove**.

**Update Host…** runs the same flow as enrollment. It hides once all of these
hold, since the run would then change nothing it can check from here:

* since launch, the host has reported the app's plugin version, and the app's
  Vibe hooks version where the host has them
* this Mac's ssh config and shell startup blocks are in place

A finished update closes its panel. The button also hides on a revoked host,
and **Rotate Token** brings it back.

#### Run the steps by hand

Settings never shows the token, and this Mac stores only its hash. If setup
is interrupted, rotate the token and run **Set Up** again. These are the
steps the flow runs.

**1. Add the tunnel to ~/.ssh/config:**

```
# BEGIN localvoxtral claude context (h1a2b3c4)
Host builder
    RemoteForward 28511 127.0.0.1:8473
    ExitOnForwardFailure no
    SendEnv LC_LVX_TTY
# END localvoxtral claude context (h1a2b3c4)
```

28511 is an example. The app generates *your* Mac's number and puts it in
both the block and the install command below. The two must always name the
same port. Change one alone and the hooks post into a port nothing forwards,
which fails open and looks exactly like nothing happening.

ExitOnForwardFailure no is the default. With yes, ssh refuses to open the
session at all when that port is already bound on the remote. That now
happens only when your own second window connects to the same host.
**Dictation context must never cost you the shell.**

The price of no is that a failed forward is silent. The hooks get connection
refused, fail open, and you get no context. Step 4 exists to catch that.

**2. Install the plugin on the remote host:**

```sh
ssh builder
claude plugin marketplace add T0mSIlver/localvoxtral
 claude plugin install localvoxtral-remote@localvoxtral --config 'token=<YOUR-TOKEN>' --config 'port=28511'
```

Note the leading space on the second line. With `HISTCONTROL=ignorespace` (bash)
or `setopt HIST_IGNORE_SPACE` (zsh), it keeps the token out of your shell
history. If it landed there anyway, rotate the token in the app.

Nothing else is installed. The marketplace add resolves the
[marketplace file](../../.claude-plugin/marketplace.json) at the repository
root. The plugin is two JSON files and two POSIX shell scripts. The
[hook script](plugins/localvoxtral-remote/hooks/post.sh) needs only `sh` and `curl` on the host, and the
opt-in [status-line script](plugins/localvoxtral-remote/hooks/statusline.sh)
needs only sh.

**3. Show the dictation indicator in herdr (optional).** After you confirm,
the app appends an agents-panel row to the remote host's herdr config. It
does so only when the config has no agents table and no rows key, and
otherwise leaves the file unchanged. The row is defined in the
[enrollment service](../../Sources/localvoxtralCore/ClaudeContext/ClaudeRemoteEnrollmentService.swift).

**4. Check it.** Press **Check Setup** in the sheet. The app runs two
read-only checks over ssh and reports what they mean:

* **Connection & tunnel.** The app sends an unauthenticated session-start hook
  through the forward. HTTP 401 is the pass, because the refusal proves the
  request crossed the tunnel and localvoxtral answered.

  That holds only when this Mac's listener is bound, which the app also
  knows. A 401 that arrives while the app's bind failed came from whatever
  else holds the port, and the app reports it as such.

  No answer means no live tunnel right now. A host with no curl gets its own
  verdict, because the plugin's hook script is a curl one-liner.
* **Claude plugin on the host.** The app lists the host's plugins with the
  usual install locations added to PATH, since a non-interactive ssh command
  skips your login rc. "Not installed" and "Claude Code was not found here"
  are separate answers with separate fixes.

The app shows, logs and copies no probe output, only verdicts it composed.
The plugin list prints the plugin's stored config. After a rotation that
holds a token this app no longer knows, and so could not redact.

To run the equivalent commands by hand, see
[Checking the setup](../../docs/remote-claude-context.md#checking-the-setup).

### Show the connection indicator on a host

This is the local plugin's bottom-bar indicator, adapted to a host where
everything fails open. It tells you whether hooks from this host reach
localvoxtral on your Mac, so you don't find out by dictating into nothing.

| Line | Meaning |
|---|---|
| lvx ● (green) | the Mac holds this session |
| lvx ◐ (yellow) | the Mac answers but does not hold this session |
| lvx ○ (grey) | no recent answer, listener, or tunnel |
| lvx ✕ (red) | the token is missing or rejected, or another HTTP error occurred |

With NO_COLOR set or a dumb terminal, the same glyphs render without color.

Set it up on the **remote host**:

1. The plugin ships the renderer, but Claude Code's plugin cache path changes
   with each version. Copy the script somewhere stable:

   ```sh
   cp ~/.claude/plugins/marketplaces/localvoxtral/integrations/claude-code/plugins/localvoxtral-remote/hooks/statusline.sh \
      ~/.claude/localvoxtral-statusline.sh
   ```

2. Add this to the host's ~/.claude/settings.json:

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "sh ~/.claude/localvoxtral-statusline.sh"
     }
   }
   ```

If you already run a status line on that host, call the script from it and
append its one line.

The renderer never dials the tunnel. A status line re-runs constantly, and
every dial against a live forward with no app behind it makes ssh print a
connection failure onto your terminal. That is the flood of messages the hook
script's backoff exists to stop (see
[When the app is not running on your Mac](#when-the-app-is-not-running-on-your-mac)).

Instead, the hook script records private stamps for the host and for each
session. The renderer checks for both a recent connection and this session's
join. It prints only one of the fixed lines above, and never echoes a byte
from the payload or either stamp.

### Keep the tunnel open for sessions nobody sits at

The tunnel exists only while *something* holds it, normally your own
ssh builder session. Anything the host starts on its own has no such
session:

* Claude Desktop sessions on the host. Desktop's ssh clears all forwardings
  and never carries the forward, so a host you reach only from Desktop has no
  tunnel at all. Host setup detects Desktop, from its server directory under
  ~/.claude/remote on the host, and turns the toggle below on.
* Claude Code remote-control servers, run as systemd user services with
  lingering enabled
* t3 code and other harnesses that spawn Claude Code into a worktree
* cron jobs, CI runners, anything headless
* sessions you only ever look at through a herdr 0.9 federated view. The link
  herdr holds is not a shell of yours. It may have lost the forward to an
  earlier session that has since ended (first session wins, see
  [A second session to the same host](../../docs/remote-claude-context.md#a-second-session-to-the-same-host))

Those sessions publish hooks like an interactive one, into a tunnel that is
not there. As always, the failure is silent, and dictation gets no context.

So each enrolled host's row in Settings has **Keep the tunnel open**. With it
on, localvoxtral holds that host's forward itself. It runs ssh in batch mode
with no remote command, forwarding the host's port to 127.0.0.1:8473 on your
Mac. The [forward supervisor](../../Sources/localvoxtral/ClaudeContext/ClaudeRemoteForwardSupervisor.swift)
builds the exact command.

It is off by default, per host, because an app that opened ssh connections
you did not ask for would be a worse bug than the one it fixes.

This path involves no token. The credential lives in the remote plugin's
config, and this process only carries bytes for it.

Its options differ from your ~/.ssh/config block on purpose:

* **ExitOnForwardFailure=no**, like your config block. The process reads your
  config, so it also requests every other forward your Host block declares. A
  refusal of one of those must not cost this tunnel. The process watches
  ssh's error output for a refusal that names its own port instead.
* **No ClearAllForwardings.** That option also clears the forward on the
  command line, so the tunnel would never be created. The duplicate of your
  block's own forward collapses into one request.
* **ForkAfterAuthentication=no, ControlPath=none, PermitLocalCommand=no** keep
  your config from backgrounding, multiplexing or running a local command
  under a process the app has to be able to stop.
* **ServerAliveInterval=30 and ServerAliveCountMax=3.** Without them, a NAT or
  a sleeping laptop leaves a half-dead connection holding the remote bind,
  which makes the next connection fail.

How the app keeps it running:

* Restarts back off exponentially (0.5 s, 1 s, 2 s and so on, capped at 30 s)
  and stop after five consecutive failures rather than hammering your ssh
  server.
* A **refused bind** never enters that loop. When your own session holds the
  port, the row reads **Tunnel up through an existing ssh session.**
  Otherwise it reads **Port held on that host. Checking again every 5 min.**
  Either way the app dials again every five minutes.
* When the Mac wakes or its network changes, a stopped or waiting tunnel
  starts over at once.
* After a network change, the host keeps the old connection's port bound
  until its sshd notices the connection is gone. The row shows the port as
  held until then. ClientAliveInterval 30 in the host's sshd config, with the
  default ClientAliveCountMax 3, makes sshd drop it within about 90 seconds.

The listener always binds before the forwards start. A forward opened into an
unbound port would give every hook connection refused (silent, fail-open),
while making ssh print a connection failure into your remote terminal on every
dial.

Turning the toggle on or off takes effect immediately, with no relaunch.
Revoking a host, or quitting the app, stops its forward.

## SSH to a host you have NOT enrolled

No enrollment means no tunnel, no token, and no hooks. Your session is
unchanged and the pane stays screen-only and unjoined.

Nothing about this feature is on by default. With no enrolled host, the app
binds no port at all.

An ENROLLED host's plain ssh session does join, on the connection itself (see
[A plain ssh host session](#a-plain-ssh-host-session)).

## Update, uninstall or revoke

### Update the plugin on your Mac

Once installed, the plugin stays current on its own. At launch the app runs
Claude Code's plugin update on an installed plugin older than the one it
ships. That update never uninstalls, so a failed update leaves the old plugin
working.

The app also repoints
~/Library/Application Support/localvoxtral/claude/publisher at its own
publisher binary. The hook script tries that link before the install-time
publisher path, so moving the app needs no reinstall.

The **Plugin** row shows **Update** only when that launch-time update failed,
and no install button while the plugin is current.

To update by hand, re-read the marketplace, then reinstall. Reinstalling
beats Claude Code's plugin update here, because that update accepts no config
flag. An update that cannot reset the publisher path leaves the hook script
on a stale path whenever the app has moved:

```sh
claude plugin marketplace add "/Applications/localvoxtral.app/Contents/Resources/claude-code-marketplace"
claude plugin uninstall localvoxtral@localvoxtral
claude plugin install localvoxtral@localvoxtral \
  --config 'publisher_path=/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook'
```

#### Why the app registers a mirror

The app registers a mirror of this directory at
~/Library/Application Support/localvoxtral/claude/marketplace, not the app
bundle's own copy. It refreshes the mirror at launch whenever its contents
differ.

Claude Code stores the marketplace as the path it was given and re-reads it at
every session start. Registering a path inside the bundle would tie your
Claude Code to wherever that app was: a try-pr build under /private/tmp, a
disk image, a folder you later renamed.

When that path goes away, the plugin stops loading. Claude Code reports
"Marketplace localvoxtral failed to load: cache-miss" and no session runs the
hooks. The only sign is a half-filled lvx ◐ status line.

The **Plugin** row then reads **Installed, but not loading** and offers
**Repair**. Launch does the same repair on its own with one marketplace add,
which on a directory source repoints the name (verified on Claude Code 2.1.x).
It leaves the installed plugin, its publisher path and its cache untouched.

Launch only takes over a registration that cannot keep working: one that is
already gone, one inside an app bundle, or one Claude Code reports as not
loading. **A marketplace you registered from a checkout is left alone**,
because that is how you edit the hook script and see the edit.

#### What the app changes in your Claude Code config

Everything the app does goes through Claude Code's own plugin commands.

**Plugin install and uninstall never touch ~/.claude/settings.json.** That
file is yours and Claude Code owns its schema. The plugin commands are the
supported interface, and third-party apps editing the file corrupt setups
during unrelated upgrades.

The one exception is the opt-in
[connection indicator](#connection-indicator-opt-in-status-line). Its
installer writes only the status-line key, after a one-sentence consent.
Over a status line you wrote yourself it writes only through **Combine…**,
which keeps your command and puts it back on **Remove**.

### Uninstall the plugin from your Mac

This removes the plugin, then deregisters the marketplace, so nothing of ours
is left in your Claude Code config:

```sh
claude plugin uninstall localvoxtral@localvoxtral
claude plugin marketplace remove localvoxtral
```

### Update an enrolled host

In the app, a host in **Settings → Remote hosts** has an **Update Host…**
button unless it is revoked or already current (see
[Manage an enrolled host](#manage-an-enrolled-host)). Its consent sentence
names the local files and the enrolled ssh alias. **Set Up** runs the same
seven-step flow as enrollment.

The app never uses the display name in place of the alias. A host enrolled
before aliases were recorded must be re-enrolled before the app can update
it.

The app does not install from GitHub. It writes its own copy of this
marketplace to ~/.local/share/localvoxtral/claude-marketplace on the host and
registers that directory. So the host gets the plugin version the app was
built for, even when main has moved on.

**Update by hand.** Re-running the setup commands does **not** pick up a
newer plugin. Verified on Claude Code 2.1.220:

* Adding a marketplace the host already has exits 0, says it is already on
  disk, and does **not** refresh the clone.
* Installing an installed plugin exits 0, says it is already installed, and
  does **not** change the version. It *does* apply a new token in its config
  flag, which is why rotating a token reuses that same command.

So the update takes its own pair of commands. It keeps your token, because
the plugin update preserves the stored config:

```sh
ssh builder 'claude plugin marketplace update localvoxtral'
ssh builder 'claude plugin update localvoxtral-remote@localvoxtral'
# Only needed once, for a host enrolled before per-Mac ports existed, and
# harmless every time after. `plugin update` has no `--config`, and `install`
# merges config per key, so this sets the port without touching your token.
ssh builder "claude plugin install localvoxtral-remote@localvoxtral --config 'port=28511'"
```

Order matters. The plugin update installs whatever the host's marketplace
clone currently offers, so without refreshing the clone first nothing
updates.

Non-interactive ssh skips your login shell's rc, so the app's version of
these commands first adds the usual Claude Code install locations to PATH.
Add them yourself if a plain ssh command to the host can't find claude.

### Uninstall from a host and revoke it

1. Remove the plugin and its marketplace from the host:

   ```sh
   ssh builder 'claude plugin uninstall localvoxtral-remote@localvoxtral'
   ssh builder 'claude plugin marketplace remove localvoxtral'
   ```

2. Delete the BEGIN/END block from ~/.ssh/config on your Mac.
3. Then **revoke the host in localvoxtral**. This step matters most, because
   the token dies on your Mac, not on the remote.

Uninstalling the plugin only stops the host asking. Revoking stops the app
answering it, immediately and without a restart. Rotating instead of revoking
issues a new token and kills the old one with no grace period.

## Reference

### Fail-open, always

If localvoxtral is not running, not installed, or its socket is absent, the
hook drains its input, prints nothing, and exits 0. The same goes for a
missing publisher binary, a full socket, or a slow app. The publisher gives
up after about 250 ms.

Your Claude session never stalls, warns or fails because dictation context
was unavailable. Nothing in this plugin can block a turn.

On each hook event, Claude Code runs the local plugin's
[hook script](plugins/localvoxtral/hooks/publish.sh). It finds the app's
publisher binary and runs it as a **child process**, rather than letting the
publisher replace the script.

A replacing publisher that cannot start at all (wrong architecture,
quarantined bundle, missing dynamic library) would return its failure as the
hook's exit code. You would see an error on your turn, which fail-open exists
to prevent. The script stays alive to swallow that failure.

The publisher writes one bounded JSON line to a private UNIX socket owned by
the app, and exits.

### What the local plugin reports

The [hook list](plugins/localvoxtral/hooks/hooks.json) names each event. From
each one, localvoxtral learns:

| Event | What localvoxtral learns |
|---|---|
| A session starts | a session exists; its working directory and terminal |
| You submit a prompt | your latest prompt (the "prior prompt" when you next dictate) |
| The working directory changes | the session moved to another directory |
| Claude reads, edits or writes a file or notebook | which files were just read or edited |
| The turn stops | the turn finished |
| A permission prompt, a question dialog, a URL dialog, or an agent needing input | the session waits for you: the kind of wait, never its text |
| The session ends | the session is gone (the app evicts it immediately) |

The plugin does not subscribe to Claude Code's file-changed event. Claude Code
fires it only for a hook that declares paths to watch, and the tool events
already report every file the model touches without watching your whole tree.

### What crosses the socket

Only what this allowlist names:

* the event name, session id, timestamp, and working directory
* your prompt text, from the prompt event only
* what a waiting notification waits for: its type, one of the four above. Its
  message and title stay behind, since they quote tool names and command text
* the session's title, which Claude Code sends when a session starts, so the
  app can show the session by it
* absolute file paths from the file tools above
* safe process metadata: pid, parent pid, controlling tty, the terminal
  program's name, and the multiplexer and bridge handles that say which pane
  the session lives in. Those are herdr's pane id and socket path, cmux's
  surface id and socket path, the Remote Control bridge session id, and the
  Claude Desktop session id. Never the rest of the environment. The
  [publisher](../../Sources/ClaudeHookPublisherCore/ClaudeHookPublisher.swift)
  holds the exact list.

These never cross:

* **transcript contents**. The publisher drops the transcript path entirely,
  so there is nothing to scrape and no pointer to it.
* **the agent's replies**. The stop event's last assistant message is dropped.
* **file contents**: what a write or edit puts in a file, and what a read
  returns.
* **command strings**. The plugin does not subscribe to the shell tool.
* **anything claiming to be trusted**. The app decides trust from UNIX peer
  credentials, never from a field on the wire.

Every field is length-capped at both ends. Hook content is never logged.

### How the remote plugin reaches your Mac

The remote plugin subscribes to session start, prompt submit, stop,
working-directory change, tool use and session end, so the app sees a new
remote session before its first prompt. Otherwise the events match the local
table above.

Each hook runs the plugin's POSIX shell
[hook script](plugins/localvoxtral-remote/hooks/post.sh). It posts the hook's
event JSON over HTTP to the per-Mac port on the *remote* loopback, with the
token as a bearer header.

OpenSSH's reverse forward carries that to your Mac's loopback port 8473,
where the app listens. The app **allocates that remote port per Mac**, a
stable number in 28473 to 30472 derived from a per-install identity. So two
Macs enrolled against one host never ask for the same bind (see
[What this does not protect against](#what-this-does-not-protect-against)).

The hook script reads the token and the port from the environment Claude Code
gives command hooks, from the plugin's config. It passes the token to curl
through a private temporary file, so the token never appears in any process's
argument list. It needs only `sh` and `curl` on the host.

It fails open, silently and printing nothing, when either is missing, the
token is unset, the tunnel is down, or the app does not answer within a
second.

Claude Code's declarative HTTP hooks cannot do this job. Claude Code fills
their header variables from the process environment only, and never puts
plugin config options there. An HTTP hook would always authenticate with an
empty token and be refused.

**What the app answers.** The app answers every hook with the same fixed
body, which tells Claude Code to suppress output. A response header says
joined or unknown, and the hook script stores that verdict for the session's
status line. The script still prints only the fixed body.

Joined means the app recorded the hook for that session, not that a dictation
will join it. That also needs a join that recognizes the window you dictate
into.

**The plugin version header.** Each post also sends the plugin's own version,
a constant in the hook script. The app checks that it has a strict numeric
shape. It records the version for that host only once it fully accepts the
request, at the same points it notes the "last seen" time. So a request the
revocation re-check refuses records nothing.

The app uses the version for one thing. When the host's plugin is older than
the app's, Settings shows the fixed "Update available" line and a prominent
**Update Host…** button.

The record keeps the highest version any of the host's hooks reported since
the app launched. Claude Code applies a plugin update only when a session
restarts, so sessions already running keep the old plugin's script and send
no version. Their hooks must not clear the flag for an update that has
already landed.

Nothing else opens a port, and nothing is reachable from your LAN.

### When the app is not running on your Mac

The hook script's own failures are always silent, but one message is out of
its reach. While an ssh session holds the forward and localvoxtral is not
running, each dial makes **ssh itself, on your Mac**, print
`connect_to 127.0.0.1 port 8473: failed.`
onto the terminal. It lands over whatever is drawn there (a herdr pane, the
Claude Code screen), once per hook.

That error output belongs to another process on another machine, so no
redirect in the plugin can reach it. Silencing it in ssh would take a quiet
log level, which also hides host-key warnings, and the plugin won't make that
trade for you.

So the hook script stops dialing instead. After a transport-level failure,
every hook except prompt submit, session start and session end skips the
tunnel for the next 5 minutes.

`UserPromptSubmit` still dials every time. One line per submitted prompt while
the app is down tells you context is off, and your first prompt after the app
comes back gets context immediately. That completed exchange (any HTTP status,
even a 401) clears the backoff for everything else.

Session start and session end also dial every time. They fire once per
session and every session on the host shares the backoff. Skipping them hid
sessions started in those 5 minutes and kept ended ones joinable.

### What crosses the tunnel

The same allowlist as the local plugin, plus two additions:

* **File excerpts.** Bounded, sanitized excerpts of the read, edit and write
  tools' input and output, at most 512 bytes each and at most 8 kept per
  session.
* **Where the session runs.** An allowlisted set of environment values, sent
  as request headers rather than in the body. The body stays Claude Code's
  event JSON byte for byte, because the host is not assumed to have jq.

The environment values are herdr's pane id, socket path and session name;
cmux's surface id and socket path; the Remote Control bridge session id; the
Claude Desktop session id; the tmux socket and pane; the screen session; the
zellij session; the ssh tty; the ssh connection; LC_LVX_TTY; the hook
script's own parent pid; the name of the session's repository; and the
branch checked out. The
[hook script](plugins/localvoxtral-remote/hooks/post.sh) holds the exact
list.

The repository name is the basename of its main checkout, as git reports it,
so every worktree of one repository keeps one set of learned terms. The
branch names a session in a linked worktree, as it does for a local one.

The hook script sends each value only if it is non-empty, at most 200
characters, and made purely of ASCII letters and digits plus
`._:/@+,=%-`. It drops anything else rather than escaping it.

The ssh connection is the one value the script reshapes. sshd writes its four
fields separated by spaces, and a space could end a header line. So the
script re-joins them with commas, and drops the value entirely if it is not
exactly four fields.

These values tell the app WHERE the session runs, so it can tell whether the
pane you are dictating into is this one, never what the pane contains. No
other environment value goes into these headers. On the Mac they are only
labels. They can never become a local path, a socket the app dials, or a
process it probes.

These additions exist only for remote sessions. A local session's files are
on your Mac and the app reads them directly. A remote session's files are on
a machine the app does not reach into, so what the hook quotes is all it will
ever know.

Every excerpt is stripped of control characters, C1 escapes, bidi overrides
and zero-width characters before it is stored. Foreign text stays text and
cannot act on anything.

Transcript contents, shell command strings, and anything claiming to be
trusted still never cross, exactly as locally. The hook script rebuilds two
events' bodies instead of posting them as they are:

* A waiting notification sends the session id and the notification type, so
  its message and title never leave the host.
* A stop sends the session id and working directory, so the agent's reply
  never leaves it either.

### What the token can and cannot do

A host presenting a valid token can give localvoxtral **remote context**, and
nothing more. It cannot make the app read a local file, and code enforces
this, not a policy.

The listener tags every session it accepts as remote, whatever the payload
says. It reduces a remote working directory to a bare label with no path that
a collector could read. A *local* process that connects to the listener gets
the same treatment, so connecting there can only downgrade you.

Each host's sessions are namespaced under the host id its token
authenticated. So two hosts can never collide on a session id or forge each
other's sessions.

### What this does not protect against

**A malicious process running as YOU on the remote host.** This cannot be
solved here. That process can already read ~/.claude, where Claude Code keeps
the plugin's configured token, so it can read the token whatever the app
does. It could just as well read your source, your keys and your shell
history without involving localvoxtral at all.

Enrolling a host means trusting that host's user account as far as it is
already trusted. The token limits what a host can do to *localvoxtral*
(remote context only, never a local file read), not what a compromised
account can do to itself.

**Two Macs enrolled against one host.** Each Mac forwards its *own* port, so
they cannot compete for one remote bind.

That used to cause silent cross-delivery (issue #215). The first connection
kept the forward, and the second connected anyway, because a failed forward
does not stop the session. Every event on that host, bearer token included,
went to the *first* Mac. It answered 401, which the hook script reads as a
completed exchange, and nothing reported it.

What per-Mac ports do **not** change is that one host runs one Claude Code
install storing one port. The Mac whose config was installed last receives the
events, and the other Mac sees no traffic. You can see that only one Mac is
served, and no credential reaches the wrong Mac's listener.

**A process on your Mac that squats 127.0.0.1:8473 before the app binds it.**
Loopback ports on macOS go to whoever binds first, with no ownership. A
squatter cannot authenticate your hosts, because it does not have the token
hashes, which never leave the host file readable only by you.

But it does receive whatever the remote sends, including the bearer token
itself, before anything rejects it. So the app reports a bind conflict
instead of routing around it. Settings says the port is in use and offers
Retry, rather than quietly moving to another port where you would never learn
a squatter was there.

If you see that status, find the process before assuming it is a stale copy
of the app:

```sh
lsof -nP -iTCP:8473 -sTCP:LISTEN
```

Then rotate the tokens of any host that connected meanwhile.

**Anyone who can write your ~/.ssh/config.** They can point the forward
somewhere else. That is true of every use of that file. So the app writes it
only after showing you the exact block and getting your confirmation. It
writes only its own marker-delimited block, never the rest of the file.

### Configuration

| Setting | Purpose |
|---|---|
| ~/Library/Application Support/localvoxtral/claude/publisher | Link to the publisher, repointed by the app on every launch. The hook script tries it right after `LOCALVOXTRAL_CLAUDE_HOOK_BIN`. |
| `publisher_path` (plugin config) | Absolute path to the publisher. localvoxtral sets it for you at install time. The hook script uses it when the link above is missing or dangling. Claude Code passes it to the script as an environment variable. |
| `LOCALVOXTRAL_CLAUDE_SOCKET` | Socket path. Defaults to ~/Library/Application Support/localvoxtral/run/claude-context.sock on macOS, or localvoxtral/claude-context.sock under the XDG runtime directory on Linux. |
| `LOCALVOXTRAL_CLAUDE_HOOK_BIN` | Path to the publisher; overrides everything else. |
