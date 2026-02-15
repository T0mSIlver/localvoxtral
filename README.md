# localvoxtral

localvoxtral is a native macOS menu bar app for realtime dictation.
It keeps the loop simple: start dictation, speak, get text fast.

It connects to OpenAI Realtime-compatible endpoints, including local vLLM.

## Features

- Global shortcut: `Cmd + Option + Space` to start/stop from anywhere
- Native menu bar app with instant open, no heavy UI
- Live dictation that writes into your active text field as you speak
- Pick your preferred microphone input device
- Copy the latest segment in one click
- Works with local or remote OpenAI Realtime-compatible endpoints

## Quick start

Build and run as an app bundle (recommended):

```bash
./scripts/package_app.sh release
open ./dist/localvoxtral.app
```

## Distribution (GitHub Releases)

One-time setup now exists in this repo:

- GitHub Actions workflow: `/Users/tom/Desktop/projects/supervoxtral/.github/workflows/release.yml`
  - Trigger: push a tag matching `v*.*.*` (example: `v0.1.0`)
  - Action: builds/tests on `macos-latest`, packages `dist/localvoxtral.app`, zips it, creates/updates the GitHub Release, and uploads the zip asset
- Local release flow: `/Users/tom/Desktop/projects/supervoxtral/scripts/release.sh`
  - Trigger: run `./scripts/release.sh vX.Y.Z` from a clean `main`
  - Action: validates repo state, runs build/tests, packages + zips app locally, pushes `main`, creates/pushes the tag that triggers GitHub Actions publishing

## Settings

- Open **Settings** from the menu bar popover to set:
  - Realtime endpoint
  - Model name
  - API key
  - Commit interval
  - Auto-copy finalized segment

## Tested setup

- Tested with a local `vllm` server running on an NVIDIA RTX 3090, using the default settings recommended on the [Voxtral Mini 4B Realtime model page](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602).

## Roadmap

- [ ] Customize keyboard shortcut
- [ ] Implement one of the on-device Voxtral Realtime integrations recommended in the model README:
  - [Pure C](https://github.com/antirez/voxtral.c) - thanks [Salvatore Sanfilippo](https://github.com/antirez)
  - [mlx-audio framework](https://github.com/Blaizzy/mlx-audio) - thanks [Shreyas Karnik](https://github.com/shreyaskarnik)
  - [MLX](https://github.com/awni/voxmlx) - thanks [Awni Hannun](https://github.com/awni)
  - [Rust](https://github.com/TrevorS/voxtral-mini-realtime-rs) - thanks [TrevorS](https://github.com/TrevorS)
