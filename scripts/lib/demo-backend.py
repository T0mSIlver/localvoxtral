#!/usr/bin/env python3
"""The README demo's speech and polishing backend, scripted (#1847).

usage: demo-backend.py <port-file> <line-file>

Every request it answers is logged to <line-file>.log.

Binds 127.0.0.1 on port 0, writes the port to <port-file>, and serves the
app in External URL mode on that one port:

  ws  /v1/realtime          speech: streams the line record-demo.sh wrote to
                            <line-file> just before the dictation, word by
                            word at speaking pace, then sends it final when
                            the app commits at stop. A line starting with
                            "@<seconds> " waits that long first. The file is
                            emptied once read, so a dictation nobody scripted
                            hears nothing.
  POST /v1/chat/completions polishing: the dictation polish writes the
                            spoken code forms of the demo's lines as code and
                            echoes everything else.

The 8 GB Mac Mini runner cannot hold the bundled 4B speech and polish models
next to two Claude Code sessions: they ran from swap and timed out. The
owner chose a scripted backend for the demo; the agents, the app, and every
UI on screen stay real. The realtime protocol is the subset the app uses,
as in scripts/ci/fake-speech-service.py.
"""

import base64
import hashlib
import json
import re
import socket
import struct
import sys
import threading
import time

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
WORDS_PER_SECOND = 2.8
# Spoken forms the agent polish writes as code in the demo's lines.
REWRITES = [
    (r"\buse auth dot t s\b", "`useAuth.ts`"),
    (r"\bnpm test dash dash coverage\b", "`npm test --coverage`"),
    (r"\bdash dash coverage\b", "`--coverage`"),
    (r"\bread ?me\b", "README"),
]

# --- websocket framing ----------------------------------------------------------------

def read_exact(conn, count):
    data = b""
    while len(data) < count:
        chunk = conn.recv(count - len(data))
        if not chunk:
            raise ConnectionError("closed")
        data += chunk
    return data


def send_frame(conn, payload, opcode=0x1):
    header = bytearray([0x80 | opcode])
    if len(payload) < 126:
        header.append(len(payload))
    elif len(payload) < 1 << 16:
        header.append(126)
        header += struct.pack("!H", len(payload))
    else:
        header.append(127)
        header += struct.pack("!Q", len(payload))
    conn.sendall(bytes(header) + payload)


def receive_frame(conn):
    first, second = read_exact(conn, 2)
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", read_exact(conn, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read_exact(conn, 8))[0]
    mask = read_exact(conn, 4) if second & 0x80 else b"\0\0\0\0"
    payload = bytes(b ^ mask[i % 4] for i, b in enumerate(read_exact(conn, length)))
    return first & 0x0F, payload


# --- speech ---------------------------------------------------------------------------

class SpeechSession:
    def __init__(self, conn, line_file):
        self.conn = conn
        self.line_file = line_file
        self.lock = threading.Lock()
        self.words = []
        self.sent = 0
        self.done_upto = 0
        self.started = False
        self.finished = False

    def send(self, event):
        with self.lock:
            send_frame(self.conn, json.dumps(event).encode())

    def take_line(self):
        try:
            with open(self.line_file) as f:
                line = f.read().strip()
            open(self.line_file, "w").close()
            return line
        except OSError:
            return ""

    def stream(self, delay):
        time.sleep(delay)
        while True:
            with self.lock:
                if self.finished or self.sent >= len(self.words):
                    return
                word = self.words[self.sent]
                self.sent += 1
                send_frame(self.conn, json.dumps(
                    {"type": "transcription.delta", "delta": (" " if self.sent > 1 else "") + word}).encode())
                # A clause ends a segment, as speech pauses end one for a
                # real server: Live Auto-Paste with spoken send types each
                # segment once it is final. The last clause stays for the
                # stop's final, the only one a spoken "send it" acts on.
                if word[-1] in ",.?!" and self.sent < len(self.words):
                    self._send_segment()
            time.sleep(1 / WORDS_PER_SECOND)

    def start(self):
        self.started = True
        line = self.take_line()
        log(f"speech: {line!r}")
        delay = 0.0
        match = re.match(r"@([0-9.]+)\s+(.*)", line, flags=re.DOTALL)
        if match:
            delay, line = float(match.group(1)), match.group(2)
        self.words = line.split()
        threading.Thread(target=self.stream, args=(delay,), daemon=True).start()

    def _send_segment(self):
        """Finalizes the words streamed since the last segment. Caller holds the lock."""
        if self.sent > self.done_upto:
            send_frame(self.conn, json.dumps(
                {"type": "transcription.done", "text": " ".join(self.words[self.done_upto:self.sent])}).encode())
            self.done_upto = self.sent

    def finish(self):
        with self.lock:
            self.finished = True
            rest = self.words[self.sent:]
            if rest:
                send_frame(self.conn, json.dumps(
                    {"type": "transcription.delta", "delta": (" " if self.sent else "") + " ".join(rest)}).encode())
            self.sent = len(self.words)
            send_frame(self.conn, json.dumps(
                {"type": "transcription.done", "text": " ".join(self.words[self.done_upto:])}).encode())
            self.done_upto = self.sent

    def run(self):
        self.send({"type": "session.created", "session": {}})
        while True:
            opcode, payload = receive_frame(self.conn)
            if opcode == 0x8:
                return
            if opcode == 0x9:
                with self.lock:
                    send_frame(self.conn, payload, opcode=0xA)
                continue
            if opcode != 0x1:
                continue
            event = json.loads(payload)
            kind = event.get("type")
            if kind == "session.update":
                self.send({"type": "session.updated", "session": {}})
            elif kind == "input_audio_buffer.append" and not self.started:
                self.start()
            elif kind == "input_audio_buffer.commit":
                log(f"commit final={event.get('final')} sent={self.sent} done_upto={self.done_upto}")
            if kind == "input_audio_buffer.commit" and event.get("final"):
                if not self.started:
                    self.start()
                self.finish()


