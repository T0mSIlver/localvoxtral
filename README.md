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

- All icon source files live under `assets/icons/`.
- App icon source: `assets/icons/app/AppIcon.png`
- Menubar icon source priority:
  - `assets/icons/menubar/MicIconTemplate.png` + `assets/icons/menubar/MicIconTemplate@2x.png` (preferred)
  - `assets/icons/menubar/menubar-icon.pdf` (fallback)
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

- waits for `session.created`
- `session.update` with model
- `input_audio_buffer.append` with base64 PCM16 mono audio at 16kHz (batched every 100ms)
- `input_audio_buffer.commit` only after buffered audio is present
- `input_audio_buffer.commit` with `final: true` before disconnect when there is active/pending audio

It handles incoming events:

- `transcription.delta`
- `transcription.done`

and common OpenAI-style transcript variants.

## Realtime connection lifecycle

Recommended global flow for robust vLLM realtime handling:

1. Open WebSocket to `/v1/realtime`.
2. Wait for `session.created` before sending protocol events.
3. Send `session.update` with the served model.
4. Stream `input_audio_buffer.append` chunks (base64 PCM16 mono @ 16kHz).
5. Send `input_audio_buffer.commit` only after audio has been appended.
6. Read `transcription.delta` / `transcription.done` continuously.
7. On stop, send `input_audio_buffer.commit` with `final: true`, then disconnect gracefully.
8. Keep heartbeat ping + handshake timeout to detect dead or half-open connections.

References:

- [vLLM Realtime API docs](https://docs.vllm.ai/en/latest/serving/openai_compatible_server.html#realtime-api)
- [vLLM realtime endpoint/router source](https://github.com/vllm-project/vllm/blob/main/vllm/entrypoints/openai/realtime/api_router.py)
- [vLLM realtime connection state machine](https://github.com/vllm-project/vllm/blob/main/vllm/entrypoints/openai/realtime/connection.py)
- [vLLM realtime file client example](https://github.com/vllm-project/vllm/blob/main/examples/online_serving/openai_realtime_client.py)
- [vLLM realtime microphone client example](https://github.com/vllm-project/vllm/blob/main/examples/online_serving/openai_realtime_microphone_client.py)

## Integration tests (vLLM)

These tests are opt-in and validate live WebSocket behavior against a running vLLM realtime server.

```bash
VLLM_REALTIME_TEST_ENABLE=1 \
VLLM_REALTIME_TEST_ENDPOINT=ws://127.0.0.1:8000/v1/realtime \
VLLM_REALTIME_TEST_MODEL=mistralai/Voxtral-Mini-4B-Realtime-2602 \
swift test --filter RealtimeWebSocketVLLMIntegrationTests
```

Optional auth:

- `VLLM_REALTIME_TEST_API_KEY` (falls back to `OPENAI_API_KEY`)

## Permissions

- Microphone permission is required.
- For one-click paste (`Paste Latest Segment`), macOS may request Accessibility permission.
