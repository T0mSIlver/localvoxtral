# Work with several agents

Run several coding agents at once, and localvoxtral tells you when one waits
for you.

This works with the sessions localvoxtral joins: Claude Code
([Dictating into Claude Code](coding-agents.md#dictating-into-claude-code)),
Codex, opencode and Mistral Vibe
([Connect opencode, Mistral Vibe and Codex](coding-agents.md#connect-opencode-mistral-vibe-and-codex)).
To press Return by voice, see
[Press Return with "send it"](dictation.md#press-return-with-send-it).

## When an agent needs you

Turn on **Tell me when an agent needs you**, under **Settings → Dictation →
Output**.

A session waits when Claude Code, Codex or opencode shows a permission
prompt or asks a question on this Mac, and when Claude Code does on an
enrolled host. A session that
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

In a Claude Code session with the localvoxtral mod, the mod's band also lists
the other sessions that wait for you. Switch to one yourself: localvoxtral
does not bring a pane forward.
