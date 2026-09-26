# Dictating: shortcuts, output modes, and settings

## Shortcuts

You pick one of two triggers in **Settings → Dictation**.

**Single modifier key.** Fn/Globe, Right Command, or Right Option. The one key
has two gestures:

| Gesture | Behavior |
|---|---|
| Tap | Toggle Overlay Buffer dictation on/off |
| Hold (past the hold delay, default 350 ms) | Live Auto-Paste push-to-talk: dictates while held, stops on release |

The gesture picks the output mode. A tap commits through optional LLM
polishing, and a hold streams words as you speak. The replacement dictionary
applies to both. Pressing any other key while the modifier is down cancels
the gesture, so your usual shortcuts with that modifier still work. This
trigger needs Accessibility permission.

**Per-mode keyboard shortcuts.** Overlay Buffer and Live Auto-Paste each get
their own shortcut, and the `Toggle` / `Push to Talk` setting decides how it
behaves. A shortcut needs at least one modifier, except for a function key.
F1 to F20 can be recorded on their own, so a spare F13 to F20 on a full-size
keyboard makes a dedicated dictation key. F1 to F12 are accepted too, but
macOS uses those presses for brightness and media unless **Use F1, F2, etc.
keys as standard function keys** is on in System Settings. Until then, the app
never sees them.

**Escape** cancels an in-progress dictation.

## Output modes

- **Overlay Buffer.** Your words collect in a floating overlay while you
  speak. When you stop, the text goes through the replacement dictionary and
  optional LLM polishing, then commits into the focused app. The overlay
  shows a **Polished** badge when the LLM changed your text, and the menu bar
  popover keeps the raw transcript. You can drag the overlay by any part of
  it to a spot of your choice, and it stays there across restarts. A
  double-click on it, or **Re-anchor** in Settings → Dictation → Overlay
  Buffer, anchors it to the focused window again. If you unplug the display
  it sits on, the app keeps the position but shows the overlay at the anchor
  until that display is back.
- **Live Auto-Paste.** Words land in the focused app while you talk. The app
  applies dictionary replacements before typing, and never backspaces over
  text an app has already drawn.

**Say "send it" to press Return.** In a terminal or Claude Desktop, end a
dictation with "send it" or "send now" and the app inserts the text without
those words, then presses Return in the same app. A coding agent gets the
prompt without you touching the keyboard. The option is off by default and
set per mode in Settings → Dictation.

- In Overlay Buffer, the app removes the words before polishing, so the
  polisher never sees them.
- In Live Auto-Paste, the app can only remove the trigger before typing it.
  With the option on, each phrase therefore appears when you finish it rather
  than word by word, and saying the same "… send it" phrase twice in a row
  sends it once. Once any text of a dictation lands in another app, "send
  it" does nothing until the dictation ends.

Neither mode presses Return in any other app, while Secure Keyboard Entry is
on, or when the text could not be inserted into that app. The app treats an
app as a terminal only if it is a known terminal or listed in Settings →
Terminals. Claude Desktop is recognized on its own; listing it there would
make localvoxtral treat its prompt box as a terminal.

**Say "go to" and a session's name to switch to it.** In Overlay Buffer, a
dictation that is only "go to payments" brings the pane of the joined coding
agent session named payments to the front instead of typing anything. A
session answers to its repository's name and, in a linked worktree, to the
worktree's name. It works for sessions in Ghostty, iTerm2 and Terminal.app on
this Mac. When no session has that name, the dictation is typed as usual;
when more than one does, or its pane can't be reached, nothing is typed and
the menu bar popover says so.

### Keeping words on their line

Words reach the overlay a few letters at a time, so a word that starts near
the end of a line can jump to the next one once it no longer fits. By default
the overlay allows this and fills every line to the edge.

**Keep words from jumping to the next line** (Settings → Dictation → Overlay
Buffer) prevents it for words up to 6, 10 or 14 letters. A word that starts
with less room than that goes straight to the next line and stays there for
the rest of the dictation. Lines can then end with empty space up to the
width of that many letters. The committed text is the same either way.

## The menu bar popover

localvoxtral lives in the menu bar. Its popover shows the dictation status, a
**microphone picker**, an auto-copy toggle for the final text, and, after a
polished commit, the raw transcript. You can edit the LLM polishing prompts
(see the config folder below).

