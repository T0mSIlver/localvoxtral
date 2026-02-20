# Realtime Backend Notes

This project now supports two websocket backends behind a shared dictation flow:

- `OpenAI/vLLM` via `Sources/localvoxtral/RealtimeWebSocketClient.swift`
- `mlx-audio` via `Sources/localvoxtral/MlxAudioRealtimeWebSocketClient.swift`

## Runtime selection

- Selected in Settings through `SettingsStore.RealtimeProvider`.
- Persisted in `UserDefaults` key: `settings.realtime_provider`.
- Endpoint is persisted per backend:
  - OpenAI/vLLM: `settings.endpoint_url`
  - mlx-audio: `settings.mlx_audio_endpoint_url`
- Model name is persisted per backend:
  - OpenAI/vLLM: `settings.model_name`
  - mlx-audio: `settings.mlx_audio_model_name`
- Consumed by `DictationViewModel` which chooses the active client per dictation session.

## Shared integration points

- Protocol: `Sources/localvoxtral/RealtimeClient.swift`
- Unified event type: `RealtimeWebSocketClient.Event`
- Dictation logic remains centralized in `Sources/localvoxtral/DictationViewModel.swift`

## Backend specifics

### OpenAI/vLLM

- Uses `input_audio_buffer.append` and `input_audio_buffer.commit`.
- Supports periodic commit loop (`supportsPeriodicCommit = true`).

### mlx-audio

- Connects to `/v1/audio/transcriptions/realtime`.
- Sends startup JSON config immediately after websocket open:
  - `model`
  - `sample_rate` (`16000`)
  - `streaming` (`true`)
- Streams PCM16 mono audio as binary websocket frames.
- Parses:
  - `{"type":"delta","delta":"..."}`
  - `{"type":"complete","text":"...","is_partial":...}`
  - `{"status":"ready", ...}`
  - `{"error":"...", ...}`
- Does not support explicit commit events (`supportsPeriodicCommit = false`).

## Current UX model

- The app is a client only.
- Users are expected to start `mlx-audio` server themselves when using that backend.
