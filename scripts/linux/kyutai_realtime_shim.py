"""Serve Kyutai STT (kyutai/stt-1b-en_fr) behind the OpenAI Realtime subset
that RealtimeAPIWebSocketClient speaks, for Linux benches beside vLLM (#907).

    kyutai_realtime_shim.py [--port 8020] [--hf-repo kyutai/stt-1b-en_fr]

The model runs in process through Kyutai's `moshi` PyTorch package, because
the Rust moshi-server builds CUDA kernels with nvcc and the dev box has none.
One session at a time.

Protocol: `session.created` on connect. `session.update` takes `model` and,
for the biasing arm, `prompt_terms` (a list of strings).
`input_audio_buffer.append` takes base64 PCM16 mono 16 kHz.
`input_audio_buffer.commit` with `final: true` flushes the model's 0.5 s delay
and answers `transcription.done` with the whole text; a non-final commit is
ignored. Text goes out as `transcription.delta` as soon as the model writes it.

Text prompt arm: before the audio, the terms are forced into the model's text
stream over silent frames, each after a word-start marker, then a short
free-running gap. It is Kyutai's prompt example without the audio prompt. The forced
tokens are left out of the transcript.
"""

import argparse
import asyncio
import base64
import json
import logging
import math
import time

import numpy as np
import soxr
import torch
import websockets

import moshi.models

FRAME_RATE = 12.5
WORD_START = 0
PAD = 3
# Free-running silent frames between the prompt and the audio. Forcing pads
# there instead, or a longer gap, left some transcripts empty (#932).
PROMPT_GAP_FRAMES = 12

log = logging.getLogger("kyutai-shim")


class Engine:
    def __init__(self, hf_repo: str, lead_silence: float, device: str = "cuda"):
        info = moshi.models.loaders.CheckpointInfo.from_hf_repo(hf_repo)
        self.repo = hf_repo
        self.device = device
        self.mimi = info.get_mimi(device=device)
        self.tokenizer = info.get_text_tokenizer()
        lm = info.get_moshi(device=device, dtype=torch.bfloat16)
        # One frame more than the delay, so the last word's tokens land.
        self.flush_frames = math.ceil(info.stt_config.get("audio_delay_seconds", 0.5) * FRAME_RATE) + 1
        self.frame = self.mimi.frame_size
        self.lead_frames = round(lead_silence * FRAME_RATE)
        self.forced: list[int] = []
        self.gen = moshi.models.LMGen(lm, temp=0, temp_text=0.0, on_text_logits_hook=self._force)
        self.mimi.streaming_forever(1)
        self.gen.streaming_forever(1)
        self.silence = torch.zeros((1, 1, self.frame), dtype=torch.float32, device=device)
        # Capture the CUDA graphs now, so the first session's timing is honest.
        self.reset()
        for _ in range(20):
            self.step(self.silence)
        self.reset()

    def _force(self, logits: torch.Tensor) -> None:
        if not self.forced:
            return
        keep = torch.zeros_like(logits, dtype=torch.bool)
        keep[..., self.forced[0]] = True
        logits[:] = torch.where(keep, logits, float("-inf"))

    def reset(self) -> None:
        self.mimi.reset_streaming()
        self.gen.reset_streaming()
        self.forced = []

    def lead_in(self) -> None:
        for _ in range(self.lead_frames):
            self.step(self.silence)

    @torch.no_grad()
    def step(self, chunk: torch.Tensor) -> int:
        token = int(self.gen.step(self.mimi.encode(chunk))[0, 0, 0].item())
        if self.forced:
            self.forced.pop(0)
        return token

    def prompt(self, terms: list[str]) -> int:
        forced: list[int] = []
        for term in terms:
            forced += [WORD_START] + self.tokenizer.encode(term)
        self.forced = forced
        steps = len(forced) + PROMPT_GAP_FRAMES
        for _ in range(steps):
            self.step(self.silence)
        return steps


