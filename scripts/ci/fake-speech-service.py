#!/usr/bin/env python3
"""A realtime speech service that answers late on purpose, for the probe tests.

    fake-speech-service.py <port-file> <lag-seconds> [error]

Binds 127.0.0.1 on port 0 and writes the port to <port-file>. Speaks the
subset of the protocol speechd does: session.created on connect,
session.updated, one delta per second of audio, and on the final commit a
`response.audio_transcript.done` sent <lag-seconds> later. `error` answers the
first audio chunk with an error frame instead.
"""

import base64
import hashlib
import json
import socket
import struct
import sys
import threading
import time

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def read_exact(conn, count):
    data = b""
    while len(data) < count:
        chunk = conn.recv(count - len(data))
        if not chunk:
            raise ConnectionError("closed")
        data += chunk
    return data


def send_text(conn, text):
    payload = text.encode()
    header = bytearray([0x81])
    if len(payload) < 126:
        header.append(len(payload))
    elif len(payload) < 1 << 16:
        header.append(126)
        header += struct.pack("!H", len(payload))
    else:
        header.append(127)
        header += struct.pack("!Q", len(payload))
    conn.sendall(bytes(header) + payload)


def receive(conn):
    first, second = read_exact(conn, 2)
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", read_exact(conn, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read_exact(conn, 8))[0]
    mask = read_exact(conn, 4)
    payload = bytes(b ^ mask[i % 4] for i, b in enumerate(read_exact(conn, length)))
    return first & 0x0F, payload


def serve(conn, lag, error):
    head = b""
    while b"\r\n\r\n" not in head:
        head += conn.recv(4096)
    key = [line.split(b":", 1)[1].strip() for line in head.split(b"\r\n")
           if line.lower().startswith(b"sec-websocket-key:")][0]
    accept = base64.b64encode(hashlib.sha1(key + GUID.encode()).digest()).decode()
    conn.sendall((
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
        "Connection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % accept
    ).encode())
    send_text(conn, json.dumps({"type": "session.created"}))
    audio_bytes, words = 0, []
    while True:
        opcode, payload = receive(conn)
        if opcode == 0x8:
            return
        if opcode != 0x1:
            continue
        event = json.loads(payload)
        kind = event.get("type")
        if kind == "session.update":
            send_text(conn, json.dumps({"type": "session.updated"}))
        elif kind == "input_audio_buffer.append":
            if error:
                send_text(conn, json.dumps({"type": "error", "message": "engine failed"}))
                continue
            audio_bytes += len(base64.b64decode(event["audio"]))
            while audio_bytes >= (len(words) + 1) * 32000:
                words.append("word%d" % len(words))
                send_text(conn, json.dumps({"type": "response.audio_transcript.delta", "delta": " " + words[-1]}))
        elif kind == "input_audio_buffer.commit" and event.get("final"):
            time.sleep(lag)
            send_text(conn, json.dumps({"type": "response.audio_transcript.done", "text": " ".join(words)}))


def main():
    port_file, lag = sys.argv[1], float(sys.argv[2])
    error = len(sys.argv) > 3 and sys.argv[3] == "error"
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(4)
    with open(port_file, "w") as handle:
        handle.write(str(server.getsockname()[1]))
    while True:
        conn, _ = server.accept()
        threading.Thread(target=lambda c=conn: _run(c, lag, error), daemon=True).start()


def _run(conn, lag, error):
    try:
        serve(conn, lag, error)
    except (OSError, ConnectionError, ValueError):
        pass
    finally:
        conn.close()


if __name__ == "__main__":
    main()
