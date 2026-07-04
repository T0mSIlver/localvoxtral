# localvoxtral

<p align="center">
  <img src="assets/demo.gif" alt="localvoxtral demo" width="760" />
</p>

<p align="center">
  <img src="assets/icons/app/AppIcon.png" alt="localvoxtral app icon" width="128" height="128" />
</p>

localvoxtral is a native macOS menu bar app for realtime dictation.
It keeps the loop simple: start dictation, speak, get text fast.
Unlike Whisper-based tools that transcribe after you stop speaking, Voxtral Realtime streams text as audio arrives, so words appear while you're still talking.
On Apple Silicon, `localvoxtral` + `voxmlx` + `mlx-lm` provides a fully local path (audio + inference + LLM polishing stay on-device), improving privacy and avoiding API costs.

On Apple Silicon the default **Managed local** mode runs everything for you: localvoxtral installs and manages `voxmlx` (dictation) and `mlx-lm` (LLM polishing) itself.
You can switch dictation and polishing independently to **External URL** mode for OpenAI-compatible endpoints you run yourself.

Built for Mistral AI's [Voxtral Mini 4B Realtime](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602) model, but it works with any OpenAI-compatible Realtime API backend and model.

## Features

- Global shortcuts: a single modifier key (tap for Overlay Buffer, hold for Live Auto-Paste) or per-mode keyboard shortcuts with `Toggle` / `Push to Talk` behavior
- Native menu bar app with instant open and visual feedback with the icon
- Output modes: overlay buffer (commit on stop) or live auto-paste into focused input
- Personal replacement dictionary (exact match or exact match + LLM-aware-replacement)
- Editable LLM system and user prompt templates
- Fully local dictation option with `voxmlx` (no third-party API traffic)
- Fully local LLM polishing option with `mlx-lm` (no third-party API traffic)
- Pick your preferred microphone input device
- Copy the latest transcribed segment

## Quick start

### Recommended: one-command installer

```bash
curl -fsSL https://raw.githubusercontent.com/T0mSIlver/localvoxtral/main/scripts/install.sh | bash
```

This downloads the latest release, clears quarantine metadata, re-signs the app locally, installs it into `/Applications`, and opens it.

### Manual install from GitHub Releases (DMG)

