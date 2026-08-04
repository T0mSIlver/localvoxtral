# Remote Claude Code context over SSH

Dictate into a Claude Code session that is running on another machine, and have
localvoxtral spell your code, file names, and identifiers correctly anyway.

This page is the long version. The app's enrollment sheet is deliberately short:
three steps, no comments in anything you copy, and a **Check Setup** button that
runs the checks and tells you what they mean.

---

## What the feature is

localvoxtral polishes dictation better when it knows what you are working on. On
this Mac it can read your terminal's repository directly. On a remote host it
cannot — and never does. Instead, the Claude Code session on that host reports a
little about itself through a plugin, over an SSH tunnel you already have open,
and localvoxtral uses that to ground technical terms.

What a remote host can contribute:

- the prompt you last sent that session, and its working directory (as a label);
- short, sanitized excerpts the session's own hooks report;
- enough identity to know which session your terminal is showing.

What it can never do:

- make localvoxtral read a file on your Mac. A remote working directory is a
  string, not a path — the app has no way to turn one into a local file read;
- impersonate another enrolled host. Sessions are namespaced by the host whose
  token authenticated them;
- send anything at all while the feature is off, or after you revoke it.

The feature is gated on **Use Claude Code project files as polish context** in
Settings › Context, and on a local polishing endpoint.

---

## How enrollment works

Enrolling a host does three things.

### 1. An `~/.ssh/config` block

```
# BEGIN localvoxtral claude context (<host-id>)
Host <your-alias>
    RemoteForward 8473 127.0.0.1:8473
    ExitOnForwardFailure no
# END localvoxtral claude context (<host-id>)
```

`RemoteForward` means: while you have an SSH session open to that host, port
8473 *on the host* is a private pipe back to localvoxtral on your Mac. Nothing
listens on the network; nothing is exposed.

The two `#` lines are not commentary — they are delimiters. localvoxtral finds
and replaces exactly the block between them, so applying the config twice is a
no-op instead of a duplicate `Host` stanza (OpenSSH is first-match-wins, and a
stale duplicate above a fresh one would silently win). Everything else in your
config is preserved byte for byte.

The app will insert the block for you after a confirmation that repeats the
exact text, or you can copy it and paste it yourself. It refuses to write when
`~/.ssh/config` or `~/.ssh` is a symlink (a dotfiles setup — an atomic rename
would replace your link) or when `~/.ssh` is not exclusively yours to write. In
those cases, copy and paste.

### 2. The plugin on the host

```
claude plugin marketplace add T0mSIlver/localvoxtral
 claude plugin install localvoxtral-remote@localvoxtral --config 'token=<token>'
```

`localvoxtral-remote` is a different plugin from the local `localvoxtral` one,
not a mode of it. It declares hooks only — no skill, no command, no agent, no
status line, so it never spends your tokens. Its shim is POSIX `sh` plus `curl`
and nothing else: no localvoxtral binary, no `jq`, no Node on the remote host.

The app can run both commands for you over `ssh`, sending them through stdin so
the token never appears in any process's arguments.

### 3. A token

The token is generated on enrollment and shown **once**. localvoxtral stores
only a hash of it, so it genuinely cannot be shown again — rotation is the
recovery path, and it takes effect immediately with no grace period.

What the token authorizes is narrow: a host that presents it may *contribute
remote context*. The listener tags every session it accepts as remote no matter
what the payload claims, so a host cannot talk its way into being treated as
local.

**Revoking the host in localvoxtral is the real off switch.** It takes effect
immediately, without a relaunch, and with no enrolled hosts left the app stops
listening on the port at all. Uninstalling the remote plugin only stops the host
asking.

One honest caveat: a malicious process running as you *on the remote host* can
read `~/.claude/` and therefore that host's token. The token bounds what a
remote host can do; it does not protect the host from itself.

---

## Why `ExitOnForwardFailure` stays `no`

