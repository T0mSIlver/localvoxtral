<h1 align="center">localvoxtral</h1>

<p align="center">
  <img src="assets/icons/app/AppIcon.png" alt="localvoxtral app icon" width="128" height="128" />
</p>

<p align="center">
  <strong>Realtime, fully local dictation for the Mac menu bar.</strong><br />
  Press a key and speak — your words appear while you're still talking.
</p>

<p align="center">
  <a href="https://github.com/T0mSIlver/localvoxtral/releases/latest"><img src="https://img.shields.io/github/v/release/T0mSIlver/localvoxtral?label=release" alt="Latest release" /></a>
  <a href="https://github.com/T0mSIlver/localvoxtral/actions/workflows/ci.yml"><img src="https://github.com/T0mSIlver/localvoxtral/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <img src="https://img.shields.io/badge/macOS%2015%2B-Apple%20Silicon-black?logo=apple" alt="macOS 15+ on Apple Silicon" />
  <a href="LICENSE"><img src="https://img.shields.io/github/license/T0mSIlver/localvoxtral" alt="License" /></a>
</p>

<p align="center">
  <img src="assets/demo.gif" alt="localvoxtral demo" width="760" />
</p>

Unlike tools that transcribe after you stop speaking, localvoxtral streams text as the audio arrives, powered by Mistral AI's [Voxtral Mini 4B Realtime](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602) running on your own Apple Silicon. By default everything happens on-device — the speech model and the optional LLM that polishes your transcript before it lands. No account, no subscription, no audio or text ever leaving your Mac.

## Features

- **Fully local by default** — dictation and polishing run on-device: no audio or text leaves the Mac, no API costs
- **One-key dictation** — a single modifier key (Fn/Globe, Right Command, or Right Option): tap to dictate into a review overlay, hold to type live — or classic per-mode keyboard shortcuts with `Toggle` / `Push to Talk` behavior
- **Two output modes** — Overlay Buffer (review, then commit on stop) or Live Auto-Paste (words land in the focused app while you speak)
- **Automatic cleanup** — optional LLM polishing with editable prompts, plus an exact-match replacement dictionary
- **Guided first launch** — a setup wizard grants permissions and downloads the local engine with live progress; re-run it any time from Settings
- **Bring your own server** — dictation and polishing can each point at any OpenAI-compatible endpoint instead of the built-in local engines
- **Menu bar native** — instant popover with dictation status at a glance, microphone picker, auto-copy of the final text

## Privacy

In the default Managed local mode, nothing you say or write is sent anywhere: audio capture, transcription, and LLM polishing all run as local processes on your Mac. The only network traffic is the one-time engine and model download. No telemetry, no account, no cloud fallback — and if you point localvoxtral at your own External URL server instead, your data goes only where you send it.

## Quick start

**Requirements:** an Apple Silicon Mac running macOS 15 or later.

### Recommended: one-command installer

```bash
curl -fsSL https://raw.githubusercontent.com/T0mSIlver/localvoxtral/main/scripts/install.sh | bash
```

### Manual install from GitHub Releases (DMG)

