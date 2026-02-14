# SuperVoxtral

A clean native macOS menu bar dictation app with a superwhisper-like flow:

- top bar popover with one-click actions
- small Settings window
- live transcript rendering
- microphone audio streamed to an OpenAI Realtime-compatible WebSocket endpoint (including local vLLM realtime serving)

## Run

```bash
swift run SuperVoxtral
```

## Run as an app bundle (recommended)

Accessibility permission is much more reliable when launched as a `.app`:

```bash
./scripts/package_app.sh release
open ./dist/SuperVoxtral.app
```

Then enable `SuperVoxtral` in:
`System Settings > Privacy & Security > Accessibility`

## Icons

- App icon source: `assets/icons/app/AppIcon.png`
- Menubar icon source priority:
  - `menubar-icon.pdf` (project root, preferred)
  - `assets/icons/menubar/MenubarIcon.svg` (fallback)

## Configure

Open `Settings` from the popover and set:

- endpoint: `ws://127.0.0.1:8000/v1/realtime` (or your realtime endpoint)
- model: your served realtime ASR model name
- API key: optional for local setups

Defaults can also be pre-set via environment variables:

- `REALTIME_ENDPOINT`
- `REALTIME_MODEL`
- `OPENAI_API_KEY`

## Realtime protocol notes

This client sends realtime events in a vLLM-safe sequence:

- `session.update` with model
- `input_audio_buffer.append` with base64 PCM16 mono audio at 16kHz (batched every 100ms)
- `input_audio_buffer.commit` only after audio has been appended and no generation is currently in progress
- `input_audio_buffer.commit` with `final: true` on stop (only when there is active/pending audio)

It handles incoming events:

- `transcription.delta`
- `transcription.done`

and common OpenAI-style transcript variants.

## Permissions

- Microphone permission is required.
- For one-click paste (`Paste Latest Segment`), macOS may request Accessibility permission.
