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

## Bring your own server

Prefer your own hardware? Switch Dictation or Polishing to **External URL**
in **Settings → Endpoints**: any OpenAI Realtime-compatible server works for
dictation, any chat-completions server for polishing.

Example: Voxtral Realtime on vLLM (NVIDIA GPU) —

```bash
VLLM_DISABLE_COMPILE_CACHE=1
vllm serve mistralai/Voxtral-Mini-4B-Realtime-2602 --compilation_config '{"cudagraph_mode": "PIECEWISE"}'
```

The settings recommended on the
[model page](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602),
tested against an NVIDIA RTX 3090.
