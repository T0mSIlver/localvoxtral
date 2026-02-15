# SuperVoxtral

SuperVoxtral is a native macOS menu bar app for realtime dictation.
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
open ./dist/SuperVoxtral.app
```

## Settings

- Open **Settings** from the menu bar popover to set:
  - Realtime endpoint
  - Model name
  - API key
  - Commit interval
  - Auto-copy finalized segment

## Permissions

- Microphone access is required.
- Accessibility access is recommended for reliable text insertion into the focused app.