# localvoxtral

<p align="center">
  <img src="assets/icons/app/AppIcon.png" alt="localvoxtral app icon" width="128" height="128" />
</p>

localvoxtral is a native macOS menu bar app for realtime dictation.
It keeps the loop simple: start dictation, speak, get text fast.

It supports two realtime backend modes: OpenAI Realtime-compatible endpoints (for example local vLLM), and `mlx-audio` realtime transcription endpoints.

## Features

- Global shortcut: `Cmd + Option + Space` to start/stop from anywhere
- Native menu bar app with instant open, no heavy UI
- Live dictation that writes into your active text field as you speak
- Pick your preferred microphone input device
- Copy the latest transcribed segment
- Stabilized mlx-audio transcription with word-boundary-aligned hypothesis merging

## Quick start

Build and run as an app bundle (recommended):

```bash
./scripts/package_app.sh release
open ./dist/localvoxtral.app
```

## Settings

- Open **Settings** from the menu bar popover to set:
  - Realtime endpoint
  - Model name
  - API key
  - Commit interval (`vLLM`)
  - Transcription delay (`mlx-audio`)
  - Auto-copy finalized segment

## Screenshots

<p>
  <img src="assets/icons/menubar/MicIconTemplate@2x.png" alt="localvoxtral menubar icon" width="22" height="22" />
  Menubar icon
</p>

<p>
  <img src="assets/settings.png" alt="localvoxtral settings view" width="420" />
</p>

## Tested setup

### vLLM

`vllm` server running on an NVIDIA RTX 3090, using the default settings recommended on the [Voxtral Mini 4B Realtime model page](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602).

```bash
VLLM_DISABLE_COMPILE_CACHE=1
vllm serve mistralai/Voxtral-Mini-4B-Realtime-2602 --compilation_config '{"cudagraph_mode": "PIECEWISE"}'
```

### mlx-audio

`mlx-audio` server on M1 Pro, running a [4bit quant](https://huggingface.co/mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit) of Voxtral Mini 4B Realtime

```bash
# Default max_chunk (6s) force-splits continuous speech mid-sentence; 30 lets silence detection handle segmentation naturally
MLX_AUDIO_REALTIME_MAX_CHUNK_SECONDS=30 python -m mlx_audio.server --workers 1
```

## Roadmap

- [ ] Customize keyboard shortcut
- [ ] Implement more of the on-device Voxtral Realtime integrations recommended in the model README:
  - [Pure C](https://github.com/antirez/voxtral.c) - thanks [Salvatore Sanfilippo](https://github.com/antirez)
  -  **done** ~~[mlx-audio framework](https://github.com/Blaizzy/mlx-audio) - thanks [Shreyas Karnik](https://github.com/shreyaskarnik)~~
  - [MLX](https://github.com/awni/voxmlx) - thanks [Awni Hannun](https://github.com/awni)
  - [Rust](https://github.com/TrevorS/voxtral-mini-realtime-rs) - thanks [TrevorS](https://github.com/TrevorS)
