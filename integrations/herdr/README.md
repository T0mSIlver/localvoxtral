# herdr

[herdr](https://herdr.dev) is a terminal multiplexer for coding agents. When a
Claude Code, opencode, Codex or Mistral Vibe session runs in a herdr pane,
localvoxtral joins that exact pane: it reads its screen for context and writes
your words into it through herdr itself.

herdr needs no plugin. Install the plugin or hooks of the agent you run in the
pane, as for any terminal: [Claude Code](../claude-code/README.md),
[opencode](../opencode/README.md), [Codex](../codex/README.md) or
[Mistral Vibe](../vibe/README.md). **Settings → herdr** shows whether herdr
is detected and lists herdr's saved machines.

## What you get

**The right pane, and only that pane.** herdr puts its own terminal in front
of every pane, so the usual match on the terminal's tty can't tell panes
apart. localvoxtral asks herdr which pane has focus and joins on its pane id.
Three checks must agree: herdr's pane id, herdr's own record of which session
the pane holds, and the agent running in the pane's foreground. If any of them
disagrees, the app joins nothing and attaches no context.

**Screen context from that pane.** With **Send agent's terminal screen** on
in **Settings → Context**, the polisher reads the text of the joined pane
from herdr. Neighboring panes and the rest of the herdr view never reach it.
[Dictating into Claude Code](../../docs/coding-agents.md#dictating-into-claude-code)
has a video of a join inside herdr.

**Words that land in the pane, whatever has focus.** Dictation goes into the
joined pane through herdr's socket, not as keystrokes. It needs no clipboard
and lands even if you click another window while you speak:

- In **Overlay Buffer**, the app sends the text once, when it commits.
- In **Live Auto-Paste**, it sends each finished phrase as you speak.
- "Send it" presses Enter in that pane
  ([Voice commands](../../docs/dictation.md#voice-commands)).

With polishing off, this works in a herdr running on this Mac. On a remote or
federated herdr (below), it needs the context join, so polishing must be on;
otherwise the app types the words as keystrokes.

**opencode in a herdr pane.** The opencode plugin's prompt relay puts your
words into opencode's prompt directly. In a local herdr, it finds the pane
even with polishing off, so the words don't fall back to keystrokes.

**"Send that to" a session in another pane.** In Overlay Buffer, ending a
dictation with "send that to" and a session's name sends it to that session
and presses Enter there. A session in a local herdr pane receives it without
its pane coming forward.

## Set up on this Mac

1. Install the plugin or hooks for your agent from its pane in Settings.
2. Start the agent in a herdr pane.
3. Dictate into the pane.

## Set up on a remote host

localvoxtral can join a Claude Code or Mistral Vibe session in a herdr pane on
an ssh host. Codex and opencode on a remote host don't join.

1. Enroll the host in **Settings → Remote hosts**
   ([How enrollment works](../../docs/remote-claude-context.md#how-enrollment-works)).
   If you saved the machine in herdr, **Settings → herdr → Saved machines →
   Import…** fills in the form.
2. **Set Up** checks for herdr on the host. When it finds herdr, it adds a
   row to the agents panel of the host's herdr config and reloads herdr. The
   row shows a short marker that localvoxtral uses to recognize the pane. If
   your config already sets its own agents panel, Set Up leaves it alone and
   says so; add the row by hand from
   [Set it up](../claude-code/README.md#set-it-up) in the remote plugin's guide.
3. From a terminal on your Mac, open herdr on the host over ssh, and
   dictate into the agent's pane.

**Why the herdr panel must be visible.** Before using a remote herdr's
focused pane, the app proves that the window you look at shows that server:
it puts a fresh marker in herdr's agents panel and looks for it on your
screen. The marker is missing when the panel is collapsed, narrower than 21
columns, too short for the entry, or lacks the row from step 2.

When the marker is missing, the app checks how you started herdr instead. It
accepts one ssh process, to exactly one enrolled host, that runs plain
`herdr` or `herdr --session <name>`. It refuses `herdr terminal attach`, and
an ssh session where you typed herdr afterwards, since neither proves what
the window shows. The [integration matrix](../../docs/integration-matrix.md)
has the details.

## Set up a federated herdr machine

herdr 0.9 can show a machine from another host in your local herdr client.
localvoxtral joins the Claude Code session on that machine with no ssh process
in your terminal.

1. Enroll the host as above.
2. Open **Settings → herdr → Saved machines → Mic indicator in herdr panel**
   and press **Set up…**. It adds the marker row to this Mac's herdr config.
3. Reload the config in herdr. localvoxtral can't do it for you.
4. Turn on **Keep the tunnel open** in the host's row in **Settings → Remote
   hosts**.

Step 4 matters because a federated view holds no ssh session of yours to
carry the session's hooks back to your Mac. Details:
[Federated herdr machines](../../docs/remote-claude-context.md#federated-herdr-machines).

## Safety rules

herdr's socket gives full control over every pane, so localvoxtral limits
itself to two actions on the joined pane: add text, and press Enter.

- **No stray Enter.** Text that holds a line break or another control
  character never goes through herdr, since herdr would pass a line break
  to the pane as Enter.
- **No Enter at a shell.** Before pressing Enter, the app checks that the
  agent still runs in the pane's foreground. If the pane is back at its shell
  prompt, no Enter is pressed and the dictation stays in History.
- **Never typed twice.** When herdr refuses a write, the app types the text
  only if your keystrokes would reach the same pane: its terminal in front and
  herdr's focus on that pane. Otherwise, and whenever a write may already have
  landed, the text stays in History.

## What doesn't work

- **Two herdr servers running on one Mac.** The app can't tell which one you
  are looking at, so it joins neither.
- **Repository context from a remote pane.** A remote join gets the pane's
  screen, your last prompt, the names of files the agent recently touched and
  short tool excerpts. It reads nothing from the host's repository: no
  status, no diff, no file list.
- **"Send that to" a remote or federated session.** The popover says "Can't
  send to that session yet".
- **Codex and opencode on a remote host.** Only Claude Code and Mistral Vibe
  send their hooks back from a host.

## Fix common problems

- **Remote pane not joined.** Show herdr's agents panel, make it at least
  21 columns wide and tall enough for the session's entry, and check the marker
  row is in the host's herdr config. Or start herdr with a plain
  `ssh <host> herdr`.
- **Federated machine not joined, host's dot grey.** Turn on **Keep the
  tunnel open** for that host.
- **Marker missing in a federated view.** Reload herdr's config after
  **Set up…**.

## See also

- [Integration matrix](../../docs/integration-matrix.md): how each terminal
  and agent joins, herdr included.
- [Remote Claude Code over SSH](../../docs/remote-claude-context.md): host
  enrollment and the tunnel.
