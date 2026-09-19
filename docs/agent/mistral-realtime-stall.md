# Mistral realtime stalls: open bug hunt

Status on 2026-09-19: symptom A (the one the owner hits) is not reproduced and has no request ID yet. Symptom B is reproduced on demand and ready to report to Mistral once confirmed. Owner rulings: no second parallel connection (it doubles the bill for Mistral's bug), and no silence-padding workaround (it may move the trigger instead of removing it).

## Symptoms

**A. Text stops mid-dictation and never resumes.** Overlay Buffer mode, Mistral API engine. Deltas arrive normally, then stop while the user keeps talking. After stop, no `transcription.done` arrives, the client closes on the finalization idle rule 1.6 s later, and the partial text is inserted. A new dictation always works. One occurrence in ~40 dictations on 2026-09-19 (session opened 15:56:20 local, last delta at 35 s, no request ID because it predates the logging).

**B. No text for the first ~31 s, then that speech is dropped.** Reproduced with the official `mistralai` Python SDK and with our client. See the report below.

**C. Final transcript ends a few seconds before stop (unconfirmed).** 2026-09-19 18:02 local, request `ws-01a0ba66-7883-715a-8f40-ef655f99cf44`: the last delta ("and") came 2.7 s before stop, and `transcription.done` (0.29 s after `input_audio.end`) ended on the same word. The polish model then appended "...". Audio went out until the stop, but that build did not log its loudness, so it is unknown whether the owner was still talking. In clean tests Mistral emits each word within ~0.1 s and `done` includes the last word before the end, so loud audio in that gap means Mistral dropped speech.

## What the app logs now (notice level, kept by macOS)

- `mistral realtime session ready request_id=ws-...`
- `mistral realtime server silent: no server event for 5.0s; ... (loudest -NN dBFS); N sends awaiting completion; last ping answered|unanswered for Xs; request_id=...`. Sends piling up or an unanswered ping point to the network, and completed sends with an answered ping point to Mistral.
- `mistral realtime server resumed after Xs of silence`
- `mistral realtime final commit: flush + end; Xs of audio since the last server event (loudest -NN dBFS), ...`. Speech reads around -40 to -20 dBFS and a quiet room below -50. This line settles symptom C.
- `mistral realtime closing before transcription.done: ...` is symptom A at stop.

## Reading the owner's Mac log

The build account cannot read the unified log (`remote-build.sh applog` fails), so use the herdr bridge (`~/bin/mac-herdr`, see the `mac-herdr-socket-bridge` memory). Open a plain shell tab with `tab create --workspace <ws> --cwd /Users/tom --no-focus`, then use `pane run` for `log show --last 30m --info --debug --predicate 'subsystem == "com.localvoxtral" AND process == "localvoxtral"'` into a file and `scp` it to `sandbox-vpn:<path>`. Info-level lines, including every `partial delta`, are purged within minutes to hours; notice lines survive.

To find a failed dictation, look for a `connect` without a later `transcription.done`. A disconnect preceded by `Escape consumed during active dictation` is the owner cancelling.

## Tools

- `MistralRealtimeSoakTests`: real-time-paced sessions of real speech through our client. It needs `.mistral-soak-enable.json` (`{"apiKey","sessions","concurrency","seconds"}`, mode 0600) and 16 kHz mono s16le speech at `local-notes/mistral-soak/soak.pcm`. Run it with `./scripts/remote-build.sh exec swift test --filter MistralRealtimeSoakTests` and delete the marker afterwards. It costs 0.006 USD per minute of audio.
- The speech used so far is LibriVox, *William Again* chapter 1 (`https://archive.org/download/williamagain_1902_librivox/williamagain_01_crompton_64kb.mp3`), converted with `ffmpeg -i in.mp3 -ac 1 -ar 16000 -f s16le out.pcm`.
- `repro.py` inside the report below reproduces symptom B with the official SDK.

## Next steps

1. When the owner hits A or C on a build with this logging, read the lines above for that request ID.
2. Try to reproduce A: soak sessions of 2 minutes or more (the owner's real dictation length), and the owner's own recordings if available.
3. Confirm B again (it was clean twice at 14:56 UTC and stalled 7 times after), then send the report to Mistral.

---

# Report for Mistral (draft, not sent)

**Model:** `voxtral-mini-transcribe-realtime-2602`
**Endpoint:** `wss://api.mistral.ai/v1/audio/transcriptions/realtime`
**Client:** `mistralai` 2.10.1 Python SDK (`client.audio.realtime.transcribe_stream`), default `target_streaming_delay_ms`. Our own Swift WebSocket client gives the same result.

### Summary

We see two symptoms. We do not know whether they share a cause.

- **A, not reproduced (the one we hit in our app).** A live dictation receives deltas normally, then stops receiving them partway through. Nothing arrives afterwards, not even `transcription.done` after `input_audio.end`.
- **B, reproduced.** Deltas are missing for the first ~31 s of a session, then resume, and `transcription.done` drops the first ~30 s of speech.

### Symptom A: deltas stop mid-session and never resume

A live microphone dictation on 2026-09-19 opened at 13:56:20 UTC and received deltas normally until 13:56:55 (35 s in). The user kept talking for another 16 s and received no deltas. The client then sent `input_audio.flush` and `input_audio.end`. No `transcription.done` arrived within 1.6 s, after which the client closed the socket; clean sessions answer in 0.25 to 0.6 s. The server sent no error or close frame. Our client did not log the request ID for that session; it does now. The user has hit this several times, and starting a new session always works.

### Symptom B: no deltas for the first ~31 s, then that audio is dropped

For some audio, a realtime session sends no `transcription.text.delta` for the first ~31 s while speech is streaming in at real-time pace. Deltas then resume. `transcription.done` arrives on time after `input_audio.end`, but its text is missing the speech from those first ~30 s. The session reports no error, and the socket stays open.

#### Reproduction

The audio is public domain: chapter 1 of *William Again*, read for LibriVox. Stream the 60 s starting at 1410 s (16 kHz mono `pcm_s16le`, 100 ms chunks, real-time pace):

| start of the 60 s clip | sessions | first delta | `transcription.done` length |
|---|---|---|---|
| 1410 s | 7 of 9 | 31.3 s | 476 chars (first half missing) |
| 1410 s | 2 of 9 | under 3 s | 868 chars |
| 1411 s | 3 of 3 | 1.7 to 2.0 s | 880 chars |

Across 50 one-minute sessions over 25 different clips from the same chapter, 1410 s is the only clip that stalled. Clean sessions get their first delta within ~2 s. Their longest gap between deltas is under 3 s, and `transcription.done` arrives 0.25 to 0.6 s after `input_audio.end`.

The output is otherwise near-deterministic: two different clients streaming the same clip get the same transcript length and the same 31.28 s gap. The two clean runs of the 1410 s clip, one per client, both came around 14:56 UTC, before every stalled run. That suggests the trigger also depends on something on your side.

`repro.py` (below) downloads the audio, converts it, and runs the sessions. It needs ffmpeg and `MISTRAL_API_KEY`:

```
$ python repro.py 1410 2
ws-01a0ba44-f70b-725c-8cba-2de6a981f83f  first delta at 31.3s  done: 476 chars
  william's father entered the house hastily surely the meeting isn't over dear said william's mother he hasn't come said ...
ws-01a0ba44-f723-7223-af43-c6f27f368d0a  first delta at 31.3s  done: 476 chars
  william's father entered the house hastily surely the meeting isn't over dear said william's mother he hasn't come said ...
$ python repro.py 1411 1
ws-01a0ba45-e6e5-7390-a77e-ff3be5973391  first delta at 1.7s  done: 880 chars
  yelled the heroine in shrill triumph shut up retorted william now you come on to the hero let's do the best as quick as ...
```

#### Request IDs (2026-09-19)

Stalled, clip at 1410 s:

- `ws-01a0ba31-7470-74d0-af0e-14f57e963817` (15:03:18 UTC)
- `ws-01a0ba35-e0bc-77c0-a8f5-faf9c1d20d6f`, `ws-01a0ba35-e0dc-7364-97d7-5e45e100b1e8`, `ws-01a0ba35-e148-750a-a30c-ec0087e56ae6` (15:08:08 UTC)
- `ws-01a0ba44-f70b-725c-8cba-2de6a981f83f`, `ws-01a0ba44-f723-7223-af43-c6f27f368d0a` (15:24:37 UTC)

Clean, for comparison:

- `ws-01a0ba2a-e30e-7392-845b-8c1d72321306`: same 1410 s clip (14:56:07 UTC; the Swift client's clean run minutes later logged no request ID)
- `ws-01a0ba45-e6e5-7390-a77e-ff3be5973391`: clip at 1411 s (15:25:38 UTC)

### Expected

Deltas for all streamed speech, and a `transcription.done` for every `input_audio.end`, covering the whole audio. If the server cannot transcribe a stretch, an `error` event, so the client can react.

### repro.py

```python
"""Repro: voxtral-mini-transcribe-realtime-2602 emits nothing for ~31 s at the
start of a session, then drops that audio from transcription.done.

Needs ffmpeg, `pip install "mistralai[realtime]"`, and MISTRAL_API_KEY.
Usage: python repro.py [start_seconds=1410] [sessions=3]
"""
import asyncio, os, subprocess, sys, time, urllib.request

from mistralai.client import Mistral
from mistralai.client.models import (AudioFormat, RealtimeTranscriptionSessionCreated,
    TranscriptionStreamDone, TranscriptionStreamTextDelta)

URL = ("https://archive.org/download/williamagain_1902_librivox/"
       "williamagain_01_crompton_64kb.mp3")  # public domain LibriVox reading
START = int(sys.argv[1]) if len(sys.argv) > 1 else 1410
SESSIONS = int(sys.argv[2]) if len(sys.argv) > 2 else 3
MODEL = "voxtral-mini-transcribe-realtime-2602"

if not os.path.exists("chapter1.pcm"):
    urllib.request.urlretrieve(URL, "chapter1.mp3")
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", "chapter1.mp3",
                    "-ac", "1", "-ar", "16000", "-f", "s16le", "chapter1.pcm"], check=True)
pcm = open("chapter1.pcm", "rb").read()
audio = pcm[START * 32000:(START + 60) * 32000]  # 60 s, 16 kHz mono s16le

client = Mistral(api_key=os.environ["MISTRAL_API_KEY"])


async def one():
    t0 = time.monotonic()
    request_id, first_delta, text = None, None, ""

    async def stream():  # real-time pace, 100 ms chunks
        for n, pos in enumerate(range(0, len(audio), 3200)):
            await asyncio.sleep(max(0, t0 + n * 0.1 - time.monotonic()))
            yield audio[pos:pos + 3200]

    async for ev in client.audio.realtime.transcribe_stream(
            audio_stream=stream(), model=MODEL,
            audio_format=AudioFormat(encoding="pcm_s16le", sample_rate=16000)):
        if isinstance(ev, RealtimeTranscriptionSessionCreated):
            request_id = ev.session.request_id
        elif isinstance(ev, TranscriptionStreamTextDelta) and first_delta is None:
            first_delta = time.monotonic() - t0
        elif isinstance(ev, TranscriptionStreamDone):
            text = ev.text or ""
    print(f"{request_id}  first delta at {first_delta:.1f}s  done: {len(text)} chars")
    print(f"  {text[:120]}...")


async def main():
    await asyncio.gather(*(one() for _ in range(SESSIONS)))

asyncio.run(main())
```