**Copy last dictation** puts the last dictation on the clipboard: its polished
text, or the transcript when polishing failed. Use it to recover a dictation
that never reached the app because:

- the insertion failed,
- the connection dropped and could not come back (the app keeps the text
  transcribed up to then), or
- a new dictation started while the last one was still polishing.

It works with history off, until the app quits. You can record a global
shortcut for it under **Settings → Dictation → Output**.

## When a coding agent needs you

Record a shortcut for **Answer the agent that needs you** under **Settings →
Dictation → Output** to turn this on. localvoxtral then tells you when one of
the coding agent sessions it joins waits for you: a permission prompt or a
question, from Claude Code, Codex or opencode, on this Mac or an enrolled host.
It also tells you when a session finishes its turn while you are looking at
another window or pane. A Mistral Vibe session tells you only when it finishes,
since Vibe reports no waits.

Each time, the app plays a sound and shows a macOS banner, the menu bar icon
gets an orange dot, and the popover names the session: "payments needs you"
or "payments finished". Nothing fires for a turn that ends in the pane you are
looking at.

The shortcut brings forward the pane of the session that has waited longest,
or else the one that finished first, and starts a dictation there, so you can
answer by voice. Press it again to stop the dictation; the next press goes to
the next session. Like "go to", it reaches sessions in Ghostty, iTerm2 and
Terminal.app on this Mac. For any other session, the popover says it can't
bring that session forward.

A session leaves the list when you send it a prompt, when it starts working
again, when it ends, or when you dictate into it. The app never receives what
the agent wrote or asked, only that it waits.

## History

The app saves every dictation on this Mac, in plain text, in
`~/Library/Application Support/default.store`. Nothing in it leaves the
machine, except that the term suggestion pass sends recent dictations to your
hosted polishing model when you have one.

**History** in the menu bar popover opens the localvoxtral window on the
list, newest first:

- Search covers the transcript and the polished text. The filter keeps the
  dictations that were **Not inserted** (the text never reached the app, so
  this list is the only copy) or whose polishing failed.
- Click a row for the whole text. When polishing or a replacement changed it,
  the transcript appears under it with the removed words marked, and
  **Copy Transcript** copies the unchanged version.
- **Delete** removes the dictation from the store. **Delete All…** removes
  every one.

**Keep dictations** sets how long they stay: forever (the default), 90, 30 or
7 days, or **Don't keep**, which deletes what is saved and saves nothing new.
Before a shorter setting deletes anything, it says how many dictations will go
and asks. Term suggestions read this history, so they stop under Don't keep.

**Keep dictation audio on this Mac**, off by default, also saves what the
microphone heard for each dictation, as a WAV file in
`~/Library/Application Support/localvoxtral/dictation-audio`. The app never
sends the audio anywhere, the term suggestion pass included. The recordings
let you replay your own dictations and measure whether localvoxtral got
better at them; the replay tool copies the files only where you run it.

Each file goes when its dictation goes. Delete, Delete All, and the Keep
dictations period remove the audio with the text, and Don't keep turns the
audio off with the history. Turning the option off asks first, then deletes
every recording and keeps the dictations. A minute of audio takes about 2 MB,
and a dictation longer than 20 minutes is saved without audio.

### Insights

**Insights**, under History in the sidebar, counts the saved dictations over
the last 7 days, the last 30, or all of them:

- **Activity**: dictations, words, time dictating, pace, and the time saved
  against typing the same words at 40 words per minute. Time dictating runs
  from the shortcut to the inserted text, with the polishing wait taken out.
- **Reliability**: dictations that were never inserted and polishes that
  failed. **Show** opens History filtered to them.
- **Polishing**: how often it changed the text, the typical wait (the
  median), and the wait one polish in ten exceeds.
- **Learning, last 12 weeks**: one bar per week, whatever the period, so you
  can see whether localvoxtral is learning how you speak. **Your terms
  recognized correctly** takes your Names and terms and the learned terms
  that ended up in a dictation, and counts how many the transcript already
  spelled exactly, before polishing or a replacement fixed them. **Polished
  dictations needing no fix** is the share of polished dictations whose text
  went in exactly as the recognizer wrote it. A week with fewer than five
  dictations to count draws no bar. Read both as a trend, not a measurement.
  The history only holds the terms that reached the inserted text, so a term
  that both the recognizer and polishing got wrong is counted nowhere.
