"""Transcribe audio files through a vLLM /v1/realtime endpoint.

    vllm_transcribe.py [--url ws://127.0.0.1:8000/v1/realtime] [--realtime] FILE...

Prints one JSON line per file: {"file", "text", "seconds", "audio_seconds",
"first_text_seconds", "stop_tail_seconds"}. --realtime paces the audio at 1x
instead of sending it all at once; the two latencies mean something only then:
the first is from the first audio sent to the first text, the second from the
last audio sent to the final transcript.
"""

import argparse
import asyncio
import base64
import json
import sys
import time

import numpy as np
import websockets
from vllm.multimodal.media.audio import load_audio

CHUNK_SAMPLES = 1600  # 100 ms at 16 kHz


async def transcribe(url: str, model: str, path: str, realtime: bool) -> dict:
    audio, _ = load_audio(path, sr=16000, mono=True)
    pcm = (np.clip(audio, -1, 1) * 32767).astype(np.int16).tobytes()
    step = CHUNK_SAMPLES * 2
    started = time.monotonic()
    async with websockets.connect(url, max_size=None) as ws:
        created = json.loads(await ws.recv())
        if created.get("type") != "session.created":
            raise RuntimeError(f"unexpected first event: {created}")
        await ws.send(json.dumps({"type": "session.update", "model": model}))
        await ws.send(json.dumps({"type": "input_audio_buffer.commit"}))

        # Read while sending: at 1x the deltas must be timed as they arrive.
        async def read_until_done() -> tuple[dict, float | None]:
            first_text = None
            while True:
                event = json.loads(await ws.recv())
                if event["type"] == "transcription.delta" and first_text is None and event.get("delta", "").strip():
                    first_text = time.monotonic()
                elif event["type"] == "transcription.done":
                    return event, first_text
                elif event["type"] == "error":
                    raise RuntimeError(f"{path}: {event}")

        reader = asyncio.create_task(read_until_done())
        audio_started = time.monotonic()
        for i in range(0, len(pcm), step):
            chunk = base64.b64encode(pcm[i : i + step]).decode()
            await ws.send(json.dumps({"type": "input_audio_buffer.append", "audio": chunk}))
            if realtime:
                await asyncio.sleep(0.1)
        audio_ended = time.monotonic()
        await ws.send(json.dumps({"type": "input_audio_buffer.commit", "final": True}))
        done, first_text = await reader
        finished = time.monotonic()
        return {
            "file": path,
            "text": done["text"].strip(),
            "seconds": round(finished - started, 2),
            "audio_seconds": round(len(audio) / 16000, 2),
            "first_text_seconds": None if first_text is None else round(first_text - audio_started, 2),
            "stop_tail_seconds": round(finished - audio_ended, 2),
        }


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="ws://127.0.0.1:8000/v1/realtime")
    parser.add_argument("--model", default="mistralai/Voxtral-Mini-4B-Realtime-2602")
    parser.add_argument("--realtime", action="store_true")
    parser.add_argument("files", nargs="+")
    args = parser.parse_args()
    for path in args.files:
        print(json.dumps(await transcribe(args.url, args.model, path, args.realtime)), flush=True)


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
