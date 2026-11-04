# herdr

[herdr](https://herdr.dev) is a terminal multiplexer for coding agents. When a
Claude Code, opencode, Codex or Mistral Vibe session runs in a herdr pane,
localvoxtral joins that exact pane and reads its screen for context.

herdr needs no plugin. Install the plugin or hooks of the agent you run in the
pane, as for any terminal: [Claude Code](https://t0msilver.github.io/localvoxtral/integrations/claude-code/),
[opencode](https://t0msilver.github.io/localvoxtral/integrations/opencode/), [Codex](https://t0msilver.github.io/localvoxtral/integrations/codex/) or
[Mistral Vibe](https://t0msilver.github.io/localvoxtral/integrations/vibe/). **Settings → herdr** shows whether herdr
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
[Dictating into Claude Code](https://t0msilver.github.io/localvoxtral/docs/coding-agents/#dictating-into-claude-code)
has a video of a join inside herdr.

**Words that land in the pane.** Dictation is typed into the focused
terminal, as in any other pane. "Send it" presses Enter there only after the
app has read back that herdr's focused pane is still the joined session
([Press Return with "send it"](https://t0msilver.github.io/localvoxtral/docs/dictation/#press-return-with-send-it)).

## Set up on this Mac

1. Install the plugin or hooks for your agent from its pane in Settings.
2. Start the agent in a herdr pane.
3. Dictate into the pane.

## Set up on a remote host

localvoxtral can join a Claude Code or Mistral Vibe session in a herdr pane on
an ssh host. Codex and opencode on a remote host don't join.

1. Enroll the host in **Settings → Remote hosts**
   ([How enrollment works](https://t0msilver.github.io/localvoxtral/docs/remote-claude-context/#how-enrollment-works)).
   If you saved the machine in herdr, **Settings → herdr → Saved machines →
   Import…** fills in the form.
2. **Set Up** checks for herdr on the host. When it finds herdr, it adds a
   row to the agents panel of the host's herdr config and reloads herdr. The
   row shows a short marker that localvoxtral uses to recognize the pane. If
   your config already sets its own agents panel, Set Up leaves it alone and
   says so; add the row by hand from
   [Set it up](https://t0msilver.github.io/localvoxtral/integrations/claude-code/#set-it-up) in the remote plugin's guide.
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
the window shows. The [integration matrix](https://t0msilver.github.io/localvoxtral/docs/integration-matrix/)
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
[Federated herdr machines](https://t0msilver.github.io/localvoxtral/docs/remote-claude-context/#federated-herdr-machines).

## Safety rules

localvoxtral never writes into a herdr pane. Your words are typed into the
terminal in front. Before "send it" presses Enter, the app reads back that
herdr's focused pane is still the joined session and that the agent still
runs in the pane's foreground. If not, no Enter is pressed.

## What doesn't work

- **Two herdr servers running on one Mac.** The app can't tell which one you
  are looking at, so it joins neither.
- **Repository context from a remote pane.** A remote join gets the pane's
  screen, your last prompt, the names of files the agent recently touched and
  short tool excerpts. It reads nothing from the host's repository: no
  status, no diff, no file list.
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

- [Integration matrix](https://t0msilver.github.io/localvoxtral/docs/integration-matrix/): how each terminal
  and agent joins, herdr included.
- [Remote Claude Code over SSH](https://t0msilver.github.io/localvoxtral/docs/remote-claude-context/): host
  enrollment and the tunnel.