`ExitOnForwardFailure yes` tells `ssh` to refuse the whole session if a
requested forward cannot be created. That sounds safer, and here it would be
worse: the port is already bound whenever a second window to the same host has
the tunnel, so `yes` would refuse you a shell because a dictation nicety was
unavailable. A convenience feature must never cost you your login.

The price of `no` is that a failed forward is *silent*. The hooks get connection
refused, fail open, and you simply get no context. That silence is exactly what
step 3's **Check Setup** exists to break.

## A second session to the same host

The first SSH session to a host wins the forward. A second concurrent session
tries to bind the same port on the remote, fails, and — because
`ExitOnForwardFailure` is `no` — connects anyway with no tunnel of its own. That
is fine: the first session's tunnel is still up and still carries the host's
events.

The port itself is per-Mac (8473 on the Mac side; the remote-side port is
derived from a per-install identity), so two different Macs asking one host for
a forward do not collide.

## Shell history and rotation

The generated install command is prefixed with a space. With
`HISTCONTROL=ignorespace` (bash) or `setopt HIST_IGNORE_SPACE` (zsh) that keeps
the token out of the host's shell history. It is a habit, not a guarantee.

If you paste the command into a shell that records it anyway — or you are simply
not sure — **rotate the token**. That is what rotation is for. Running the setup
from the app instead avoids the question entirely: the token goes through SSH
stdin, never through a command line.

## tmux, screen, and window titles

localvoxtral joins a remote session by a marker the hook writes into the window
title. A multiplexer owns that title, so by default the marker never reaches
your terminal and the pane stays unjoined. In `~/.tmux.conf`:

```
set -g set-titles on
```

Without it you still get the off-screen context (prompt, working directory,
files) — you just do not get the screen join. herdr users need nothing here: a
herdr pane is joined by its pane id, not by a title.

## What happens when things are missing

Everything fails open, silently. If `sh` or `curl` is absent on the host, if the
tunnel is down, if localvoxtral is not running, or if the app simply does not
answer — the hook exits successfully and you get no context. A Claude Code turn
is never blocked or delayed by this feature.

Plain `ssh` to a host you have not enrolled keeps working exactly as before: no
tunnel, no token, no hooks.

---

## Checking the setup

Use **Check Setup** in the enrollment sheet. It runs two read-only checks and
interprets them for you. If you would rather run them by hand:

### Is the tunnel live, and is localvoxtral behind it?

```
ssh <alias> 'curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" -d "{}" http://127.0.0.1:8473/v1/hook/SessionStart'
```

**`401` is the success answer.** The probe deliberately sends no credential, so
being refused is the proof: the request reached localvoxtral (which alone holds
the token hashes) through the tunnel. `000` — or a curl connection error — means
no tunnel is live right now, which usually just means you have no SSH session
open to that host at this moment. Any other status code means something that is
not localvoxtral answered on that port; find it and quit it.

### Is the plugin installed on the host?

```
ssh <alias> 'PATH="$HOME/.claude/local:$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" claude plugin list'
```

The PATH prefix is not decoration. A non-interactive SSH command skips your
login shell's rc files, so `claude` is frequently off PATH here even on a host
where it works perfectly when you log in. Look for `localvoxtral-remote` in the
output.

### Is the forward being requested at all?

```
ssh -v <alias> true 2>&1 | grep -i 'remote forward'
```

A failure line here is *expected* whenever another live session to that host
already holds the tunnel — see "A second session to the same host" above. The
port check is the truth either way, which is why the app does not run this one.

---

## Uninstalling

On the remote host:

```
claude plugin uninstall localvoxtral-remote@localvoxtral
claude plugin marketplace remove localvoxtral
```

On this Mac:

1. Remove the `# BEGIN localvoxtral claude context (<host-id>)` … `# END …`
   block from `~/.ssh/config`.
2. In Settings › Context › Remote hosts, **Revoke** (or **Remove**) the host.

Step 2 is the one that matters. Revocation is what actually stops the host: the
token dies on this Mac, not on the remote. With no active hosts left, the
listener closes its port.
