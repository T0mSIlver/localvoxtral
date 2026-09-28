# Work with several agents

Run several coding agents at once, and localvoxtral tells you when one waits
for you. Tab to it while you dictate, and that agent's pane comes to the
front so you can read what it asked while you answer. Your words go into
that pane when you stop. By voice, you can name a session, go to it, send
it a dictation from another app, and press Return.

This works with the sessions localvoxtral joins: Claude Code
([Dictating into Claude Code](coding-agents.md#dictating-into-claude-code)),
Codex, opencode and Mistral Vibe
([Connect opencode, Mistral Vibe and Codex](coding-agents.md#connect-opencode-mistral-vibe-and-codex)).
The needs-you cue and Tab need **Tell me when an agent needs you**, under
**Settings → Dictation → Output**.

## When an agent needs you

A session waits when Claude Code, Codex or opencode shows a permission
prompt or asks a question, on this Mac or an enrolled host. A session that
finishes its turn while you look at another window or pane counts too, and
Mistral Vibe sessions count only then, since Vibe reports no waits. A turn
that ends in the pane you are looking at counts for nothing.

Each time, the app shows a macOS banner with a sound, and the menu bar icon
gets an orange dot. **Menu bar mark when an agent needs you** can make it a
square or an exclamation mark instead. The popover names the session:
"payments needs you" or "payments finished". The sound is your alert sound,
and macOS controls it: turn off **Play sound for notifications** under
**System Settings → Notifications → localvoxtral** to keep the banner
without it. Focus silences both.

A session stops waiting when you send it a prompt, when it starts working
again, when it ends, or when you dictate into it. The app never receives
what the agent wrote or asked, only that it waits.

## Jump to it

During a dictation, the overlay lists each waiting session among
[where the words go](dictation.md#where-the-words-go), oldest first, after
the Inbox. The second Tab reaches the oldest one, and its pane comes
forward. The overlay moves to it only once the
terminal confirms the pane is in front. Otherwise it stays where it was and
the popover says why.

The optional **Answer the agent that needs you** shortcut, under **Settings
→ Dictation → Output**, does the same in one press. It brings forward the
session that has waited longest, or else the one that finished first, and
starts a dictation there. Press it again to stop; the next press goes to the
next session. During a dictation it picks that session the way Tab would. It
can be a [chord of modifier keys](dictation.md#record-a-chord-of-modifier-keys).
With no session waiting, it opens the oldest ready quick capture draft
instead ([Review a draft by voice](coding-agents.md#review-a-draft-by-voice)).

After a move to a session, moving back to the app you started in brings it
forward, except in one case: you started in the same terminal app as that session, in
a pane with no joined session. The app has no way to find that pane again,
and bringing the terminal forward would only show the session's pane.

### Which sessions come forward

- Ghostty, iTerm2 and Terminal.app on this Mac.
- Claude Desktop Code-tab sessions, on this Mac or on an ssh host Desktop
  runs them on. Desktop switches to the session, and the words go there once
  its prompt has focus.

herdr and cmux panes can't come forward yet
([#1012](https://github.com/T0mSIlver/localvoxtral/issues/1012)). For those,
and any other session, the popover says it can't bring that session forward.
["Go to"](#go-to-a-session-by-voice) reaches the same sessions.

## Name a session

The overlay, the popover and the banners show a session by the name you gave
it, else its Claude Desktop title, else its folder. The folder is the
repository's, or in a linked worktree the worktree's, without the random
ending of a worktree Claude created (`zealous-chaplygin-aa1a02` shows as
"zealous-chaplygin"). A worktree on a branch you named shows the branch
instead (`fix/overlay-names` shows as "overlay-names").

When sessions would show the same name, each gets its agent
("localvoxtral · Codex") or a number ("localvoxtral · 2") added.

A session answers to, in this order:

1. the name you gave it;
2. the name it shows, suffix included ("go to localvoxtral two");
3. its folder or branch, with or without the random ending;
4. its repository's name;
5. its Claude Desktop title, whole or its first two to four words
   ("go to better session names").

A name that several sessions share matches none of them.

To give a session a name of your own, say "call this session payments" (or
"name this session payments") while dictating into it. Nothing is typed.
From then on it shows as payments, and "go to payments" reaches it ahead of
any other name. Naming another session payments moves the name to it.

## Go to a session by voice

Say only "go to payments" and the app brings the pane of the joined session
named payments to the front instead of typing anything. In Live Auto-Paste,
say it as a phrase between pauses, and what you say next is typed into that
session.

When no session has that name, the app types the dictation as usual. When
more than one does, or its pane can't be reached, nothing is typed and the
menu bar popover says so.

## Send a dictation to another session

In Overlay Buffer, end a dictation with "send that to payments". The session
named payments gets the text and presses Enter, and the app you are in gets
nothing.

The name has one to four words, and sessions answer to it the way they do
for "go to". What happens next depends on the session:

- **A Ghostty, iTerm2 or Terminal.app tab** comes forward and gets the text.
  Enter is pressed only if that pane is still the one in front.
- **An opencode session, or a session in a
  [herdr](../integrations/herdr/README.md) pane on this Mac,** gets the text
  without coming forward.
- **A remote, Claude Desktop or cmux session** gets nothing, and the popover
  says "Can't send to that session yet".

When no session has that name, the app inserts the whole dictation where you
are, as spoken. When more than one does, nothing is sent and the text stays
in History.

When a delivery fails, nothing reaches the app you are in. The text stays in
History, and the popover says whether it was typed without Enter.

## Press Return by voice

In a terminal or Claude Desktop, end a dictation with "send it" or "send
now". The app inserts the text without those words, then presses Return, so
the agent gets the prompt without you touching the keyboard. In Overlay
Buffer, the dictation also stops on its own three seconds after the phrase.

The option is off by default. **Settings → Dictation → Output → Phrases that
press Return** replaces the phrases with your own. The rest is in
[Press Return with "send it"](dictation.md#press-return-with-send-it).