Download the latest `.dmg` from [Releases](https://github.com/T0mSIlver/localvoxtral/releases/latest).

Releases are ad-hoc signed (not notarized). On macOS 26, launching the raw downloaded app can hang on first launch unless you use the installer script above. On older macOS versions, first launch may instead be blocked with an **Open Anyway** button in **System Settings -> Privacy & Security**, or reported as "damaged". This clears the quarantine flag:

```bash
xattr -cr /Applications/localvoxtral.app
```

### Alternatively, build from source as an app bundle

```bash
./scripts/package_app.sh release
open ./dist/localvoxtral.app
```

## Shortcuts

Two ways to trigger dictation, configured in **Settings -> Dictation**:

**Single modifier key** — Fn/Globe, Right Command, or Right Option. One key, two gestures:

| Gesture | Behavior |
|---|---|
| Tap | Toggle Overlay Buffer dictation on/off |
| Hold (past the hold delay, default 350 ms) | Live Auto-Paste push-to-talk — dictates while held, stops on release |

The gesture selects the output mode, so both workflows are always one key away. Pressing any other key while the modifier is down cancels the gesture, so regular keyboard combos are unaffected. Requires Accessibility permission.

**Per-mode keyboard shortcuts** — separate shortcuts for Overlay Buffer and Live Auto-Paste; behavior follows the `Toggle` / `Push to Talk` setting.

The **Output mode** setting applies to dictation started from the menu bar. Keyboard gestures and per-mode shortcuts select their mode directly.

**Escape** cancels an in-progress dictation.

## Settings

A first-launch setup wizard (Welcome → Permissions → Downloads → Finish) grants microphone/Accessibility permissions and downloads the managed local engine. It appears once on a fresh install; re-run it any time from **Settings → General → Re-run Setup…**.

- Open **Settings** from the menu bar popover to set:
  - **General**: microphone and Accessibility permissions, auto-copy final segment, and re-run the setup wizard
  - Dictation trigger: single modifier key (tap/hold) or per-mode keyboard shortcuts (`Toggle` / `Push to Talk`)
  - Dictation and polishing backend modes (`Managed local` / `External URL`)
  - Realtime endpoint (URL, model name, API key)
  - Output mode (`Overlay Buffer` / `Live Auto-Paste`)
  - Replacement dictionary for live corrections and overlay finalization
  - LLM polishing toggle and endpoint (URL, model name, API key) — in the **Endpoints** tab; endpoint fields appear when polishing is in External URL mode
  - Export Diagnostics in **About** — writes a redacted local report to the Desktop
  - Open the shared config folder for `replacement_dictionary.toml`, `llm_system_prompt.toml`, and `llm_user_prompt.toml`

The shared config directory lives at `~/Library/Application Support/localvoxtral/config`.

## Tested setup

### Managed local (default)

In Managed local mode, localvoxtral installs pinned wheel releases of the selected managed backends into `~/Library/Application Support/localvoxtral/backends` using a pinned [uv](https://github.com/astral-sh/uv) it downloads on first use, and starts them lazily on the first dictation request. App launch stays network-inert; downloads happen only when dictation starts. The managed processes exit with the app — even after a crash, via a parent-pid watchdog. Uninstalling the backends is deleting that one directory.

**Dictation — voxmlx.** [voxmlx](https://github.com/awni/voxmlx) running [Voxtral Mini 4B Realtime in 4-bit](https://huggingface.co/T0mSIlver/Voxtral-Mini-4B-Realtime-2602-MLX-4bit) on M1 Pro, streaming partial text fast enough for realtime dictation (latency and throughput vary by hardware, model, and quantization). The managed build is [this fork](https://github.com/T0mSIlver/voxmlx), which adds a WebSocket server that speaks the OpenAI Realtime API protocol, memory-management optimizations, and managed-launch support (readiness signal + parent-pid watchdog).

**LLM polishing — mlx-lm.** When polishing is enabled, `mlx_lm.server` runs [Qwen3.5-0.8B in 8-bit](https://huggingface.co/mlx-community/Qwen3.5-0.8B-MLX-8bit) — a lightweight default that adds little overhead while remaining smart enough for reliable polishing. The managed build is [this fork](https://github.com/T0mSIlver/mlx-lm), which adds enhanced prompt caching (enabled by the managed launch): with the default polishing prompts, prompt processing is roughly 286 ms (~50%) faster on average on M1 Pro. On more powerful Apple Silicon the absolute savings will be lower because prompt processing is faster.

### External URL: vLLM

[vllm](https://github.com/vllm-project/vllm) OpenAI Realtime-compatible server running on an NVIDIA RTX 3090, using the default settings recommended on the [Voxtral Mini 4B Realtime model page](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602).

```bash
VLLM_DISABLE_COMPILE_CACHE=1
vllm serve mistralai/Voxtral-Mini-4B-Realtime-2602 --compilation_config '{"cudagraph_mode": "PIECEWISE"}'
```

Any other OpenAI Realtime-compatible endpoint works the same way — set the dictation backend to `External URL` in **Settings → Endpoints**, then enter the URL, model name, and API key if needed.

## Roadmap

- [ ] Enhance the server connection UX
- [x] Drive `voxmlx-serve` (from the `voxmlx` fork) upstream and assess app-managed local serving (start/stop/config) in localvoxtral.
- [ ] Implement more of the on-device Voxtral Realtime integrations recommended in the model README:
  - [Pure C](https://github.com/antirez/voxtral.c) - thanks [Salvatore Sanfilippo](https://github.com/antirez)
  - **done** ~~[MLX](https://github.com/awni/voxmlx) - thanks [Awni Hannun](https://github.com/awni)~~
  - [Rust](https://github.com/TrevorS/voxtral-mini-realtime-rs) - thanks [TrevorS](https://github.com/TrevorS)

## UI

<!-- Regenerate the screenshots below with ./scripts/capture-readme-assets.sh (run on a Mac; demo.gif is manual). They are auto-recaptured after merge, so a new/updated pane (e.g. settings-general.png) may render broken until that runs. -->

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
