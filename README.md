# SuperVoxtral

SuperVoxtral is a native macOS menu bar app for realtime dictation.
It keeps the loop simple: start dictation, speak, get text fast.

It connects to OpenAI Realtime-compatible endpoints, including local vLLM.

## Core features

- Menu bar-first UX with a small Settings window
- Start/stop dictation from the menu or `Cmd + Option + Space`
- Live partial + finalized transcript handling
- Microphone input selection
- Copy latest finalized segment
- Optional auto-copy for each finalized segment

## Quick start

Build and run as an app bundle (recommended):

```bash
./scripts/package_app.sh release
open ./dist/SuperVoxtral.app
```

Or run directly during development:

```bash
swift run SuperVoxtral
```

## Configure

Open **Settings** and set:

- Realtime endpoint (default: `ws://127.0.0.1:8000/v1/realtime`)
- Model name (default: `voxtral-mini-latest`)
- API key (optional for local setups)

You can also preconfigure with:

- `REALTIME_ENDPOINT`
- `REALTIME_MODEL`
- `OPENAI_API_KEY`

## Permissions

- Microphone access is required.
- Accessibility access is recommended for reliable text insertion into the focused app.

## Development

```bash
swift test
```

Optional live vLLM integration tests:

```bash
VLLM_REALTIME_TEST_ENABLE=1 \
VLLM_REALTIME_TEST_ENDPOINT=ws://127.0.0.1:8000/v1/realtime \
VLLM_REALTIME_TEST_MODEL=mistralai/Voxtral-Mini-4B-Realtime-2602 \
swift test --filter RealtimeWebSocketVLLMIntegrationTests
```