- **What polishing keeps fixing**: replacements of up to four words that
  polishing made in three dictations or more, such as `quen → Qwen`. These are
  the words the recognizer gets wrong for you. Every polish receives the
  spellings you add to Names and terms, and the app fixes their casing and
  spacing without the model.
- **Apps**: where Overlay Buffer dictations went. Live Auto-Paste records no
  target app.

The app computes all of this on this Mac from the history store. With history
off, the pane is empty.

## Settings

Open **Settings…** from the menu bar popover. Settings shares a window with
History; the panes sit under the sidebar's Settings header.

- **General**: permission status for Microphone and Accessibility (with grant
  buttons), Re-run setup, and two startup switches. **Open localvoxtral at
  login** starts the app when you log in, and **Open the window at launch**
  opens the window on History every time the app starts. Both are off, and a
  first launch shows the setup wizard instead of the window.
- **Engines**: Dictation and Polishing each switch on their own between
  `Managed local` (a model picker and a status light for each),
  `External URL` (server URL, model name, API key), and `Mistral API`
  (Mistral's hosted models on one API key, entered in the pane's Mistral API
  group). Dictation accepts an OpenAI Realtime-compatible endpoint. For
  polishing, enter either a base URL such as `http://127.0.0.1:8080` or the
  full chat completions URL; the app appends `/v1/chat/completions` to a base
  URL. Memory limit caps the dictation helper's buffer cache (2 GB by
  default). Nemotron never fills it, so the row appears only for Voxtral.
