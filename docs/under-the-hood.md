# Under the hood

What localvoxtral runs, where your words go, and which models it pins. It
also covers the hosted Mistral API and running the models on your own server.

## Privacy

With the managed local engines, nothing you say or write leaves your Mac.
Audio capture, transcription and LLM polishing run as local processes. The
only network traffic is the one-time download of the engines and models.

There is no telemetry, no account and no cloud fallback.

The context-aware polishing features (session context, repo vocabulary,
clipboard, the agent's screen) are opt-in, and by default send context only
to a polisher on this Mac
([Polish context: what each toggle sends](coding-agents.md#polish-context-what-each-toggle-sends)).

[Quick capture](coding-agents.md#quick-capture) is the exception you trigger
yourself: a capture goes to your polishing model with its project's context
(README and AGENTS.md openings, code search hits, issue and pull request
titles), wherever polishing runs, to be routed and drafted.

What the app keeps on this Mac (your dictations, optionally their audio, and
diagnostic records of how each was polished) is described under
[History](dictation.md#history), where each can be turned off and deleted.

If you point localvoxtral at your own **External URL** server or at the
**Mistral API** instead, your audio and transcripts go where you send them.

### Where API keys are stored

The app stores every API key you enter in your login Keychain, under the
service `com.localvoxtral.api-keys`. That covers the External URL dictation
and polishing keys and the Mistral key.

The app never writes the keys to its preferences file. They never appear in a
backup or export of that file.

The app reads a key back only when something needs it. That means the engines
you have selected, at launch or when you switch to one, and the Engines pane,
which shows the fields. Managed local mode uses no key, so that setup never
opens the Keychain.

This matters because localvoxtral is not signed with an Apple Developer
identity. macOS ties each stored item to the exact build that wrote it, so a
newly installed build asks you to allow its first read. Answer **Always
Allow** and that build stops asking.

## The managed local engines

In **Managed local** mode, the default, localvoxtral starts and supervises
two inference engines for you. You need no terminal.

### Dictation engine

Dictation runs in localvoxtral-speechd, a bundled Swift helper built on
[mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift). It streams
[Voxtral Mini 4B Realtime in 4-bit with a quantized LM head](https://huggingface.co/T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead)
through the app's OpenAI Realtime-compatible server.

That checkpoint converts the mlx-community 4-bit snapshot and also quantizes
the tied output head. The quantized head cuts the decode loop's largest
projection from ~30 ms to ~3 ms per token and saves ~530 MB of memory, with
no loss in transcription quality.

One dictation can run for up to an hour. The limit guards against a session
left running and is not a speed limit. The helper holds a steady 3.5 GB and
stays ahead of live speech for at least three hours. When a dictation reaches
the limit, the helper stops and the menu bar says so.

The Engines pane also offers
[NVIDIA Nemotron 3.5 ASR Streaming 0.6B in 8-bit](https://huggingface.co/mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit),
for Macs where the speech model and the polish model compete for memory. It
takes 0.8 GB on disk, against Voxtral's 2.6 GB.

Nemotron is a cache-aware streaming RNN-T, not a decoder that attends over
the whole utterance. It transcribes in fixed 320 ms chunks, and it is the
less accurate of the two models. NVIDIA publishes it under OpenMDW 1.1.

Changing the model picker restarts the helper and downloads the new
checkpoint.

### Polishing engine

Polishing runs in localvoxtral-polishd, a bundled Swift helper built on
Apple's [MLX Swift](https://github.com/ml-explore/mlx-swift-lm). It runs
[Qwen3.5-4B-OptiQ in 4-bit](https://huggingface.co/mlx-community/Qwen3.5-4B-OptiQ-4bit)
by default. Settings offers a lighter 0.8B and a larger 9B.

A warm prompt cache keeps polish latency low. Turning polishing off frees its
memory at once.

The helper builds against an mlx-swift-lm main-branch commit from 2026-09-22,
ee673d6, not a release (pinned in the helper's
[package file](../PolishHelper/Package.swift)). No release yet loads OptiQ
checkpoints correctly, because they ship extra weight files next to the
model's.

### Model pins and quality checks

Both helpers ship inside the app bundle. Both speech models and the polish
model are pinned to an exact Hugging Face commit. The app downloads and loads
that commit, never the repo's moving main branch, so an upstream edit to a
model repo can never change what your install runs.

The app supervises both helpers, and a watchdog stops them even if the app
crashes.

A weekly end-to-end eval guards transcription and polish quality. It runs
real audio through the production ASR and polishing path and scores the
result against an agent-dictation corpus of ~160 cases. A model or prompt
change that makes dictation worse gets caught before it ships.

## Mistral API

Switch Dictation or Polishing to **Mistral API** in **Settings → Engines**,
then paste one API key from
[console.mistral.ai](https://console.mistral.ai/api-keys).

- Dictation uses Voxtral Mini Transcribe Realtime
  (voxtral-mini-transcribe-realtime-2602) over Mistral's hosted realtime
  socket, at 0.006 USD per minute of audio.
- Polishing uses Mistral Medium 3.5 (mistral-medium-3-5) with reasoning off,
  at 1.5 USD per million input tokens and 7.5 USD per million output tokens.
  [Polish while you speak](coding-agents.md#polishing) is off by default
  here, since it multiplies the input tokens.

In this mode your audio and transcripts reach Mistral.

### Choose models

The two engines share the key but switch independently. You can pair hosted
dictation with local polishing, or the reverse.

Each engine's **Model** menu lists every model your key can use for that job,
read from Mistral's model list. Polishing can therefore also run on Mistral's
other chat models, or on partner models Mistral hosts, such as Z.ai's GLM 5.3
(zai-glm-5-3).

GLM does not accept reasoning off, so polishing asks it for its lowest
setting, low. Models without reasoning get no reasoning setting at all.

### The second pass in the Overlay Buffer

With the Overlay Buffer, Mistral API dictation transcribes each dictation a
second time when you stop. The realtime model takes no vocabulary. The app
therefore keeps the dictation's audio in memory and sends it whole to Voxtral
Mini Transcribe 2 (voxtral-mini-latest) with up to 100 terms.

The terms come from:

- your Global terms;
- your replacement dictionary's spellings;
- only with **Send context to non-local polishing servers** on, this
  dictation's context. That is the terms learned from polishing, the ones the
  project's coding agent proposed, and the identifiers and file names in the
  joined session and on the screen as it was when you started speaking. The
  project is the joined session's, or the terminal's repository.

If the answer comes back within 2.5 seconds plus one second per minute of
audio, its text replaces the realtime text and polishing runs on it. When
it left out a stretch of four or more words the realtime text had, that
stretch is put back. A later answer leaves the realtime text as it is.

The app writes the audio to disk only if History keeps audio.

The second pass costs 0.003 USD per minute, so hosted dictation in the
Overlay Buffer costs 1.5 times the realtime price. Live Auto-Paste has
already typed its text and gets no second pass.

**Re-transcribe dictations on stop**, in the pane's Mistral API group, turns
the second pass off, and the price falls back to the realtime one. It is on
by default because Mistral's realtime stream sometimes stalls for a few
seconds and drops the words spoken meanwhile; the second pass is what puts
them back. With it off, those words stay lost, and the custom terms above
no longer reach the transcript, except through polishing. A dictation
already under way keeps the setting it started with.

### The usage estimate

The **Usage** row in the pane's Mistral API group estimates what those
requests cost, in EUR. It covers today, the last 7, 30 or 90 days, or all
time.

The app logs every request it sends to a model, Mistral's or not, one line
per request, in
`~/Library/Application Support/localvoxtral/mistral-usage.jsonl`. Each line
holds:

- the time;
- the feature that asked: dictation, polishing, the second pass, term
  suggestions, project terms, quick-capture routing or drafting;
- the backend that answered: Mistral, Jev, the bundled helper, your own
  server, or a coding agent;
- the model;
- the seconds of audio sent, or the tokens the backend reports;
- the estimated cost: in EUR for Mistral, in USD at API prices for an agent
  run that reports it, and in USD at Jev's list price ($0.042 per million
  input tokens) for a Jev call whose answer reports its tokens. Vibe reports
  tokens but no price.

The Usage row sums only the Mistral lines. The log never holds what you said,
and nothing in it leaves the Mac.

The prices are Mistral's EUR list prices, built into the app, so the estimate
can differ from your invoice. Mistral does not document how it rounds audio
time. The app counts a model it has no price for but leaves it out of the
total.

The app times dictation on the Mac, because the audio duration Mistral
reports back is wrong. It reported 2 seconds for clips from 4.6 to 30.7
seconds long. For the billed figure, see the usage page in Mistral's admin
console.

## Terms from your coding agent

The opt-in project-terms run runs Claude Code on the pinned sonnet model
alias, and Vibe and opencode on their own configured model. Its tools, caps
and measured costs are in
[Terms from your coding agent](dictation.md#terms-from-your-coding-agent).

Haiku 4.5 was measured and rejected for Claude Code. It cost the same, took
ten times as long and padded the list with generic names.

## Bring your own server

To run the models on your own hardware, switch Dictation or Polishing to
**External URL** in **Settings → Engines**, and fill in the server URL, the
model name and an API key. Dictation works with any OpenAI
Realtime-compatible server, and polishing with any chat-completions server.
For polishing, enter either a base URL such as `http://127.0.0.1:8080` or
the full chat completions URL; the app appends `/v1/chat/completions` to a
base URL.

For example, to serve Voxtral Realtime with vLLM on an NVIDIA GPU:

```bash
VLLM_DISABLE_COMPILE_CACHE=1
vllm serve mistralai/Voxtral-Mini-4B-Realtime-2602 --compilation_config '{"cudagraph_mode": "PIECEWISE"}'
```

These are the settings the
[model page](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602)
recommends, tested on an NVIDIA RTX 3090.

Voxtral Realtime spends one token of context per 80 ms of audio, so one vLLM
session holds about 164 s at the default `--max-model-len 2048`. Past that the
transcript turns to garbage, and vLLM's engine can crash. The app reads the
limit from the server's `/v1/models` at the start of each dictation (2048 when
the model is listed without one) and, before the limit, finishes the session
and carries the dictation on in a fresh one. It picks a pause once the
session is 60% full and does it regardless at 85%. Nothing changes on
screen; a raised `--max-model-len` just moves the switch later.
