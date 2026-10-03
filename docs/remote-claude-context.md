# Remote Claude Code context over SSH

Dictate into a Claude Code session running on another machine, and localvoxtral
still spells your code, file names and identifiers correctly.

The app's enrollment sheet runs the whole setup as one flow that checks each
step as it goes. It shows one consent sentence, a **Details** link to this
page, and one status line per step. Settings never shows a token, a command or
file contents. Every command the app runs is listed in
[Commands the app runs](#commands-the-app-runs) at the end of this page.

## What the feature is

localvoxtral polishes dictation better when it knows what you are working on.
On this Mac it reads your terminal's repository directly. On a remote host it
never does.

Instead, the Claude Code session on that host reports a little about itself
through a plugin. The reports travel over an SSH tunnel you already have open,
and localvoxtral uses them to spell technical terms.

A remote host can send:

- the prompt you last sent that session, and its working directory (as a label);
- short, sanitized excerpts the session's own hooks report;
- enough identity to know which session your terminal is showing.

A remote host can never:

- make localvoxtral read a file on your Mac
  ([why](integration-matrix.md#no-repo-context-for-a-remote-session));
- impersonate another enrolled host. Each session belongs to the host whose
  token authenticated it;
- reach your dictation while the toggle is off.

### The toggle and revocation

Two switches do different things.

**The toggle** (**Send diff, recent files and last prompt**, in **Settings ›
Context**) gates what a dictation attaches. With it off, nothing a host sent
reaches the polisher.

The toggle does not close the port. While any enrolled host is unrevoked, the
listener keeps accepting and caching valid hook records.

**Revocation is what actually stops the host**: **Revoke** or **Remove** in
**Settings › Remote hosts**. It takes effect at once, without a relaunch. The token is
invalidated on this Mac, not on the host, and the listener then rejects the
host's requests, since another enrolled host may still hold the port open.
With no active hosts left, the listener closes the port. Uninstalling the
remote plugin only stops the host asking.

### Where polish context goes

Like local context, it goes only to a polisher on this Mac unless you turn
on **Send context to non-local polishing servers**
([Polish context](coding-agents.md#polish-context-what-each-toggle-sends)).

## Enroll a host

Before you start, check the host:

- It needs POSIX sh and curl. The plugin's hook script is a curl one-liner, so
  without curl it can never deliver anything.
- It needs Claude Code, Mistral Vibe, or both. The setup run fails only on a
  host with neither.

Then enroll it:

1. In **Settings › Remote hosts**, fill in the enrollment form. If the machine
   is saved in herdr, you can import it instead (see below).
2. Press **Set Up** in the enrollment sheet. For a host that is already
   enrolled, press **Update host…** in its row, then **Set Up**.
3. Read the status lines. The run stops at the first failure and shows the
   exact fix.

**Importing a herdr saved machine.** If you use herdr's saved machines (herdr
0.9's `herdr machine add`), you do not have to type a destination. **Settings ›
herdr** lists them under **Saved machines**, one row per machine with its saved
ssh target. **Import…** fills the enrollment form with the machine's name and
target.

A machine saved as user@host or as an ssh:// destination needs a Host alias in
your `~/.ssh/config` first. Add one, then import it. After the form, the flow
is the same for everyone.

### How enrollment works

The app runs these steps in order and checks each one. It shows one short
status sentence per step and stops at the first failure with the exact fix.

1. **Mac SSH config.** Writes the marked Host block that opens the tunnel and
   sends this terminal's tty. See
   [1. A block in your SSH config](#1-a-block-in-your-ssh-config).
2. **Mac shell startup.** Adds the block that exports `LC_LVX_TTY` to your
   login shell's startup file. A block that is already applied, an unsupported
   shell and a symlinked startup file are reported, not failed.
3. **Remote plugin.** Installs the plugin, or updates it when present, and
   reads the installed version back in the same SSH session to verify it. See
   [2. The plugin on the host](#2-the-plugin-on-the-host).
4. **Remote environment.** Proves `LC_LVX_TTY` crosses to the host. The app
   sends a fresh random value for that one call and compares the echo exactly.
   It never logs the value, and a mismatch names the side at fault.
5. **Remote herdr.** When herdr is on the host, adds the agents-panel row (only
   when no agents table or rows key exists) and reloads herdr's config. "Not
   installed" and an already-customized table are reported, not failed.
6. **Check Setup.** Runs the two read-only checks last and shows their verdict
   as the final status line. See [Checking the setup](#checking-the-setup).

While the host's **Keep the tunnel open** is off, the first step also checks
the host for Claude Desktop. When Desktop is there, the run turns **Keep the
tunnel open** on, because Desktop's ssh never carries the tunnel. The toggle
stays yours to turn off.

When the host has Mistral Vibe, the run also installs the Vibe hooks; see
[Mistral Vibe on an enrolled host](#mistral-vibe-on-an-enrolled-host).

### If the tty value does not cross

Step 4 fails when the host never receives `LC_LVX_TTY`. If this Mac's
`ssh -G` output shows no sendenv line covering the host, step 1's block is
missing.

Otherwise the remote sshd refused the variable. Add `AcceptEnv LANG LC_*` to
`sshd_config` on that host and reload sshd there. That needs root on that
host, and the app never attempts it for you.

To check by hand, run this from a window where the shell startup block ran:

```sh
ssh <alias> 'echo "[$LC_LVX_TTY]"'
```

Empty output means the value is not crossing.

## What setup leaves on each side

### 1. A block in your SSH config

The app adds this block to `~/.ssh/config`:

```
# BEGIN localvoxtral claude context (<host-id>)
Host <your-alias>
    RemoteForward <this-Mac's-port> 127.0.0.1:8473
    ExitOnForwardFailure no
    SendEnv LC_LVX_TTY
# END localvoxtral claude context (<host-id>)
```

**The forward.** While you have an SSH session open to that host, the
RemoteForward line makes that port *on the host* a private pipe back to
localvoxtral on your Mac. Nothing listens on the network and nothing is
exposed.

The Mac-side end is always 8473, the app's own listener. Only the remote end
varies; see [The forward port is per-Mac](#the-forward-port-is-per-mac).

**The tty.** The SendEnv line carries this terminal's tty into the remote
session, so a plain `ssh` Claude Code session can be joined to the window you
are dictating into. Set `LC_LVX_TTY` from your shell first. **Settings › Remote
hosts › Plain SSH › Terminal setup** writes the line for you, or see the
[integration README](../integrations/claude-code/README.md). With the variable
unset, this line sends nothing and costs nothing.

The LC_ prefix matters because sshd's stock `AcceptEnv LANG LC_*` already lets
it through. The environment also travels per session channel, so it survives
ProxyJump and ControlMaster where a TCP-level match cannot. Most ssh configs
already send LC_*, and this line covers the ones that do not.

**The delimiters.** The two # lines mark the block. localvoxtral finds and
replaces exactly the block between them, so applying the config twice changes
nothing instead of adding a duplicate Host stanza.

That matters because OpenSSH uses the first match, so a stale duplicate above a
fresh one would silently win. The rest of your config stays byte for byte the
same.

**When the app will not write it.** The app inserts the block after the
one-sentence consent. It refuses to write when `~/.ssh/config` or `~/.ssh` is a
symlink (a dotfiles setup, where an atomic rename would replace your link), or
when `~/.ssh` is not exclusively yours to write. It also refuses, for both
writing and Remove Host, when the file holds this host's `# BEGIN` line without
its `# END` line or the other way round: writing past a lone marker would add a
second block OpenSSH ignores, and a later update would delete your lines between
the two. In those cases, edit the real file yourself using the block above.

### 2. The plugin on the host

To install the plugin by hand, run this on the host:

```
claude plugin marketplace add T0mSIlver/localvoxtral
claude plugin install localvoxtral-remote@localvoxtral --config 'port=<this-Mac's-port>'
claude plugin configure localvoxtral-remote@localvoxtral --values-stdin
```

The last command reads the token from stdin: type `{"token":"<token>"}`, press
Return, then Control-D. A token typed there stays off the host's process list,
where `--config 'token=<token>'` would show it to every account on the host.

Always set the port and the token together. The `port` option is the same number the
SSH config block binds. Change one without the other and every hook on that
host posts into a port nothing forwards. The hooks fail open, so this looks
exactly like nothing happening.

The remote plugin, localvoxtral-remote, is separate from the local localvoxtral
plugin, not a mode of it. It declares hooks and one executable,
`localvoxtral`, which Claude Code puts on its sessions' PATH and which runs
only `localvoxtral doctor` (see [Checking the setup](#checking-the-setup)).
It adds no skill, agent or status line, so it never spends your tokens.

Its [hook script](../integrations/claude-code/plugins/localvoxtral-remote/hooks/post.sh)
needs only POSIX sh and curl. The host needs no localvoxtral binary, no jq and
no Node.

**What stays off this Mac's process list.** The app can run these commands for
you over SSH, sending them through the remote shell's stdin. The token never
appears in the arguments of any process on your Mac, so ps here cannot show it,
and the app never writes it to a file here.

**What the host can see.** The token stays out of every argument list on the
host too. The app hands it to `claude plugin configure --values-stdin` in a
here-document, so the host's process table (`/proc/<pid>/cmdline` on Linux)
never shows it. That command needs a recent Claude Code; on an older one setup
stops and asks you to update Claude Code on the host.

The plugin stores the token in its user config under `~/.claude`, readable by
anything running as you on that host.

So the token limits what a remote host may ask localvoxtral for. It does not
limit what someone who can read your files on that host can read. If you think
someone saw the token, **rotate it** ([A token](#3-a-token)).

### 3. A token

The app generates the token on enrollment and passes it straight into the
setup run you consented to. Settings never shows it.

localvoxtral stores only a hash, so after an interrupted or dismissed setup,
or when someone may have seen the token, you recover by rotating. Rotation
takes effect immediately with no grace period, and running **Set Up** with
the new token is the whole recovery.

The token authorizes one thing: a host that presents it may *contribute remote
context*. The listener tags every session it accepts as remote, whatever the
payload claims, so a host cannot get itself treated as local.

**Revoking the host in localvoxtral is the real off switch**
([The toggle and revocation](#the-toggle-and-revocation)).

A malicious process running as you *on the remote host* can read `~/.claude/`
and so that host's token. The token limits what a remote host can do. It does
not protect the host from itself.

**Shell history.** The generated install command starts with a space. With
`HISTCONTROL=ignorespace` (bash) or `setopt HIST_IGNORE_SPACE` (zsh), that
keeps the token out of the host's shell history. It is a habit, not a
guarantee.

If you paste the command into a shell that records it anyway, or you are not
sure, **rotate the token**. Running the setup from the app avoids shell history
altogether, since the token goes through SSH stdin (see above).

## Checking the setup

Press **Check Setup** in the enrollment sheet. It runs two read-only checks
and explains the results. The checks below run them by hand.

Or run `localvoxtral doctor` in a Claude Code session on the host, or ask
the agent why a dictation did not join: plugin 1.36.0 ships a skill that
tells it about the command. It runs
them all from there: the forward port, the 401 without the token and the 200
with it, the plugin version each running session loaded, the Vibe hooks and
the last hook's outcome. It then prints the Mac's own checks for this host,
fetched through the tunnel, without local paths and without your other
hosts. It reads the token from
`~/.claude/.credentials.json` or `~/.vibe/localvoxtral/remote/token` and
never prints it. On a macOS host, Claude Code keeps the token in the
Keychain, and the token check says so. Without the Claude Code plugin, run
`sh ~/.vibe/localvoxtral/remote/doctor.sh`. It needs plugin 1.25.0 or Vibe
hooks 1.10.0 on the host.

### Is the tunnel live, and is localvoxtral behind it?

```
ssh -o ClearAllForwardings=yes builder 'curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Content-Type: application/json" -d "{}" http://127.0.0.1:28511/v1/hook/SessionStart'
```

The ClearAllForwardings option keeps this ssh from opening the tunnel itself.
Without it, the check carries your config block's forward, answers through a
tunnel that closes when the check does, and looks healthy on a host where
nothing else ever holds the tunnel.

28511 is an example. Replace it with your allocated port, the one the
RemoteForward line in your `~/.ssh/config` block names.

**`401` is the success answer**, provided localvoxtral is listening on this
Mac. The probe sends no credential on purpose, so a refusal proves the request
crossed the tunnel and something on the Mac side answered.

It does not prove that the something was localvoxtral. If the app's own bind
failed, whatever holds the listener port (8473) here receives the forwarded
request instead, and its rejection looks identical from the host. Check the
listener line in **Settings › Remote hosts** as well. The in-app check does
exactly this, which is how it tells the two cases apart.

000, or a curl connection error, means nothing holds the tunnel right now. No
SSH session of yours to that host carries it, and the app is not holding it.
Turn on **Keep the tunnel open**, or run the check again without the
ClearAllForwardings option to see whether your config block opens it at all.

Any other status code means something other than localvoxtral answered on that
port. Find it and quit it.

If the host has no curl, the plugin can never deliver anything, however healthy
the tunnel is. Run `command -v curl` on the host to find out. The in-app check
reports it as a separate verdict.

### Is the plugin installed on the host?

```
ssh <alias> 'PATH="$HOME/.claude/local:$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" claude plugin list'
```

Look for localvoxtral-remote in the output. The PATH prefix is needed because a
non-interactive SSH command skips your login shell's rc files. So claude is
often off PATH here, even on a host where it works when you log in.

The in-app check also looks in `~/.nvm/versions/node/*/bin`, where
npm-installed Claude Code lands. The quoted PATH above cannot expand a glob. If
claude lives under nvm on that host, run `command -v claude` in a normal shell
there and prepend that directory instead.

### Is the forward being requested at all?

```
ssh -v <alias> true 2>&1 | grep -i 'remote forward'
```

A failure line here is *expected* whenever another live session to that host
already holds the tunnel (see
[A second session to the same host](#a-second-session-to-the-same-host)). The
port check gives the real answer either way, so the app does not run this one.

## Fix a missing or dropped tunnel

Hook events reach your Mac only while something holds the tunnel. When nothing
does, you get no context and no error.

### Why a failed forward is silent

`ExitOnForwardFailure yes` tells ssh to refuse the whole session if it cannot
create a requested forward. That sounds safer, but here it is worse.

The port is already bound whenever a second window to the same host has the
tunnel, so yes would refuse you a shell because dictation context was
unavailable. Dictation context should never cost you your login. The block
therefore sets it to no.

The price of no is that a failed forward is *silent*. The hooks get connection
refused, fail open, and you get no context. Step 6's **Check Setup** exists to
catch that.

### A second session to the same host

Within one Mac, the first SSH session gets the forward. A second concurrent
session tries to bind the same port on the remote and fails. Because
ExitOnForwardFailure is no, it connects anyway with no tunnel of its own.

That is expected and harmless. The first session's tunnel is still up and
still carries the host's events. So a raw `ssh -v` forward check is misleading
on a healthy setup, and the in-app check probes the port instead of reading
ssh's warnings.

The problem comes when that first session ends. The port frees, but the
sessions that failed to bind never ask again. A host whose open sessions all
started while another one held the forward has no tunnel at all, and no
terminal says so.

The sessions left open are usually long-lived ones that are not shells, such as an
editor's remote server, a herdr federation link, a socket forward. **Keep the
tunnel open** (below) fixes this, because the app re-binds the port itself
instead of leaving it to whichever session came first.

### Keep the tunnel open for sessions with no terminal

Hook events reach your Mac only while something holds the tunnel, normally one
of your own SSH sessions. A session a harness starts on the host (t3 code,
claude remote-control services, any headless runner) has no such terminal, so
its context goes nowhere.

Claude Desktop's sessions on the host are in the same position, because
Desktop's ssh clears every forward.

Turn on **Keep the tunnel open** in that host's row and the app holds the
forward itself. It reconnects as needed, including after the Mac wakes or
changes network. Host setup turns it on when it finds Claude Desktop on the
host.

### After a network change

The host keeps the old connection's port bound until its sshd notices the
connection is gone. Until then the row reads "Port held on that host", and the
app checks again every five minutes.

To shorten the wait, add `ClientAliveInterval 30` to the host's `sshd_config`.
With the default `ClientAliveCountMax 3`, sshd then drops a dead connection
within about 90 seconds.

### The forward port is per-Mac

The remote end of the tunnel is not a fixed 8473. Each localvoxtral install
derives its own port in the range **28473 to 30472** from a per-install identity
stored on that Mac.

Every place that names a port takes it from that one value. That covers the SSH config
block, the install command's `port` option, the in-app check, and the update
commands.

**The failure it prevents.** When two SSH connections ask for the same remote
listen port, only the first gets it and keeps it. The second stays connected
with only a warning, because the block sets ExitOnForwardFailure to no on
purpose.

Before per-Mac ports, a second Mac's enrollment silently delivered *this*
host's events, and its bearer token, to the first Mac. That Mac rejected them
with a 401, which the remote hook script reads as a completed exchange. Nothing
reported a problem. Distinct ports make that state impossible.

**The limit it leaves.** Per-Mac ports do **not** fix this. One remote host
runs one Claude Code install with one plugin config, so its `port` names
exactly one Mac. Enroll two Macs against the same host, and only the
most recently installed config receives events.

The other Mac's tunnel binds fine and sees no traffic. That limit is visible,
and no Mac receives another's credentials.

### What happens when things are missing

Everything fails open, silently. If sh or curl is missing on the host, the
tunnel is down, localvoxtral is not running, or the app does not answer, the
hook exits successfully and you get no context.

This feature never blocks a Claude Code turn, and the delay it can add is
bounded. The hook script's curl call runs with a one-second limit, so at worst
it waits one second, gives up and exits 0.

Plain `ssh` to a host you have not enrolled keeps working exactly as before, with no
tunnel, no token and no hooks.

One case is noisier. While a session holds the tunnel and localvoxtral is *not
running*, ssh on your Mac prints `connect_to 127.0.0.1 port 8473: failed.` into
the remote terminal on every dial.

That is another process's stderr, which the plugin cannot silence, so after a
failed dial the hook script backs off for five minutes. Prompt submits still
try, so context returns with your first prompt once the app is back.

## Update a host enrolled before per-Mac ports

An enrollment made before per-Mac ports uses the legacy shared 8473 on both
ends and keeps working. The app never forces a migration.

When you want one, use **Update host…** in the host's row. It updates the
marketplace copy and the plugin, stores this Mac's allocated port, and rewrites
this host's SSH config block in the same action, so the two halves always
agree.

Sessions already running on the host keep the old hook script until you run
`/reload-plugins` in a Claude Code session (Claude Code 2.1.283) or restart a
Vibe session, since Vibe has no such command.

Your token is preserved: `claude plugin update` keeps the stored config, and
each --config option merges per key.

**Why the update is not a reinstall.** The update refreshes the marketplace and
calls plugin update, because a bare plugin install does not update. On Claude
Code 2.1.220 it exits 0 with "already installed", and marketplace add does not
refresh an existing clone.

**Which plugin version the host gets.** The host gets the plugin version this
app ships, not the one on GitHub's main branch. Otherwise the app would reject
a newer plugin it was not built for. A host that a newer app updated goes back
to this app's version, and keeps its token.

A host enrolled from GitHub moves to the app's copy on its next update, because
marketplace add on an existing name replaces its source in place. Don't run
`claude plugin marketplace remove localvoxtral` to switch sources. It
uninstalls the plugin and deletes the token (Claude Code 2.1.283).

## Use other agents and features on a host

### Mistral Vibe on an enrolled host

An enrolled host can report its Mistral Vibe sessions too, over the same
tunnel. Vibe is one step of the host's setup run.

The enrollment sheet's **Set Up** and the row's **Update Host…** install the
Claude Code plugin and then, when Vibe is on the host, the Vibe hooks. A host
without Vibe skips that step. A host without Claude Code skips the plugin step
and the plugin half of the final check. The run fails only when the host has
neither.

**After installing Vibe on a host.** The row offers **Update Host…** while the
plugin or the Vibe hooks are outdated or not yet heard from. So after
installing Vibe on a host, relaunch localvoxtral and press it.

When the Vibe hooks already report this version, a run leaves them alone. It
sends no Vibe script and keeps their token.

**When the run refuses.** The run writes nothing when:

- a path under `~/.vibe` is a symlink;
- `~/.vibe/hooks.toml` has an unpaired marker, a marker inside a multi-line
  string, a hook named localvoxtral-remote-files or localvoxtral-remote-turn
  outside the block, or a key right after the block;
- the file changed during the run.

**Its token.** The Vibe hooks get a second credential for the same host,
created for this run. The app keeps only a hash of the host's first token,
which went into the Claude Code plugin's config, so Vibe cannot reuse it.

The listener trusts the new token from just before the run writes it,
alongside the previous Vibe token until that write succeeds. So an update that
loses its connection cannot lock the host out.

The Vibe token authenticates as the same host, and **Rotate token**,
**Revoke** and **Remove** end it like the first. Removing a host leaves the
files on it, as it leaves the Claude Code plugin, and their token no longer
authenticates.

The token sits in `~/.vibe/localvoxtral/remote/token`, readable by any process
running as you on that host. The Claude Code plugin's token already has the
same exposure in `~/.claude`.

The four SSH calls of this step are listed under
[The Vibe step](#the-vibe-step). What runs on the host, what it sends and what
it never sends is in the
[Vibe hooks README](../integrations/vibe/README.md#on-an-ssh-host).

### Terms from the coding agent on a host

With **Ask the coding agent for each new project's terms** on
([Terms from your coding agent](dictation.md#terms-from-your-coding-agent)), a
remote Claude Code or Vibe session's project gets its terms from a run on the
host.

The Mac cannot run it, because the repository is on the host, and the Mac holds only a
label for it, never a path it could hand to ssh. The run goes like this:

1. **Mac, at commit.** A dictation joins a remote Claude Code or Vibe session
   whose project (shown as `remote:<label>`) has no answer and no attempt in the
   last 24 hours. The host must have reported localvoxtral-remote 1.15.0 or
   Vibe hooks 1.2.0. A project answered with an older version of the request
   is asked once more, on a host whose runner asks the newer one: the
   project's sentence from localvoxtral-remote 1.20.0 or Vibe hooks 1.5.0,
   names people say from 1.21.0 or 1.6.0. **Update Host…** installs them
   ([sessions already running need a reload](#update-a-host-enrolled-before-per-mac-ports)).
   The Mac marks that session in memory for 10 minutes and records an
   attempt on the project.
2. **Mac, next hook.** The reply to that session's next hook carries a
   terms-wanted header, once. The body stays the constant one.
3. **Host hook script.** The
   [hook script](../integrations/claude-code/plugins/localvoxtral-remote/hooks/post.sh)
   matches the header exactly and takes a per-project stamp in its state
   directory by an atomic mkdir. The state directory is
   `$XDG_RUNTIME_DIR/localvoxtral/terms-3/`, else
   `~/.cache/localvoxtral/terms-3/`.

   The project is the git toplevel of the hook's working directory, or that
   directory outside git. A project marked done, or attempted in the last 24
   hours, is skipped.

   Otherwise the hook script starts the
   [terms runner](../integrations/claude-code/plugins/localvoxtral-remote/hooks/terms.sh)
   detached and returns. The runner gets its own session (setsid, or an
   ignored hangup signal where setsid is missing) and a clean environment with
   only HOME, PATH, LANG, USER and LOGNAME. Every descriptor points at
   /dev/null, and the token arrives on stdin. (On macOS, claude finds its
   keychain login only with USER set.)
4. **Host runner.** The runner runs the same read-only claude -p or vibe -p as
   the Mac's local run, in the project directory, with a 180-second watchdog.

   Vibe runs under `~/.vibe/localvoxtral/remote/vibe-home/<stamp>`, one per
   project, which holds only links to your config.toml and .env, so no Vibe
   hook fires.

   The runner posts the first 16 KiB of the answer to the listener's terms
   endpoint, with the token in a header file and the session id in a header. A
   200 marks the project done.

   From plugin 1.19.0 and Vibe hooks 1.4.0, the answer also carries the run's
   usage for the Mac's usage log. Claude Code sends its whole result object.
   A Vibe run adds the input, cached input and output token counts it read
   from its session log, in a header.
5. **Mac, terms endpoint.** The listener authenticates the token, scopes the
   session id under that host, and accepts only an answer for a live session
   it asked, from the agent it asked, once.

   It files the terms under the project it recorded in step 1, never one the
   host names, through the same filters as a local answer, and keeps the
   sentence on the project for quick capture's classifier. Anything else is
   refused with a status and a log line that names the reason, never the body.

Only the answer crosses the tunnel, as a JSON list of terms and one sentence:
a few hundred bytes. With Claude Code's result object around it, about 3.4 KiB
for 40 terms, the answer adds only token counts, the cost and the run's
timings.

The run bills the host's Claude Code login or Mistral key, under the same caps
as the local run. A process that squats the forward port could send the header
too; the host's stamp bounds that to one run per project per 24 hours.

### Quick capture on a host

A quick capture ([Quick capture](coding-agents.md#quick-capture)) routed to a
remote project is drafted on its host, for the same reason. The repository is
there. The host also reports the project's README, which the router reads to
tell projects apart.

Both need localvoxtral-remote 1.17.0 or Vibe hooks 1.3.0 on the host.

**Projects.** Which remote repositories the router offers is in
[Which projects a capture can go to](coding-agents.md#which-projects-a-capture-can-go-to).

**README.** The reply to a hook from a session in a remote project the Mac
holds, with no README summary or one a week old, asks for the README. The hook
script then starts the
[capture script](../integrations/claude-code/plugins/localvoxtral-remote/hooks/capture.sh)
detached, at most once per project per 24 hours.

The capture script posts the first 16 KiB of the project's README.md to the
listener. The Mac keeps the first two prose paragraphs, 400 characters at
most, on the project. From localvoxtral-remote 1.35.0 and Vibe hooks 1.17.0,
the script skips a README, AGENTS.md or CLAUDE.md that is a symlink, so a
committed link cannot send a file from elsewhere on the host.

**Draft.** The capture waits up to 10 minutes for a hook from a live session in
its project. The reply to that hook asks for a draft. With no such session, or
only sessions on older hooks, the capture waits in the Inbox with your words
and a note.

The hook script starts the capture script's draft run detached, one at a time
and at most 20 a day. With localvoxtral-remote 1.24.0 or Vibe hooks 1.9.0, the
run drafts in two stages:

1. It asks the listener for the capture's search words, then posts the
   project's context: the openings of its README and AGENTS.md (or
   CLAUDE.md), `git grep` hits for those words, and, when gh works there, the
   open issues, the last 40 closed issues and the last 20 merged pull
   requests, 96 KiB at most.
2. The Mac writes the first draft from it. The run polls the listener every 3
   seconds, for 3 minutes at most, until it answers: no check due (a
   question, a task or a note), or the prompt to check the issue's draft
   against the code.

An older hook script lists the open issues only, and gets back the prompt to
draft from your words alone.

It then runs the Mac's drafting command in the project:

- Claude Code with Read, Glob and Grep confined to the checkout, capped at
  $0.50;
- or Vibe with its read-only tools, hooks and MCP off, capped at $0.30.

Both get 20 turns and a 6-minute watchdog (4 minutes before 1.24.0 and 1.9.0).
From localvoxtral-remote 1.37.0 and Vibe hooks 1.18.0, the prompt goes to the
agent on stdin, since other users on the host can read a command line from `ps`.
The run posts the output, at most 60 KiB, to the listener with how the run
ended. A Vibe run (hooks 1.4.0) adds its token counts in a header; Claude
Code's output already carries its usage.

**What crosses and what can't.** Each route takes one answer, only from the
host, session and agent the Mac asked, and files it under the project the Mac
recorded. Your words cross the tunnel only in the prompt reply and, as search
words, in the words reply, to the session of the project the router chose.

Nothing is filed on the host. gh only lists issues and pull requests, git only
greps, and the agent has no shell. The context and the draft are untrusted
text: the context is only quoted into the first draft's request, and the
draft is read as a local draft is.

Whatever answers on the forward port can send both asks. It never sees a
capture, since those go only to the Mac's listener, but it can hand the host a
prompt of its own. That is why the agent cannot read outside the checkout, and
why the hook script runs one draft at a time and 20 a day.

### Federated herdr machines

If your local herdr 0.9 client is showing a machine from another host,
localvoxtral can join the Claude Code session on that machine without an ssh
process in the terminal.

It reads which machine herdr selected, reaches that machine's herdr over the
app-managed tunnel, and checks a short-lived panel marker on your screen.

If the marker does not appear, use **Settings › herdr › Saved machines › Mic
indicator in herdr panel** to add the indicator row to this Mac's herdr config.
Then reload config in herdr. localvoxtral cannot reload herdr for you.

The join can only pick from sessions whose hooks have reached this Mac, and a
federated view carries none of your own ssh sessions to hold the hook tunnel.
herdr's link uses your ssh config, but it may have lost the forward to a
session that has since ended (see
[A second session to the same host](#a-second-session-to-the-same-host)).

Turn on **Keep the tunnel open** in that host's row. Without it, the join
abstains with "no live session on the selected herdr session" in the log, and
the status line on the host shows a grey dot.

### tmux, screen, and window titles

September 2026 removed the window-title marker, along with its setting and the
tmux and screen title-passthrough advice (see "What was removed (September
2026)" in the [Claude Code integration README](../integrations/claude-code/README.md)).

A remote session joins by the tty echo (`LC_LVX_TTY`, above) or by matching
the SSH connection the focused terminal holds. The "A plain `ssh host`
session" section of that README covers the full mechanics and their limits:
jump hosts, ControlMaster, tmux, screen and zellij.

Without either join you get **no context from that pane at all**, not a
reduced amount. localvoxtral attaches context only to a session it positively
joined. A lookup that cannot identify the session abstains rather than
guessing, so an unjoined pane contributes nothing.

herdr users need nothing here, because localvoxtral joins a herdr pane by its pane id,
not by a title.

## Uninstall a host

On the remote host, run:

```
claude plugin uninstall localvoxtral-remote@localvoxtral
claude plugin marketplace remove localvoxtral
```

On this Mac:

1. Remove the `# BEGIN localvoxtral claude context (<host-id>)` … `# END …`
   block from `~/.ssh/config`.
2. In **Settings › Remote hosts**, **Revoke** (or **Remove**) the host.

Step 2 is the one that matters
([The toggle and revocation](#the-toggle-and-revocation)).

**What Remove undoes for you.** Removing the host reverses the Mac side. It
removes the SSH config block, and the shell startup block only when no other
host remains.

A problem undoing either never blocks the removal, because the registry entry
is the off switch. An alert names anything the app could not rewrite, with its
manual fix. You uninstall the remote half by hand, by design.

## Commands the app runs

The enrollment sheet's **Details** link opens this page, and this section is
the complete list. The app writes the two Mac files directly. For every remote
script except the tunnel check, it starts this exact process and sends the
script through stdin:

```sh
ssh -o BatchMode=yes -o ClearAllForwardings=yes -- <alias> /bin/sh -s
```

On this Mac, the token exists only in that stdin script.

### The plugin step

The remote plugin step runs `claude plugin list --json` before and after the
change. Between those reads, it writes the app's own copy of the plugin
marketplace to `~/.local/share/localvoxtral/claude-marketplace` on the host. It
registers that directory as the localvoxtral marketplace and runs whichever of
these commands apply:

```sh
M="$HOME/.local/share/localvoxtral/claude-marketplace"
claude plugin marketplace add "$M"
claude plugin marketplace update localvoxtral
claude plugin update localvoxtral-remote@localvoxtral
claude plugin install localvoxtral-remote@localvoxtral --config 'port=<this-Mac's-port>'
claude plugin configure localvoxtral-remote@localvoxtral --values-stdin <<'LVX_EOF_TOKEN'
{"token":"<token>"}
LVX_EOF_TOKEN
```

Only a run with a new token runs the last command. When it fails, setup stops
with exit code 48, and a plugin this run installed is uninstalled again, so the
next run installs it with a token.

The plugin step finds claude the same way the plugin check does (see
[The Check Setup step](#the-check-setup-step)).

### The environment step

This step sends the following script with a fresh `LC_LVX_TTY` value in the SSH
child's environment:

```sh
printf 'LVX_TTY:%s\n' "${LC_LVX_TTY-}"
```

If the value does not cross, the app inspects the effective local config with:

```sh
ssh -G -- <alias>
```

### The herdr step

```sh
set -eu
if ! command -v herdr >/dev/null 2>&1; then
  for lv_dir in "$HOME/.claude/local" "$HOME/.local/bin" "$HOME/bin" /opt/homebrew/bin /usr/local/bin "$HOME"/.nvm/versions/node/*/bin; do
    if [ -x "$lv_dir/herdr" ]; then PATH="$lv_dir:$PATH"; break; fi
  done
fi
if ! command -v herdr >/dev/null 2>&1; then
  printf '%s\n' LVX_HERDR_ABSENT
  exit 0
fi
lv_config=${HERDR_CONFIG_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}
if [ -f "$lv_config" ] && grep -Eq '^[[:space:]]*\[ui\.sidebar\.agents\][[:space:]]*(#.*)?$|^[[:space:]]*rows[[:space:]]*=' "$lv_config"; then
  printf '%s\n' LVX_HERDR_CUSTOMIZED
  exit 42
fi
mkdir -p "$(dirname "$lv_config")"
touch "$lv_config"
cat >> "$lv_config" <<'LOCALVOXTRAL_HERDR_PANEL'
[ui.sidebar.agents]
rows = [["state_icon", "workspace", "tab"], ["agent"], [{ token = "$lvmark", dim = true }]]
LOCALVOXTRAL_HERDR_PANEL
herdr server reload-config
printf '%s\n' LVX_HERDR_CONFIGURED
```

When the grep matches, the step stops without changing the file.

### The Check Setup step

The tunnel check runs in two steps. The first clears forwardings, so it can
only reach a tunnel another connection already holds (the app's own, a
terminal's, an editor's). That is the tunnel your hooks use between checks:

```sh
ssh -o BatchMode=yes -o ClearAllForwardings=yes -- <alias> /bin/sh -s
```

The second step runs only when nothing answered. It drops that option, so the
config block's own forward is open while it runs. A 401 there means the block
works but nothing keeps the tunnel open:

```sh
ssh -o BatchMode=yes -- <alias> /bin/sh -s
```

Both send the same stdin script, which checks for curl and posts an
unauthenticated empty JSON body:

```sh
set -u
command -v curl >/dev/null 2>&1 || { printf '%s\n' 'LVX_NO_CURL'; exit 0; }
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' http://127.0.0.1:<this-Mac's-port>/v1/hook/SessionStart 2>/dev/null) || code=000
[ -n "$code" ] || code=000
printf 'LVX_HTTP:%s\n' "$code"
```

The plugin check uses the first SSH command above and runs `claude plugin list`.
It finds claude on PATH, then in `~/.claude/local`, `~/.local/bin`, `~/bin`,
`/opt/homebrew/bin`, `/usr/local/bin` and `~/.nvm/versions/node/*/bin`. Last,
it tries the newest Claude Desktop CLI in `~/.claude/remote/ccd-cli/<version>`.

While the host's **Keep the tunnel open** is off, the run's first step also
checks for Claude Desktop, with the first SSH command above and this script:

```sh
if [ -d "$HOME/.claude/remote/srv" ]; then printf 'LVX_DESKTOP:yes\n'; else printf 'LVX_DESKTOP:no\n'; fi
```

### The Vibe step

The Vibe step runs `ssh -o BatchMode=yes -o ClearAllForwardings=yes -- <alias> /bin/sh -s`
four times, each with its own script on stdin:

1. Read the host: whether vibe is on the non-interactive PATH (with
   `~/.local/bin` added), the installed hooks version, and
   `~/.vibe/hooks.toml` (base64, at most 256 KiB) with its cksum.
2. Write `~/.vibe/localvoxtral/remote/` at mode 0700 with post.sh, terms.sh,
   capture.sh, compact.py and port (0600). Put a marked block of two hooks
   tables into `~/.vibe/hooks.toml`.

   This Mac computes the new hooks.toml text by the same rules as the local
   install. The script writes it only if the file's cksum is still the one
   step 1 saw.
3. Read the host again and compare the version and the block.
4. Write token (0600). It goes last, so a run that stops earlier leaves an
   existing install working with its current token.

### Shell startup blocks

For zsh and bash, the app adds this marked block to `~/.zshrc`,
`~/.bash_profile`, or an existing `~/.bashrc`:

```sh
# localvoxtral plain-ssh join (begin)
# Publishes this terminal's tty so localvoxtral can tell which window a
# Claude Code session over ssh belongs to. Remove this block in
# Settings, or by hand.
if [ -z "${LC_LVX_TTY:-}" ] && [ -z "${SSH_TTY:-}" ]; then
  case "$(tty 2>/dev/null)" in /dev/*) LC_LVX_TTY="$(tty)"; export LC_LVX_TTY ;; esac
fi
# localvoxtral plain-ssh join (end)
```

For fish, it writes `~/.config/fish/conf.d/localvoxtral.fish`:

```fish
# localvoxtral plain-ssh join (begin)
# Publishes this terminal's tty so localvoxtral can tell which window a
# Claude Code session over ssh belongs to. Remove this block in
# Settings, or by hand.
if not set -q LC_LVX_TTY; and not set -q SSH_TTY
    set -l __lvx_tty (tty 2>/dev/null)
    if string match -q -- '/dev/*' "$__lvx_tty"
        set -gx LC_LVX_TTY "$__lvx_tty"
    end
end
# localvoxtral plain-ssh join (end)
```
