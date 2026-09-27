"""Stream a term-recall recording set through a /v1/realtime endpoint.

    realtime_term_bench.py --url ws://127.0.0.1:8020/v1/realtime --model NAME \\
        --out EvalRecordings/term-recall/<run>.jsonl [--paced] [--prompt-terms] \\
        [--cases EvalRecordings/term-recall/cases.json] \\
        [--recordings EvalRecordings/term-recall/say-samantha-thomas] [--limit N]

Writes {"id", "text"} rows to --out, which TermRecallEvalTests scores in
hypotheses mode, and prints aggregate timing by language to stderr.

--paced sends 100 ms chunks at 1x on a fixed schedule and times the first
text: when the first non-empty delta arrives, minus when the recording's
speech starts (first 20 ms window above -40 dBFS). --prompt-terms sends the
case's sessionTerms as `prompt_terms` in session.update, which only
kyutai_realtime_shim.py reads.

Works against vLLM (scripts/linux/voxtral-vllm.sh) and the Kyutai shim. The
output holds transcripts: keep it under the gitignored EvalRecordings/.
"""

import argparse
import asyncio
import base64
import json
import statistics
import sys
import time
import wave
from pathlib import Path

import numpy as np
import websockets

CHUNK_SAMPLES = 1600  # 100 ms at 16 kHz
ONSET_WINDOW = 320  # 20 ms
ONSET_RMS = 0.01  # -40 dBFS


def read_pcm(path: Path) -> bytes:
    with wave.open(str(path)) as w:
        if (w.getframerate(), w.getnchannels(), w.getsampwidth()) != (16000, 1, 2):
            raise ValueError(f"{path}: want PCM16 mono 16 kHz")
        return w.readframes(w.getnframes())


def speech_onset(pcm: bytes) -> float:
    x = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
    for i in range(0, len(x) - ONSET_WINDOW, ONSET_WINDOW):
        if np.sqrt(np.mean(x[i : i + ONSET_WINDOW] ** 2)) > ONSET_RMS:
            return i / 16000
    return 0.0


async def run_case(url: str, model: str, pcm: bytes, paced: bool, terms: list[str] | None) -> dict:
    step = CHUNK_SAMPLES * 2
    first_delta = None
    async with websockets.connect(url, max_size=None) as ws:
        created = json.loads(await ws.recv())
        if created.get("type") != "session.created":
            raise RuntimeError(f"unexpected first event: {created}")
        update = {"type": "session.update", "model": model}
        if terms:
            update["prompt_terms"] = terms
        await ws.send(json.dumps(update))
        await ws.send(json.dumps({"type": "input_audio_buffer.commit"}))

        async def reader() -> str:
            nonlocal first_delta
            while True:
                event = json.loads(await ws.recv())
                if event["type"] == "transcription.delta" and event.get("delta", "").strip():
                    if first_delta is None:
                        first_delta = time.monotonic()
                elif event["type"] == "transcription.done":
                    return event["text"].strip()
                elif event["type"] == "error":
                    raise RuntimeError(str(event))

        read = asyncio.create_task(reader())
        started = time.monotonic()
        for n, i in enumerate(range(0, len(pcm), step)):
            if paced:
                await asyncio.sleep(max(0.0, started + n * CHUNK_SAMPLES / 16000 - time.monotonic()))
            chunk = base64.b64encode(pcm[i : i + step]).decode()
            await ws.send(json.dumps({"type": "input_audio_buffer.append", "audio": chunk}))
        await ws.send(json.dumps({"type": "input_audio_buffer.commit", "final": True}))
        text = await asyncio.wait_for(read, timeout=120)
        done = time.monotonic()
    return {
        "text": text,
        "first_text": None if first_delta is None else first_delta - started,
        "after_last_audio": done - started - len(pcm) / 32000 if paced else None,
    }


def summary(values: list[float]) -> str:
    if not values:
        return "n=0"
    v = sorted(values)
    p90 = v[min(len(v) - 1, int(0.9 * len(v)))]
    return f"n={len(v)} median={statistics.median(v):.2f}s p90={p90:.2f}s"


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--cases", type=Path, default=Path("EvalRecordings/term-recall/cases.json"))
    parser.add_argument(
        "--recordings", type=Path, default=Path("EvalRecordings/term-recall/say-samantha-thomas")
    )
    parser.add_argument("--paced", action="store_true")
    parser.add_argument("--prompt-terms", action="store_true")
    parser.add_argument("--limit", type=int, help="first N cases per language")
    args = parser.parse_args()

    case_file = json.loads(args.cases.read_text())
    manifest = json.loads((args.recordings / "manifest.json").read_text())
    files = {r["id"]: args.recordings / r["file"] for r in manifest["recordings"]}
    cases = [c for c in case_file["cases"] if c["id"] in files]
    if args.limit:
        cases = [c for c in cases if c["language"] == "en"][: args.limit] + [
            c for c in cases if c["language"] == "fr"
        ][: args.limit]
    print(f"cases={len(cases)} paced={args.paced} prompt={args.prompt_terms}", file=sys.stderr)

    latency: dict[str, list[float]] = {"en": [], "fr": []}
    tail: dict[str, list[float]] = {"en": [], "fr": []}
    no_text = 0
    with args.out.open("w") as out:
        for n, case in enumerate(cases, 1):
            pcm = read_pcm(files[case["id"]])
            terms = case["sessionTerms"] if args.prompt_terms else None
            result = await run_case(args.url, args.model, pcm, args.paced, terms)
            out.write(json.dumps({"id": case["id"], "text": result["text"]}) + "\n")
            out.flush()
            if args.paced:
                if result["first_text"] is None:
                    no_text += 1
                else:
                    latency[case["language"]].append(result["first_text"] - speech_onset(pcm))
                tail[case["language"]].append(result["after_last_audio"])
            if n % 20 == 0:
                print(f"{n}/{len(cases)}", file=sys.stderr, flush=True)
    if args.paced:
        for lang in ("en", "fr"):
            print(f"{lang} first text after speech onset: {summary(latency[lang])}", file=sys.stderr)
            print(f"{lang} done after last audio sent: {summary(tail[lang])}", file=sys.stderr)
        print(f"cases with no delta before done: {no_text}", file=sys.stderr)


if __name__ == "__main__":
    asyncio.run(main())