Download the latest `.dmg` from [Releases](https://github.com/T0mSIlver/localvoxtral/releases/latest).

Releases are ad-hoc signed (not notarized). On macOS 26, launching the raw downloaded app can hang on first launch unless you use the installer script above. On older macOS versions, first launch may instead be blocked with an **Open Anyway** button in **System Settings → Privacy & Security**, or reported as "damaged". This clears the quarantine flag:

```bash
xattr -cr /Applications/localvoxtral.app
```

### Alternatively, build from source as an app bundle

```bash
./scripts/package_app.sh release
open ./dist/localvoxtral.app
```

## Shortcuts

Two ways to trigger dictation, configured in **Settings → Dictation**:

**Single modifier key** — Fn/Globe, Right Command, or Right Option. One key, two gestures:

| Gesture | Behavior |
|---|---|
| Tap | Toggle Overlay Buffer dictation on/off |
| Hold (past the hold delay, default 350 ms) | Live Auto-Paste push-to-talk — dictates while held, stops on release |

The gesture selects the output mode, so both workflows are always one key away. Pressing any other key while the modifier is down cancels the gesture, so regular keyboard combos involving the modifier are unaffected. Requires Accessibility permission.

**Per-mode keyboard shortcuts** — separate shortcuts for Overlay Buffer and Live Auto-Paste; behavior follows the `Toggle` / `Push to Talk` setting.

**Escape** cancels an in-progress dictation.

## Settings

A first-launch setup wizard (Welcome → Permissions → Downloads → Finish) grants microphone/Accessibility permissions and downloads the managed local engine, showing download progress for the models. It appears once on a fresh install; re-run it any time from **Settings → General → Re-run Setup…**.

Open **Settings** from the menu bar popover:

- **General** — permission status for Microphone and Accessibility (with grant buttons), copy-final-segment toggle, and Re-run Setup
- **Endpoints** — Dictation and Polishing sections; each switches independently between `Managed local` (status row with inline install/download progress) and `External URL` (endpoint URL, model name, API key)
- **Dictation** — the trigger (single modifier key with tap/hold gestures, or per-mode keyboard shortcuts with `Toggle` / `Push to Talk`) and the menu-bar output mode
- **Text Processing** — exact-match replacements toggle and the shared config folder (`replacement_dictionary.toml`, `llm_system_prompt.toml`, `llm_user_prompt.toml`)
- **About** — version, link to this repository, and Export Diagnostics (writes a redacted local report to the Desktop)

The shared config directory lives at `~/Library/Application Support/localvoxtral/config`.

## Under the hood

In **Managed local** mode (the default), localvoxtral installs, launches, and supervises two inference engines for you — no terminal required:

- **Dictation — [voxmlx](https://github.com/T0mSIlver/voxmlx)** streaming [Voxtral Mini 4B Realtime in 4-bit](https://huggingface.co/T0mSIlver/Voxtral-Mini-4B-Realtime-2602-MLX-4bit). localvoxtral ships a tuned build that adds a native OpenAI Realtime WebSocket server and memory-management optimizations for long dictation sessions.
- **Polishing — [mlx-lm](https://github.com/T0mSIlver/mlx-lm)** running [Qwen3.5-0.8B in 8-bit](https://huggingface.co/mlx-community/Qwen3.5-0.8B-MLX-8bit), a lightweight model that cleans up transcripts with negligible overhead. The tuned build adds enhanced prompt caching that roughly halves prompt-processing time for each polishing call.

Engines install from pinned, checksum-verified releases into `~/Library/Application Support/localvoxtral`, never outlive the app (a watchdog stops them even after a crash), and uninstall by deleting that one folder.

Prefer your own hardware? Dictation and polishing each switch independently to **External URL** mode in **Settings → Endpoints** — any OpenAI Realtime-compatible server works for dictation, any chat-completions server for polishing.

<details>
<summary>Example: Voxtral Realtime on vLLM (NVIDIA GPU)</summary>

```bash
VLLM_DISABLE_COMPILE_CACHE=1
vllm serve mistralai/Voxtral-Mini-4B-Realtime-2602 --compilation_config '{"cudagraph_mode": "PIECEWISE"}'
```

The settings recommended on the [model page](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602); tested against an NVIDIA RTX 3090.

</details>

## Roadmap

- [ ] Developer ID signing + notarization — install with no Gatekeeper workarounds
- [ ] Documentation website — a visual, end-user guide beyond this README
- [ ] Model choice in Managed local mode — pick the polishing LLM instead of the pinned default
- [ ] More streaming ASR models beyond Voxtral Realtime — e.g. [NVIDIA Nemotron 3.5 ASR Streaming 0.6B](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b)

## UI

<!-- Regenerate the screenshots below with the "Capture README Assets" workflow (Actions -> capture-assets.yml, run on the branch) or ./scripts/capture-readme-assets.sh on a Mac. Captures are pinned to dark mode for consistency. The demo video is recorded with ./scripts/record-demo.sh (operator speaks the prompted lines) or hands-free via the "Record README Demo" workflow (record-demo.yml, TTS through BlackHole on the self-hosted runner); GitHub only renders inline video from user-attachments URLs, so the resulting mp4 is drag-dropped into a PR comment by hand and the URL pasted here on its own line. -->

<p>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/icons/menubar/MicIconTemplate@2x_dark-preview.png" />
    <img src="assets/icons/menubar/MicIconTemplate@2x.png" alt="localvoxtral menubar icon" width="28" height="28" />
  </picture>
  Menubar icon
</p>

| General | Endpoints |
| --- | --- |
| ![localvoxtral general settings](assets/settings-general.png) | ![localvoxtral endpoints settings](assets/settings-endpoints.png) |
| Dictation | Text Processing |
| ![localvoxtral dictation settings](assets/settings-dictation.png) | ![localvoxtral text processing settings](assets/settings-text-processing.png) |
| Popover | |
| ![localvoxtral popover view](assets/popover.png) | |