# --- polishing ------------------------------------------------------------------------

def polish(text):
    for pattern, replacement in REWRITES:
        text = re.sub(pattern, replacement, text, flags=re.IGNORECASE)
    return text


LOG = None


def log(line):
    if LOG:
        with open(LOG, "a") as f:
            f.write(time.strftime("%H:%M:%S ") + line + "\n")


def complete(body):
    messages = body.get("messages", [])
    system = next((m.get("content", "") for m in messages if m.get("role") == "system"), "")
    last = messages[-1].get("content", "") if messages else ""
    if isinstance(last, list):
        last = "".join(part.get("text", "") for part in last if isinstance(part, dict))
    if len(messages) == 1 and str(last).startswith("You are given many short texts"):
        answer = "[]"
    elif "Working text:\n" in last:
        answer = polish(last.rsplit("Working text:\n", 1)[1].strip())
    else:
        answer = "Ready."
    log(f"chat: {system[:40]!r} -> {answer[:160]!r}")
    return {
        "id": "demo",
        "object": "chat.completion",
        "model": body.get("model", "demo"),
        "choices": [{"index": 0, "message": {"role": "assistant", "content": answer}, "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0},
    }


# --- server ---------------------------------------------------------------------------

def read_request(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            raise ConnectionError("closed")
        data += chunk
    head, rest = data.split(b"\r\n\r\n", 1)
    lines = head.decode("latin-1").split("\r\n")
    method, path = lines[0].split(" ")[:2]
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            key, value = line.split(":", 1)
            headers[key.strip().lower()] = value.strip()
    length = int(headers.get("content-length", "0") or 0)
    while len(rest) < length:
        rest += conn.recv(length - len(rest))
    return method, path, headers, rest


def respond(conn, status, payload):
    body = json.dumps(payload).encode()
    conn.sendall(
        f"HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\n"
        "Connection: close\r\n\r\n".encode() + body)


def handle(conn, line_file):
    try:
        method, path, headers, body = read_request(conn)
        if headers.get("upgrade", "").lower() == "websocket":
            accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + GUID).encode()).digest()).decode()
            conn.sendall(
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {accept}\r\n\r\n".encode())
            SpeechSession(conn, line_file).run()
        elif method == "POST" and path.rstrip("/").endswith("/chat/completions"):
            respond(conn, "200 OK", complete(json.loads(body or b"{}")))
        else:
            respond(conn, "404 Not Found", {"error": "not served by the demo backend"})
    except (ConnectionError, OSError, ValueError):
        pass
    finally:
        conn.close()


def main(argv):
    if len(argv) != 3:
        sys.exit(__doc__)
    global LOG
    port_file, line_file = argv[1], argv[2]
    LOG = line_file + ".log"
    open(line_file, "w").close()
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(16)
    with open(port_file, "w") as f:
        f.write(str(server.getsockname()[1]))
    while True:
        conn, _ = server.accept()
        threading.Thread(target=handle, args=(conn, line_file), daemon=True).start()


if __name__ == "__main__":
    main(sys.argv)
