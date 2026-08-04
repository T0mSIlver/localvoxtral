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
Live Auto-Paste; behavior follows the `Toggle` / `Push to Talk` setting.

**Escape** cancels an in-progress dictation.

## Output modes

- **Overlay Buffer** — your words collect in a floating overlay while you
  speak; on stop, the text runs through the replacement dictionary and
  optional LLM polishing, then commits into the focused app. The overlay
  shows a **Polished** badge whenever the LLM touched your text, and the raw
  transcript stays one click away in the menu bar popover.
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
  grant buttons), copy-final-segment toggle, and Re-run Setup
- **Endpoints** — Dictation and Polishing each switch independently between
  `Managed local` (a model picker for polishing, plus a status light) and
  `External URL` (endpoint URL, model name, API key)
- **Dictation** — the trigger (single modifier key with tap/hold gestures, or
  per-mode keyboard shortcuts) and the menu-bar output mode
- **Text Processing** — exact-match replacements, plus the LLM Polishing
  switch and its agent-dictation features (agent prompt profile, repo
  vocabulary, clipboard context, spoken clipboard paste, and Claude Code
  session context)
- **About** — version, link to the repository, and Export Diagnostics
  (writes a redacted local report to the Desktop)

The config folder at `~/Library/Application Support/localvoxtral/config`
holds `replacement_dictionary.toml`, the LLM prompt TOMLs (including the
agent variants), and `terminal_apps.toml`. When an update ships improved
defaults, files you haven't edited are refreshed automatically; files you
have edited are never touched without asking — the app offers to update them
and keeps your versions as `.backup` files alongside.

## Screenshots

<!-- Regenerate the screenshots below with the "Capture README Assets" workflow (Actions -> capture-assets.yml, run on the branch) or ./scripts/capture-readme-assets.sh on a Mac. Captures are pinned to dark mode for consistency. The demo video is recorded with ./scripts/record-demo.sh (operator speaks the prompted lines) or hands-free via the "Record README Demo" workflow (record-demo.yml, TTS through BlackHole on the self-hosted runner); GitHub only renders inline video from user-attachments URLs, so the resulting mp4 is drag-dropped into a PR comment by hand and the URL pasted into the README/docs by hand. -->

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
    <td width="50%" align="center"><b>Endpoints</b></td>
  </tr>
  <tr>
    <td width="50%"><img src="../assets/settings-general.png" alt="localvoxtral general settings" width="100%" /></td>
    <td width="50%"><img src="../assets/settings-endpoints.png" alt="localvoxtral endpoints settings" width="100%" /></td>
  </tr>
  <tr>
    <td width="50%" align="center"><b>Dictation</b></td>
    <td width="50%" align="center"><b>Text Processing</b></td>
  </tr>
  <tr>
    <td width="50%"><img src="../assets/settings-dictation.png" alt="localvoxtral dictation settings" width="100%" /></td>
    <td width="50%"><img src="../assets/settings-text-processing.png" alt="localvoxtral text processing settings" width="100%" /></td>
  </tr>
</table>