class Session:
    def __init__(self, engine: Engine):
        self.engine = engine
        self.resampler = soxr.ResampleStream(16000, 24000, 1, dtype="float32")
        self.pending = np.zeros(0, dtype=np.float32)
        self.tokens: list[int] = []
        self.sent = ""
        self.prompt_terms: list[str] = []
        self.started = False
        self.opened_at = time.monotonic()
        self.first_text_at: float | None = None
        self.audio_samples = 0

    def text(self) -> str:
        return self.engine.tokenizer.decode(self.tokens).strip()

    def feed(self, pcm16: bytes, final: bool = False) -> str:
        """Runs every whole frame received so far; returns the new text."""
        e = self.engine
        if not self.started:
            self.started = True
            e.reset()
            e.lead_in()
            if self.prompt_terms:
                steps = e.prompt(self.prompt_terms)
                log.info("prompt: %d terms, %d forced frames", len(self.prompt_terms), steps)
        x = np.frombuffer(pcm16, dtype=np.int16).astype(np.float32) / 32768.0
        self.audio_samples += len(x)
        self.pending = np.concatenate([self.pending, self.resampler.resample_chunk(x, last=final)])
        if final and len(self.pending) % e.frame:
            self.pending = np.pad(self.pending, (0, e.frame - len(self.pending) % e.frame))
        n = len(self.pending) // e.frame
        for i in range(n):
            chunk = torch.from_numpy(self.pending[i * e.frame : (i + 1) * e.frame]).to(e.device)
            self._take(e.step(chunk[None, None]))
        self.pending = self.pending[n * e.frame :]
        if final:
            for _ in range(e.flush_frames):
                self._take(e.step(e.silence))
        text = self.text()
        if not text.startswith(self.sent) or not text[len(self.sent) :].strip():
            return ""
        delta, self.sent = text[len(self.sent) :], text
        if self.first_text_at is None:
            self.first_text_at = time.monotonic()
        return delta

    def _take(self, token: int) -> None:
        if token > PAD:
            self.tokens.append(token)


async def handle(ws, engine: Engine, lock: asyncio.Lock) -> None:
    await ws.send(json.dumps({"type": "session.created", "session": {"model": engine.repo}}))
    async with lock:
        session = Session(engine)
        try:
            async for raw in ws:
                event = json.loads(raw)
                kind = event.get("type")
                if kind == "session.update":
                    terms = event.get("prompt_terms") or (event.get("session") or {}).get("prompt_terms")
                    session.prompt_terms = [str(t) for t in terms or []]
                    await ws.send(json.dumps({"type": "session.updated"}))
                elif kind == "input_audio_buffer.append":
                    delta = await asyncio.to_thread(session.feed, base64.b64decode(event["audio"]))
                    if delta:
                        await ws.send(json.dumps({"type": "transcription.delta", "delta": delta}))
                elif kind == "input_audio_buffer.commit" and event.get("final"):
                    delta = await asyncio.to_thread(session.feed, b"", True)
                    if delta:
                        await ws.send(json.dumps({"type": "transcription.delta", "delta": delta}))
                    text = session.text()
                    await ws.send(json.dumps({"type": "transcription.done", "text": text}))
                    first = session.first_text_at
                    log.info(
                        "done: audio %.2fs, first text %s, wall %.2fs, %d chars",
                        session.audio_samples / 16000,
                        f"{first - session.opened_at:.2f}s" if first else "none",
                        time.monotonic() - session.opened_at,
                        len(text),
                    )
                    session = Session(engine)
        except websockets.ConnectionClosed:
            pass
        except Exception as error:
            log.exception("session failed")
            try:
                await ws.send(json.dumps({"type": "error", "error": {"message": str(error)}}))
            except websockets.ConnectionClosed:
                pass


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8020)
    parser.add_argument("--hf-repo", default="kyutai/stt-1b-en_fr")
    parser.add_argument(
        "--lead-silence", type=float, default=1.0,
        help="seconds of silence run before each session's audio; with none the first word is often lost",
    )
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    engine = Engine(args.hf_repo, args.lead_silence)
    log.info("loaded %s, GPU peak %.2f GB", args.hf_repo, torch.cuda.max_memory_allocated() / 1e9)
    lock = asyncio.Lock()
    async with websockets.serve(lambda ws: handle(ws, engine, lock), args.host, args.port, max_size=None):
        log.info("listening on ws://%s:%d/v1/realtime", args.host, args.port)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
