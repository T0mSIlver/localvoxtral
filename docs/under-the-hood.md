# Under the hood

## Privacy

In the default Managed local mode, nothing you say or write is sent
anywhere. Audio capture, transcription, and LLM polishing all run as local
processes on your Mac, and the only network traffic is the one-time engine
and model download. There is no telemetry, no account, and no cloud
fallback. The context-aware polishing features (Claude Code session context,
repo vocabulary, clipboard context) are opt-in and by default only ever talk
to a loopback polishing endpoint — a non-local endpoint receives context
only if you additionally enable the explicit trusted-endpoint opt-in
(default off). If you point localvoxtral at your own External URL server
instead, your data goes only where you send it.

In **Mistral API** mode, the audio you dictate and the transcript being
polished are sent to Mistral's API. The context features do not change with
the mode: api.mistral.ai is not a local endpoint, so clipboard, terminal
screen, repo vocabulary and Claude Code session context are attached only if
you also turn on the explicit trusted-endpoint opt-in — exactly as for any
other non-local endpoint.

Any API key you enter — the External URL dictation and polishing keys, and
the Mistral key — is stored in your login Keychain under the service
`com.localvoxtral.api-keys`, never in the app's preferences file and so never
in a backup or `defaults export` of it.

## The managed local engines

In **Managed local** mode (the default), localvoxtral launches and
supervises two inference engines for you — no terminal required:

- **Dictation — `localvoxtral-speechd`**, a bundled Swift helper built on
  [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift), streams
  [Voxtral Mini 4B Realtime in 4-bit with a quantized LM head](https://huggingface.co/T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead)
  through the app's OpenAI Realtime-compatible server. The checkpoint is a
  conversion of the mlx-community 4-bit snapshot that also quantizes the
  tied output head — cutting the decode loop's largest projection from
  ~30 ms to ~3 ms per token and saving ~530 MB of memory, at level
  transcription quality.
- **Polishing — `localvoxtral-polishd`**, a bundled Swift helper built on
  Apple's [MLX Swift](https://github.com/ml-explore/mlx-swift-lm), runs
  [Qwen3.5-4B-OptiQ in 4-bit](https://huggingface.co/mlx-community/Qwen3.5-4B-OptiQ-4bit)
  by default (a lighter 0.8B and a larger 9B are one click away in
  Settings). A warm prompt cache keeps polish latency low, and turning
  polishing off frees its memory immediately.

Both helpers ship inside the app bundle. Their model weights download from
Hugging Face at exact pinned commits, so an upstream edit to a model repo
can never change what your install runs. The app supervises both helpers,
and a watchdog stops them even if the app crashes. Transcription-and-polish
quality is held by a nightly end-to-end eval — real audio through the
production ASR and polishing path, scored against an agent-dictation corpus
of ~160 cases — so a model or prompt change that regresses dictation gets
caught before it ships.

## Mistral API

Rather run the same models without the download? Switch Dictation or
Polishing to **Mistral API** in **Settings → Engines** and paste one API key
from [console.mistral.ai](https://console.mistral.ai/api-keys):

- **Dictation** — Voxtral Mini Transcribe Realtime
  (`voxtral-mini-transcribe-realtime-2602`) over Mistral's hosted realtime
  socket, at 0.006 USD per minute of audio.
- **Polishing** — Mistral Medium 3.5 (`mistral-medium-3-5`), at 1.5 USD per
  million input tokens and 7.5 USD per million output tokens. Reasoning is
  switched off for polishing: a polish pays no reasoning trace.

Both engines share one key and switch independently — hosted dictation with
local polishing, or the reverse, is a supported combination. The **Mistral
API** group on the Engines pane holds the key, a "Check key" button, and a
one-click "Use Mistral for dictation and polishing" setup. Either model field
can name another Mistral model; empty means the default above.

What this trades away is the privacy paragraph at the top of this page: in
this mode your audio and transcripts reach Mistral. The context features stay
behind the trusted-endpoint opt-in regardless.

## Bring your own server

Prefer your own hardware? Switch Dictation or Polishing to **External URL**
in **Settings → Engines**: any OpenAI Realtime-compatible server works for
dictation, any chat-completions server for polishing.

Example: Voxtral Realtime on vLLM (NVIDIA GPU) —

```bash
VLLM_DISABLE_COMPILE_CACHE=1
vllm serve mistralai/Voxtral-Mini-4B-Realtime-2602 --compilation_config '{"cudagraph_mode": "PIECEWISE"}'
```

The settings recommended on the
[model page](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602),
tested against an NVIDIA RTX 3090.
