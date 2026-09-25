#!/usr/bin/env python3
"""Time how far the speech service lags, without the app in the path.

    speech-service-probe.py <ws-endpoint> <model> <wav> <silence-seconds>

e2e-dictation.sh runs this to tell a slow service from a broken app (#548).
It plays the scenario's WAV to the service the way the dogfood app does: the
audio is produced at real time from the moment the socket opens, held until
`session.created`, sent in 100 ms chunks, followed by the same seconds of
silence the check leaves before its stop, then a final commit. The lag is the
time from the end of the speech to the final transcript. The app waits at
least that silence plus its finalization's minimum open time for the final
transcript, so a lag past that sum means a correct app can lose words.

Prints one line, `lag=<s> created=<s> audio=<s> text=<final transcript>`, and
exits 0. Exits 2 with a reason on stderr when nothing could be measured
(refused connection, handshake, protocol error, no answer within the timeout).
Standard library only: it runs on the Mac runner's stock python3.
"""

import base64
import json
import os
import socket
import ssl
import struct
import sys
import threading
import time
import wave
from urllib.parse import urlsplit

CHUNK_SECONDS = 0.1  # TimingConstants.audioSendInterval
SAMPLE_RATE = 16000
TIMEOUT_SECONDS = float(os.environ.get("LV_E2E_PROBE_TIMEOUT", "60"))
DONE_TYPES = (
    "transcription.done",
    "response.audio_transcript.done",
    "conversation.item.input_audio_transcription.completed",
)


def fail(reason):
    sys.stderr.write("probe: %s\n" % reason)
    sys.exit(2)


class Socket:
    """A minimal RFC 6455 client: masked text frames out, text frames in."""

    def __init__(self, url, timeout):
        parts = urlsplit(url)
        secure = parts.scheme == "wss"
        port = parts.port or (443 if secure else 80)
        raw = socket.create_connection((parts.hostname, port), timeout=timeout)
        if secure:
            raw = ssl.create_default_context().wrap_socket(raw, server_hostname=parts.hostname)
        self.sock = raw
        self.send_lock = threading.Lock()
        key = base64.b64encode(os.urandom(16)).decode()
        path = parts.path or "/"
        if parts.query:
            path += "?" + parts.query
        request = (
            "GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n" % (path, parts.hostname, port, key)
        )
        self.sock.sendall(request.encode())
        head = b""
        while b"\r\n\r\n" not in head:
            data = self.sock.recv(4096)
            if not data:
                raise ConnectionError("closed during the handshake")
            head += data
        head, self.buffer = head.split(b"\r\n\r\n", 1)
        status = head.split(b"\r\n", 1)[0]
        if b" 101 " not in status + b" ":
            raise ConnectionError("handshake answered %r" % status.decode(errors="replace"))

    def send_text(self, text):
        payload = text.encode()
        header = bytearray([0x81])
        if len(payload) < 126:
            header.append(0x80 | len(payload))
        elif len(payload) < 1 << 16:
            header.append(0x80 | 126)
            header += struct.pack("!H", len(payload))
        else:
            header.append(0x80 | 127)
            header += struct.pack("!Q", len(payload))
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        with self.send_lock:
            self.sock.sendall(bytes(header) + mask + masked)

    def _read(self, count):
        while len(self.buffer) < count:
            data = self.sock.recv(65536)
            if not data:
                raise ConnectionError("the service closed the socket")
            self.buffer += data
        out, self.buffer = self.buffer[:count], self.buffer[count:]
        return out

    def receive_text(self):
        """The next text message; answers pings, skips other control frames."""
        message = b""
        while True:
            first, second = self._read(2)
            opcode, length = first & 0x0F, second & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._read(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._read(8))[0]
            mask = self._read(4) if second & 0x80 else None
            payload = self._read(length)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x8:
                raise ConnectionError("the service closed the socket")
            if opcode == 0x9:
                with self.send_lock:
                    self.sock.sendall(self._pong(payload))
                continue
            if opcode in (0x1, 0x0):
                message += payload
                if first & 0x80:
                    return message.decode()

    @staticmethod
    def _pong(payload):
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return bytes([0x8A, 0x80 | len(payload)]) + mask + masked


def main():
    if len(sys.argv) != 5:
        fail("usage: speech-service-probe.py <ws-endpoint> <model> <wav> <silence-seconds>")
    endpoint, model, wav_path, silence = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])

    with wave.open(wav_path, "rb") as wav:
        if (wav.getframerate(), wav.getnchannels(), wav.getsampwidth()) != (SAMPLE_RATE, 1, 2):
            fail("%s is not 16 kHz mono PCM16" % wav_path)
        pcm = wav.readframes(wav.getnframes())
    speech_seconds = len(pcm) / (2.0 * SAMPLE_RATE)
    pcm += b"\x00\x00" * int(silence * SAMPLE_RATE)
    chunk_bytes = int(CHUNK_SECONDS * SAMPLE_RATE) * 2
    chunks = [pcm[i:i + chunk_bytes] for i in range(0, len(pcm), chunk_bytes)]

    try:
        ws = Socket(endpoint, TIMEOUT_SECONDS)
    except (OSError, ConnectionError) as error:
        fail("could not open %s: %s" % (endpoint, error))
    opened = time.monotonic()
    ws.sock.settimeout(TIMEOUT_SECONDS)

    created = threading.Event()
    result = {}

    def reader():
        try:
            while True:
                event = json.loads(ws.receive_text())
                kind = event.get("type", "")
                if kind == "session.created":
                    result["created"] = time.monotonic()
                    created.set()
                elif kind in DONE_TYPES:
                    result["done"] = time.monotonic()
                    result["text"] = event.get("text") or event.get("transcript") or ""
                    break
                elif kind == "error":
                    result["error"] = event.get("message") or json.dumps(event)
                    break
        except (OSError, ConnectionError, ValueError) as error:
            result["error"] = str(error)
        created.set()

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()

    if not created.wait(TIMEOUT_SECONDS) or "created" not in result:
        fail("no session.created within %.0f s: %s" % (TIMEOUT_SECONDS, result.get("error", "timeout")))
    ws.send_text(json.dumps({"type": "session.update", "model": model}))

    # Chunk i exists at opened + i * CHUNK_SECONDS, like audio a microphone
    # captured while the session was being set up; send whatever is due.
    for index, chunk in enumerate(chunks):
        due = opened + index * CHUNK_SECONDS
        delay = due - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        if "error" in result:
            fail("the service reported an error while audio was streaming: %s" % result["error"])
        ws.send_text(json.dumps({
            "type": "input_audio_buffer.append",
            "audio": base64.b64encode(chunk).decode(),
        }))
    ws.send_text(json.dumps({"type": "input_audio_buffer.commit", "final": True}))

    speech_end = opened + speech_seconds
    thread.join(max(0.0, speech_end + silence + TIMEOUT_SECONDS - time.monotonic()))
    if "done" not in result:
        fail("no final transcript within %.0f s of the final commit: %s"
             % (TIMEOUT_SECONDS, result.get("error", "timeout")))
    print("lag=%.2f created=%.2f audio=%.2f text=%s" % (
        result["done"] - speech_end,
        result["created"] - opened,
        speech_seconds,
        " ".join(result["text"].split()),
    ))


if __name__ == "__main__":
    main()
