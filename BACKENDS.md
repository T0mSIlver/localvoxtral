# Backends in depth

localvoxtral talks to two backends: a realtime speech-to-text server for dictation and an OpenAI-compatible chat server for LLM polishing. Each one independently runs in **Managed local** mode (the app installs and supervises it) or **External URL** mode (you run it), switched in **Settings → Endpoints**.

## Managed local (default)

In Managed local mode, localvoxtral installs pinned wheel releases of the selected managed backends into `~/Library/Application Support/localvoxtral/backends` using a pinned [uv](https://github.com/astral-sh/uv) it downloads on first use. Downloads start only from explicit setup/dictation actions; enabling managed polishing may warm that backend immediately. The managed processes exit with the app — even after a crash, via a parent-pid watchdog. Uninstalling the backends is deleting that one directory.

### Dictation — voxmlx

[voxmlx](https://github.com/awni/voxmlx) running [Voxtral Mini 4B Realtime in 4-bit](https://huggingface.co/T0mSIlver/Voxtral-Mini-4B-Realtime-2602-MLX-4bit) on M1 Pro, streaming partial text fast enough for realtime dictation (latency and throughput vary by hardware, model, and quantization). The managed build is [this fork](https://github.com/T0mSIlver/voxmlx), which adds a WebSocket server that speaks the OpenAI Realtime API protocol, memory-management optimizations, and managed-launch support (readiness signal + parent-pid watchdog).

### LLM polishing — mlx-lm

When polishing is enabled, `mlx_lm.server` runs [Qwen3.5-0.8B in 8-bit](https://huggingface.co/mlx-community/Qwen3.5-0.8B-MLX-8bit) — a lightweight default that adds little overhead while remaining smart enough for reliable polishing. The managed build is [this fork](https://github.com/T0mSIlver/mlx-lm), which adds enhanced prompt caching (enabled by the managed launch): with the default polishing prompts, prompt processing is roughly 286 ms (~50%) faster on average on M1 Pro. On more powerful Apple Silicon the absolute savings will be lower because prompt processing is faster.

## External URL

### Tested: vLLM

[vllm](https://github.com/vllm-project/vllm) OpenAI Realtime-compatible server running on an NVIDIA RTX 3090, using the default settings recommended on the [Voxtral Mini 4B Realtime model page](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602):

```bash
VLLM_DISABLE_COMPILE_CACHE=1
vllm serve mistralai/Voxtral-Mini-4B-Realtime-2602 --compilation_config '{"cudagraph_mode": "PIECEWISE"}'
```

Any other OpenAI Realtime-compatible endpoint works the same way — set the dictation backend to `External URL` in **Settings → Endpoints**, then enter the URL, model name, and API key if needed. Polishing accepts any OpenAI-compatible chat-completions endpoint.
