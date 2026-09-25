# Under the hood

## Privacy

Nothing you say or write is sent anywhere. Audio capture, transcription,
and LLM polishing run as local processes on your Mac, and the only network
traffic is the one-time engine and model download. There is no telemetry,
no account, and no cloud fallback. The context-aware polishing features
(Claude Code session context, repo vocabulary, clipboard context) are
opt-in and only ever talk to a loopback polishing endpoint. A non-local
endpoint receives context only if you also enable the explicit
trusted-endpoint opt-in (default off).

If you point localvoxtral at your own External URL server or at the Mistral
API instead, your audio and transcripts go where you send them. Neither is a
local endpoint, so the context features stay behind the trusted-endpoint
opt-in there too.

Any API key you enter (the External URL dictation and polishing keys, and
the Mistral key) is stored in your login Keychain under the service
`com.localvoxtral.api-keys`, never in the app's preferences file and so never
in a backup or `defaults export` of it.

A key is read back only when something needs it: the engines you have selected
(at launch, or when you switch to one) and the Engines pane, which shows the
fields. Managed local mode authenticates with nothing, so that setup never
opens the Keychain at all. This matters because localvoxtral is not signed with
an Apple Developer identity: macOS ties each stored item to the exact build that
wrote it, so the first read by a newly installed build asks you to allow it.
Answer **Always Allow** and that build stops asking.

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
  transcription quality. One dictation can run for up to an hour — a guard
  against a session left running, not a speed limit: the helper holds a
  steady 4.2 GB and stays ahead of live speech for at least three hours. On
  reaching the limit it stops and says so in the menu bar.

  The Engines pane also offers
  [NVIDIA Nemotron 3.5 ASR Streaming 0.6B in 8-bit](https://huggingface.co/mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit),
  for Macs where the speech model and the polish model compete for memory:
  0.8 GB on disk against Voxtral's 2.6 GB. It is a cache-aware streaming
  RNN-T rather than a decoder that attends over the whole utterance, so it
  transcribes in fixed 320 ms chunks, and it is the less accurate of the
  two. NVIDIA publishes it under OpenMDW 1.1. Changing the picker restarts
  the helper and downloads the new checkpoint. Both models are pinned to an
  exact Hugging Face commit, and the app downloads and loads that commit,
  never the repo's moving `main`.

  Nemotron also favors your own terms while it decodes. At the start of each
  dictation the app sends the helper your custom terms and the learned terms
  polish has confirmed across several dictations, at most 100. When the model
  is unsure between spellings, a listed spelling wins. On a 260-sentence test
  set spoken by the system voice, it spelled 61.0% of listed terms right
  instead of 54.3%, with no rise in errors on the other words. The list goes
  only to the bundled helper, never to an external server or Mistral, and the
  helper's log records how many tokens it changed, never the terms. Voxtral
  receives the list too but cannot use it yet (#316). The change lives on a
  fork of mlx-audio-swift until it merges upstream.
- **Polishing — `localvoxtral-polishd`**, a bundled Swift helper built on
  Apple's [MLX Swift](https://github.com/ml-explore/mlx-swift-lm), runs
  [Qwen3.5-4B-OptiQ in 4-bit](https://huggingface.co/mlx-community/Qwen3.5-4B-OptiQ-4bit)
  by default (a lighter 0.8B and a larger 9B are one click away in
  Settings). A warm prompt cache keeps polish latency low, and turning
  polishing off frees its memory immediately. The helper builds against an
  mlx-swift-lm `main` commit from 2026-09-22 (`ee673d6`), not a release:
  no release yet loads OptiQ checkpoints correctly, because they ship
  extra weight files next to the model's.

Both helpers ship inside the app bundle. Their model weights download from
Hugging Face at exact pinned commits, so an upstream edit to a model repo
can never change what your install runs. The app supervises both helpers,
and a watchdog stops them even if the app crashes. Transcription-and-polish
quality is held by a nightly end-to-end eval — real audio through the
production ASR and polishing path, scored against an agent-dictation corpus
of ~160 cases — so a model or prompt change that regresses dictation gets
caught before it ships.

## Mistral API

Switch Dictation or Polishing to **Mistral API** in **Settings → Engines**
and paste one API key from
[console.mistral.ai](https://console.mistral.ai/api-keys). Dictation then
uses Voxtral Mini Transcribe Realtime
(`voxtral-mini-transcribe-realtime-2602`) over Mistral's hosted realtime
socket, at 0.006 USD per minute of audio. Polishing uses Mistral Medium 3.5
(`mistral-medium-3-5`) with reasoning switched off, at 1.5 USD per million
input tokens and 7.5 USD per million output tokens. Both engines share the
key and switch independently, so hosted dictation with local polishing
works, and so does the reverse. Each engine's **Model** menu lists every
model your key can use for that job, read from Mistral's model list, so
polishing can also run on Mistral's other chat models or on partner models
Mistral hosts, such as Z.ai's GLM 5.3 (`zai-glm-5-3`). GLM does not accept
reasoning switched off, so polishing asks it for its lowest setting (`low`);
models without reasoning are sent no reasoning setting at all. In this mode
your audio and transcripts reach Mistral.

The **Usage** row in the pane's Mistral API group estimates what those
requests cost, in EUR, over today, the last 7, 30 or 90 days, or all time.
The app logs every request it sends to Mistral in
`~/Library/Application Support/localvoxtral/mistral-usage.jsonl`, one line
per request: time, model, the seconds of audio sent (dictation) or the tokens
Mistral reports (polishing), and the estimated cost. The log never holds what
you said, and nothing in it leaves the Mac. Prices are Mistral's EUR list
prices, built into the app, so the estimate can differ from your invoice:
Mistral does not document how it rounds audio time, and a model the app has
no price for is counted but left out of the total. Dictation is timed on the
Mac because the audio duration Mistral reports back is wrong (it reported 2
seconds for clips from 4.6 to 30.7 seconds long). For the billed figure, see
the usage page in Mistral's admin console.

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