- **Dictation**: the trigger (single modifier key with tap/hold gestures, or
  per-mode keyboard shortcuts), the menu-bar mode, copy on stop, the **Copy
  last dictation** shortcut, ducking other audio, the spoken "send it"
  trigger for each mode, and the overlay's font size, how many lines it shows
  before scrolling, and whether it
  [keeps words on their line](#keeping-words-on-their-line).

  **Lower other audio while dictating**, on unless you turn it off, drops
  music and calls to a fifth of your volume while a session runs, in both
  output modes, and fades back when it ends. **Fade** sets how long each fade
  takes. The app changes the volume of the device you were listening to when
  the session started, and restores that device even if you switched outputs
  in the meantime. It leaves alone an output whose volume the Mac does not
  own (HDMI monitors, most digital outputs), and one that offers only
  per-channel volume, since ducking those channels together would flatten a
  stereo balance you set.
- **Text Processing**: **About you** holds a few lines on your work in your
  own words, plus a list of the names and terms you say often, spelled the
  way they should appear ("Qwen", "Claude Code", "vLLM"). The app sends both
  to the polishing model with every dictation, whichever endpoint you chose.
  You never list how a name gets misheard; the polisher works that out. The
  app fixes the casing of a multi-word or mixed-case term even in Live
  Auto-Paste with no polishing.

  **Suggest terms** sends your recent dictations to the polishing model you
  chose and shows the names it finds as dashed tags. + adds one, and ×
  refuses it for good (**Advanced → Dismissed suggestions → Forget** undoes
  that). One run reads up to 120 dictations at high reasoning effort, so it
  uses API credits and can take a few minutes. It keeps running in the
  background while you dictate. It needs a hosted polishing model (Mistral
  API or your own server); the bundled local model cannot do it. With a
  hosted model, the same run also starts by itself every 50 saved
  dictations, spending API credits without a click. **Suggest by itself**
  sets the pace (25, 50, 100 or 200) or **Never**. A number on the Text
  Processing sidebar row means tags are waiting; nothing is added until you
  press +.

  The app also learns terms by itself. When polishing fixes a mangled name
  using your repo, your screen or your agent's session, the app remembers
  the spelling for that project. After three dictations it starts correcting
  the name on its own, including in dictations where nothing on screen
  mentions it. These terms also show as tags in **Suggestions**, with no API
  credits. A project is a repository: all its git worktrees share one list,
  on this Mac and on a remote host whose plugin is 1.13.0 or later.

  **Advanced → Terms learned from polishing → Show** lists them by project,
  with how often each was applied and when it last was. Pin a term to keep
  it: the app uses it at once and it never expires. Forget one, or all of
  them with **Forget**. **Export…** and **Import…** at the bottom of that
  list move the terms to another Mac as a JSON file. An import adds to what
  is there, and a term still being learned stays that way until you have
  said it in three dictations. When you say a learned name as ordinary words
  in a sentence ("we should use auth tokens" with `useAuth` learned), the app
  does not rewrite it; polishing decides from the sentence. Next to a code
  word ("call use auth", "the session start hook"), it does.

  The app also learns from your own fixes. When a dictation joined a
  coding-agent session and you fix a misheard name before sending the prompt
  (`kwen` to `Qwen`), the app compares the prompt you sent with what it typed
  and remembers the new spelling for that project at once. "Learned “Qwen”"
  shows at the top of the screen for a few seconds, with an **Undo** button.
  The app learns only a small fix, to a word that sounds like the one it
  replaced and looks like a name or identifier; rewording teaches nothing.
  Changing a learned spelling back forgets it. The app compares your prompt
  in memory and never saves it.

  The pane also has the LLM Polishing switch, the agent prompt profile and
  spoken clipboard paste. **Advanced** holds the legacy replacement
  dictionary and the prompt files. The dictionary applies fixed
  `replace_with`/`matches` rewrites from `replacement_dictionary.toml`, which
  helps in Live Auto-Paste without polishing. The polisher no longer sees
  it, and its spellings were imported into your terms once.
- **Context**: what the polisher may see (repo vocabulary, clipboard, the
  agent's screen and session). Each toggle's title names what leaves this
  Mac, and the full terms are in
  [Terminals & coding agents](coding-agents.md#polish-context-what-each-toggle-sends).
- **Integrations**: one pane per harness, each with a status dot. Green
  means detected and set up, yellow means a setup step is pending, grey
  means not installed. **Claude Code** and **opencode** install their
  plugins, **Mistral Vibe** installs its hooks, **Codex** installs its plugin
  and turns green once Codex has run the hooks, **herdr** shows detection and
  herdr's saved machines, and **Remote hosts** enrolls SSH hosts for remote
  sessions.
- **Terminals**: one pane per terminal app (plus any you add), showing
  whether it is installed and what it supports. Dictation works in all of
  them. Session join and screen context work only on Ghostty (1.4+ or a tip
  build), iTerm2, Terminal.app, and cmux. iTerm2 and Terminal.app ask for the
  Automation (AppleScript) permission on the first session join. **Add app…**
  picks any application to treat as a terminal for dictation; added apps are
  removed from their own pane. cmux's pane also holds its session join and
  socket password.
- **About**: version, link to the repository, and Export Diagnostics (writes
  a redacted local report to the Desktop).

### Terms from your coding agent

**Text Processing → Advanced → Ask the coding agent for each new project's
terms** is off by default. When it is on, the first dictation that joins a
local Claude Code, Mistral Vibe or opencode session in a project the app has
not asked about starts that agent once, headless, in the project's repository. The
agent reads a few files and answers with up to 40 of the project's own names:
modules, types, commands, environment variables. Your session never sees the
request, so it cannot interrupt a turn. Every worktree of a repository counts
as one project, and the app asks each project once, whichever agent joins
first. It retries a failed run a day later.

The names show in **Terms learned from polishing → Show** as "Proposed by
Claude Code", "Proposed by Mistral Vibe" or "Proposed by opencode". They are
suggestions. Polishing
applies one only where you allow repo vocabulary and only where the
transcript spells it out, and it never reaches the polishing prompt's list of
your terms. Three dictations that use it, or **Pin**, make it yours;
**Forget** removes it. An unused one expires after 90 days.

What a run costs and sends:

- **Claude Code**: `claude -p` with Sonnet, read-only tools (Read, Glob, Grep),
  hooks and MCP servers off, at most 12 turns and $0.50. Measured runs cost
  $0.03–0.12 and took 5–15 s. On a Claude.ai plan it spends quota instead.
- **Mistral Vibe**: `vibe -p` on Vibe's unified harness with read-only file
  tools, at most 12 turns and $0.30. It runs under a Vibe home the app owns
  (`~/Library/Application Support/localvoxtral/vibe-home`, two links to your
  `~/.vibe/config.toml` and `.env`), so none of your Vibe hooks fire and the
  run stays out of your Vibe history. Its prompt lists up to 200 tracked file
  names. Measured runs used about 115k input tokens, $0.05–0.10 at Vibe's
  default model prices, in 10–25 s.
- **opencode**: `opencode run --pure` with your default model, read, glob,
  grep and list only, at most 12 steps and 4,096 output tokens a step.
  opencode has no price cap, so a run is also cut off after 2 minutes.
  `--pure` keeps every plugin out, ours included. The run ignores the
  repository's `opencode.json` (no MCP server starts) and keeps its session
  in memory, so it stays out of your opencode history. A provider that only an
  environment variable configures is not seen, because the app does not have
  your shell's environment; `opencode auth login` stores a key it can use.
  Measured runs with Mistral Medium used 5 steps, 5–9k input and 200–350
  output tokens (under $0.02), in 5–14 s.

Either way, the agent sends the files it reads to its provider, as it does in
your own sessions.

A session on an enrolled ssh host is asked too, once its host runs
`localvoxtral-remote` 1.15.0 or the Vibe hooks 1.2.0 (**Update Host…**). The
run happens on that host, in the session's repository, with the same limits,
and bills the host's own Claude Code login or Mistral key. The Mac only asks,
on the session's next hook, and files the answer under the session's project.
Details: [Terms from the coding agent on a host](remote-claude-context.md#terms-from-the-coding-agent-on-a-host).

The config folder at `~/Library/Application Support/localvoxtral/config`
holds `replacement_dictionary.toml` for both output modes and the standard
and agent `llm_system_prompt*.toml` and `llm_user_prompt*.toml` files.
Remove `{{replacement_dictionary}}` from a user prompt template to stop
sending the dictionary to the LLM.

You manage extra terminal apps in Settings → Terminals, not in a config file.
If you had a legacy `terminal_apps.toml`, the app reads it once at launch and
moves its entries into the Settings list, leaving the file untouched.

When an update ships better defaults, the app refreshes the files you haven't
edited. It never changes a file you edited without asking: it offers to
update it and keeps your version alongside as a `.backup` file.

## Screenshots

<!-- Regenerate the screenshots below with the "Capture README Assets" workflow (Actions -> capture-assets.yml, run on the branch) or ./scripts/capture-readme-assets.sh on a Mac. Captures are pinned to dark mode for consistency. The demo video is recorded with ./scripts/record-demo.sh (operator speaks the prompted lines) or hands-free via the "Record README Demo" workflow (record-demo.yml, TTS through BlackHole on the self-hosted runner); GitHub only renders inline video from user-attachments URLs, so the resulting mp4 is drag-dropped into a PR comment by hand and the URL pasted into the README/docs by hand. Only screenshots that exist in assets/ are listed here: the remaining Integrations panes (Context, opencode, herdr) and the per-terminal panes are captured by the same workflow and join this table as their PNGs land. -->

<p>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../assets/icons/menubar/MicIconTemplate@2x_dark-preview.png" />
    <img src="../assets/icons/menubar/MicIconTemplate@2x.png" alt="localvoxtral menubar icon" width="28" height="28" />
  </picture>
  Menubar icon
</p>

<table>
  <tr>
    <td width="50%" align="center"><b>General</b></td>
    <td width="50%" align="center"><b>Engines</b></td>
  </tr>
  <tr>
    <td width="50%"><img src="../assets/settings-general.png" alt="localvoxtral general settings" width="100%" /></td>
    <td width="50%"><img src="../assets/settings-endpoints.png" alt="localvoxtral engine settings" width="100%" /></td>
  </tr>
  <tr>
    <td width="50%" align="center"><b>Dictation</b></td>
    <td width="50%" align="center"><b>Text Processing</b></td>
  </tr>
  <tr>
    <td width="50%"><img src="../assets/settings-dictation.png" alt="localvoxtral dictation settings" width="100%" /></td>
    <td width="50%"><img src="../assets/settings-text-processing.png" alt="localvoxtral text processing settings" width="100%" /></td>
  </tr>
  <tr>
    <td width="50%" align="center"><b>Integrations: Claude Code</b></td>
    <td width="50%"></td>
  </tr>
  <tr>
    <td width="50%"><img src="../assets/settings-integrations-claude-code.png" alt="localvoxtral Claude Code settings" width="100%" /></td>
    <td width="50%"></td>
  </tr>
</table>
