"""Drives one interactive Vibe turn through a pty: the unified harness fires
user hooks only in an interactive session (`vibe -p` denies their callbacks).

    python3 scripts/linux/vibe-tty-turn.py <prompt> <vibe> [args...]

Waits for the UI, types the prompt, waits for the turn, then quits. Prints
the time the Vibe process exited, epoch seconds, on the last line.
"""
import os
import pty
import select
import signal
import sys
import time

prompt, argv = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execvp(argv[0], argv)


LOG = open(os.environ["VIBE_TTY_LOG"], "ab") if os.environ.get("VIBE_TTY_LOG") else None


def pump(seconds, until=None):
    end = time.time() + seconds
    seen = b""
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return seen, True
            if not chunk:
                return seen, True
            seen += chunk
            if LOG:
                LOG.write(chunk)
                LOG.flush()
            if until and until in seen:
                return seen, False
    return seen, False


pump(12)
for ch in prompt:
    os.write(fd, ch.encode())
    time.sleep(0.01)
time.sleep(0.5)
os.write(fd, b"\r")
pump(45)
for _ in range(3):
    os.write(fd, b"\x03")
    _, closed = pump(3)
    if closed:
        break
# Keep draining the pty while Vibe exits: a process whose terminal output
# nobody reads cannot finish exiting.
deadline = time.time() + 20
while time.time() < deadline:
    done, _ = os.waitpid(pid, os.WNOHANG)
    if done:
        break
    if time.time() > deadline - 15:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    pump(1)
else:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
print(int(time.time()))
