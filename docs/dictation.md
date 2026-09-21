# Dictating: shortcuts, output modes, and settings

## Shortcuts

Two ways to trigger dictation, configured in **Settings → Dictation**:

**Single modifier key** — Fn/Globe, Right Command, or Right Option. One key,
two gestures:

| Gesture | Behavior |
|---|---|
| Tap | Toggle Overlay Buffer dictation on/off |
| Hold (past the hold delay, default 350 ms) | Live Auto-Paste push-to-talk — dictates while held, stops on release |

The gesture selects the output mode, so both workflows are always one key
away. A tap commits through optional LLM polishing, while a hold streams
words in real time (the replacement dictionary applies in both). Pressing any
other key while the modifier is down cancels the gesture, so regular keyboard
combos involving the modifier are unaffected. Requires Accessibility
permission.

**Per-mode keyboard shortcuts** — separate shortcuts for Overlay Buffer and
Live Auto-Paste; behavior follows the `Toggle` / `Push to Talk` setting. A
shortcut needs at least one modifier, except for a function key: F1 to F20 can
be recorded on their own, so a spare F13 to F20 on a full-size keyboard works
as a dedicated dictation key. F1 to F12 are accepted too, but macOS claims
those presses for brightness and media unless **Use F1, F2, etc. keys as
standard function keys** is on in System Settings — until it is, the app never
sees them.

**Escape** cancels an in-progress dictation.

## Output modes

- **Overlay Buffer** — your words collect in a floating overlay while you
  speak; on stop, the text runs through the replacement dictionary and
  optional LLM polishing, then commits into the focused app. The overlay
  shows a **Polished** badge whenever the LLM touched your text, and the raw
  transcript stays one click away in the menu bar popover. Drag the
  overlay anywhere on it to put it where the anchored position never gets
  right; it stays there across restarts, and a double-click on it (or
  **Re-anchor** in Settings → Dictation → Overlay Buffer) hands it back to the
  focused window. A position on a display you later unplug is kept
  but not used — the overlay returns to the anchor until that display is back.
- **Live Auto-Paste** — words land in the focused app while you're still
  talking. Dictionary replacements are applied before text is typed;
  localvoxtral never backspaces over what an app has already drawn.

## The menu bar popover

localvoxtral lives in the menu bar: the popover shows dictation status at a
glance, a **microphone picker**, an auto-copy toggle for the final text, and
— after a polished commit — the raw transcript one click away. LLM polishing
prompts are editable (see the config folder below).

## Settings

Open **Settings** from the menu bar popover:

- **General** — permission status for Microphone and Accessibility (with
  grant buttons), and Re-run setup
- **Engines** — Dictation and Polishing each switch independently between
  `Managed local` (a model picker for polishing, plus a status light),
  `External URL` (server URL, model name, API key), and `Mistral API`
  (Mistral's hosted models on one API key, entered in the pane's Mistral API
  group). Dictation accepts an OpenAI Realtime-compatible endpoint. For
  polishing, enter either a base URL such as `http://127.0.0.1:8080` or the
  full chat completions URL; the app appends `/v1/chat/completions` to a base
  URL. Lower dictation step intervals show words sooner, while higher values
  use less compute.
- **Dictation** — the trigger (single modifier key with tap/hold gestures, or
  per-mode keyboard shortcuts), the menu-bar mode, copy on stop, ducking other
  audio, and the overlay's font size and how many lines it shows before
  scrolling. **Duck other audio** drops music and calls to a fifth of your
  volume for as long as a session runs, in both output modes, and fades back
  when it ends; **Fade** sets how long each fade takes. It moves the system
  volume of your current output device, so an output whose volume the Mac does
  not own — HDMI monitors, most digital outputs — is left alone.
- **Text Processing** — **About you**: a few lines on your work in your own
  words, plus a list of the names and terms you say often, spelled the way
  they should appear ("Qwen", "Claude Code", "vLLM"). Both are sent to the
  polishing model with every dictation, whichever endpoint you chose. You
  never list how a name gets misheard; the polisher works that out, and the
  casing of a multi-word or mixed-case term is fixed even in Live Auto-Paste
  with no polishing.
  **Suggest terms** sends your recent dictations to the polishing model you
  chose and shows the names it finds as dashed tags: + adds one, × refuses it
  for good (**Advanced → Dismissed suggestions → Forget** undoes that). One
  run reads up to 120 dictations at high reasoning effort, so it uses API
  credits and can take a few minutes; it keeps running in the background
  while you dictate. It needs a hosted polishing model (Mistral API or your
  own server); the bundled local model cannot do it.
  The app also learns terms by itself: when polishing fixes a mangled name
  against your repo, your screen or your agent's session, it remembers the
  spelling for that project, and after three dictations it starts correcting
  the name on its own — including in dictations where nothing on screen
  mentions it. Those terms are offered as tags in **Suggestions** too, with
  no API credits. **Advanced → Learned terms** counts them and forgets them.
  Then the LLM Polishing switch, the agent prompt profile and spoken
  clipboard paste. **Advanced** holds the legacy replacement dictionary
  (fixed `replace_with`/`matches` rewrites from `replacement_dictionary.toml`,
  useful for Live Auto-Paste without polishing; the polisher no longer sees
  it, and its spellings were imported into your terms once) and the prompt
  files
- **Context** — what the polisher may see (repo vocabulary, clipboard, the
  agent's screen and session); each toggle's help is one line naming what
  leaves this Mac, and the full terms are in
  [Terminals & coding agents](coding-agents.md#polish-context-what-each-toggle-sends)
- **Integrations** — one pane per harness, each with a status dot: green
  means detected and set up, yellow means a setup step is pending, grey
  means not installed. **Claude Code** and **opencode** install their
  plugins; **herdr** shows detection and herdr's saved machines;
  **Remote hosts** enrolls SSH hosts for remote sessions
- **Terminals** — one pane per terminal app (plus any you add), showing
  whether it is installed and what it supports: dictation everywhere, session
  join and screen context only on Ghostty (1.4+ or a tip build), iTerm2, Terminal.app, and
  cmux. iTerm2 and Terminal.app ask for the Automation (AppleScript)
  permission on the first session join. **Add app…** picks any application
  to treat as a terminal for dictation; added apps are removed from their
  own pane. cmux's pane also holds its session join and socket password
- **About** — version, link to the repository, and Export Diagnostics
  (writes a redacted local report to the Desktop)

The config folder at `~/Library/Application Support/localvoxtral/config`
holds `replacement_dictionary.toml` for both output modes and the standard
and agent `llm_system_prompt*.toml` and `llm_user_prompt*.toml` files.
Remove `{{replacement_dictionary}}` from a user prompt template to stop
sending the dictionary to the LLM. Extra terminal apps are managed in
Settings → Terminals rather than a config file: the legacy
`terminal_apps.toml`, if you had one, is read once at launch and its
entries move into the Settings list; the file is left untouched. When an
update ships improved defaults, files you haven't edited are refreshed
automatically; files you have edited are never touched without asking —
the app offers to update them and keeps your versions as `.backup` files
alongside.

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
