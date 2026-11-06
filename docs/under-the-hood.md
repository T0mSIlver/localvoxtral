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

The first read may show a macOS prompt asking whether localvoxtral may use
the stored key. Answer **Always Allow**. Stable releases are signed with the
same Developer ID, so updates keep that answer.

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
least accurate of the three models. NVIDIA publishes it under OpenMDW 1.1.

The pane also offers
[NVIDIA Nemotron Unified ASR 0.6B in 8-bit](https://huggingface.co/T0mSIlver/nemotron-labs-unified-asr-0.6b-8bit),
0.7 GB on disk. It is the same kind of RNN-T, but it streams buffered: every
step re-encodes the last 5.6 s of audio with the new chunk, so it uses about
four times Nemotron 3.5's GPU. In exchange it makes fewer errors than 3.5,
especially in French, and covers 25 European languages. It runs at the same
320 ms latency, also under OpenMDW 1.1. Its Language row in the Engines pane
names the language you dictate in; Auto, the default, lets the model detect it.

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

Once a pinned model is downloaded, the app starts it without asking Hugging
Face, so it works offline. If Hugging Face is unreachable, it starts from the
model already on disk.

The app supervises both helpers, and a watchdog stops them even if the app
crashes.

Dictation waits only for the speech model. While the polish model is still
downloading, or if its helper failed, a dictation goes in as spoken and the
status line says "Polishing not ready; inserted as spoken." Polishing starts
with the first dictation after the helper is ready.

An end-to-end eval guards transcription and polish quality. It runs real
audio through the production ASR and polishing path and scores the result
against an agent-dictation corpus of ~160 cases. Every model or prompt change
runs it, so a change that makes dictation worse gets caught before it ships.

## Mistral API

Switch Dictation or Polishing to **Mistral API** in **Settings → Engines**,
then paste one API key from
[console.mistral.ai](https://console.mistral.ai/api-keys).

- Dictation uses Voxtral Mini Transcribe Realtime 3
  (voxtral-mini-transcribe-realtime-3-0) over Mistral's hosted realtime
  socket, at 0.008 USD per minute of audio. It is in public preview and has
  no open weights, so it runs only on Mistral's API. Mistral retires the
  previous model, Voxtral Mini Transcribe Realtime 2602
  (voxtral-mini-transcribe-realtime-2602, 0.006 USD per minute), on
  2027-04-30. A Mac that had chosen it moves to Realtime 3 once; until the
  retirement the **Model** menu still offers it.
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

### Your terms with Voxtral Realtime 3

Voxtral Realtime 3 takes a list of terms when the dictation starts, to spell
names and jargon right as you speak. It takes none later, so the app sends
up to 100 at the start, phrases included: your Global terms and your
replacement dictionary's spellings first, then, only with **Send context to
non-local polishing servers** on, the joined session's project terms. Those
are the second pass's terms below, without the screen's. Voxtral Realtime
2602 takes no terms.

### The second pass in the Overlay Buffer

With the Overlay Buffer, Mistral API dictation transcribes each dictation a
second time when you stop, with the context the start could not send. The
app keeps the dictation's audio in memory and sends it whole to Voxtral Mini
Transcribe 3 (voxtral-mini-transcribe-3-0) with up to 100 terms, phrases
included.

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
stretch is put back. A later answer leaves the realtime text as it is, and
the overlay's header says "Transcribing again timed out".

That allowance fits an upload of about 15 Mbit/s. Each pass measures its
upload rate, and the app keeps it in memory for that backend. When the last
rate was slower, the next pass gets the extra upload time, plus half again
as margin, up to 30 seconds in all.

The app writes the audio to disk only if History keeps audio.

The second pass costs 0.0035 USD per minute, so hosted dictation in the
Overlay Buffer costs about 1.4 times the realtime price. Live Auto-Paste has
already typed its text and gets no second pass.

Mistral's realtime stream sometimes stalls for a few seconds and drops the
words spoken meanwhile. When it resumes after five seconds or more of
silence while you were speaking, the app sends that stretch, plus the 3
seconds before it, to the same batch model with your Global terms and
dictionary spellings. The words it finds go into the overlay where the
stream skipped them, before you stop. When they can't be lined up with the
words on either side, or the answer misses the same deadline, the gap stays.
Each such request is logged and billed as a second pass, for its audio only.

**Re-transcribe dictations on stop**, in the pane's Mistral API group, turns
the second pass off, and the price falls back to the realtime one; stalls
are still filled in. With it off, the custom terms above no longer reach the
transcript, except through polishing. A dictation already under way keeps
the setting it started with.

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
  suggestions, project terms;
- the backend that answered: Mistral, the bundled helper, your own
  server, or a coding agent;
- the model;
- the seconds of audio sent, or the tokens the backend reports;
- the estimated cost: in EUR for Mistral, and in USD at API prices for an
  agent run that reports it. Vibe reports tokens but no price.

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

## Anthropic API

Polishing can run on Anthropic's API: switch Polishing to **Anthropic API**
in **Settings → Engines**, pick a model (Claude Haiku 5.5 by default, the
fastest; or Claude Sonnet 5.5) and paste an Anthropic API key. Anthropic
serves no speech-to-text, so Dictation never offers this mode. The app speaks
Anthropic's Messages API and asks for low effort, so the model thinks little
before it answers. Your transcripts reach Anthropic.

Claude models follow the polish rules more literally than GLM does, and left
misheard words in place. Requests to Anthropic carry one extra rule: repair
a word that makes no sense where it stands with what you most plausibly said,
drop false starts and repeated words, and fix where sentences break, while
keeping your words, order and hedges.

An External URL server at `https://api.anthropic.com` works the same way.
Switching that setup to Anthropic API mode keeps its key and model.

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

llama.cpp's `llama-server` serves the same model on NVIDIA, Apple Metal and
the CPU, from a GGUF quantization:

```bash
llama-server -hf ggml-org/Voxtral-Mini-4B-Realtime-2602-GGUF:Q8_0 \
  --host 127.0.0.1 --port 8093 -ngl 99 -np 1 -c 2048 --temp 0
```

Then set the Dictation server URL to `ws://127.0.0.1:8093/v1/realtime`; the
model name can be anything. It needs a llama.cpp build from 23 October 2026 or
later, with [#30994](https://github.com/ggml-org/llama.cpp/pull/30994). Keep `--temp 0`: llama-server transcribes at its
sampling temperature, 0.8 by default, and the same audio then gives different
text from one run to the next. The app sends 16 kHz audio, which is the rate
llama-server expects.

On an NVIDIA RTX 3090 with the Q8_0 GGUF, llama-server matched vLLM's BF16
model on the 146 recorded utterances of the dictation eval (22.15% and 22.20%
word error rate) and used about 6 GB of GPU memory against vLLM's 12 GB. The
final text arrived 0.15 s after the stop, against 0.41 s with vLLM.

Voxtral Realtime spends one token of context per 80 ms of audio, so one
session holds about 164 s at vLLM's default `--max-model-len 2048`, or with
2048 positions per llama-server slot (`-c` divided by `-np`). Past that
the transcript turns to garbage, and vLLM's engine can crash. The app reads the
limit from the server's `/v1/models` at the start of each dictation (2048 when
the model is listed without one) and, before the limit, finishes the session
and carries the dictation on in a fresh one. It picks a pause once the
session is 60% full and does it regardless at 85%. Nothing changes on
screen; a raised limit just moves the switch later.
