# localvoxtral remote Vibe hook compactor. Python 3.8+, standard library only.
#
# Run by post.sh as:  python compact.py WORKDIR START_PID  < vibe-hook-payload
#
# Vibe's hook payload embeds whole tool outputs, and no payload carries the
# user's prompt. This script reduces one payload to the few fields the Mac
# keeps, in Claude Code's hook shape (which the Mac's remote parser already
# reads), so file contents never cross the tunnel beyond the short excerpts a
# remote Claude Code session sends too. It writes, into WORKDIR:
#
#   plan            one line per request to make, in order: "<n> <EventName>"
#   event-<n>.json  the body of request <n>
#   agent-pid       the Vibe process id, a label for the Mac
#
# It never sees the token, never opens a socket, prints nothing, and exits 0
# whatever happens: post.sh sends what the plan lists, and an empty plan means
# nothing is sent.
#
# The rules mirror the local publisher (VibeHookInputParser and
# VibeTranscriptPrompt in the app's sources). Change them together.
import json
import os
import subprocess
import sys
import threading

# Vibe has two hook runners, chosen per user by a server-side rollout. The
# Unified Harness one group-qualifies its tools, names the path `path` on read
# and write, and sends no session id, parent or transcript path at all
# (VibeHookInputParser in the app's sources has the details).
TOOLS = {
    "read_file": "Read",
    "write_file": "Write",
    "edit": "Edit",
    "file_system.read_file": "Read",
    "file_system.write_file": "Write",
    "file_system.search_replace": "Edit",
}
PATH_ARGUMENTS = ("file_path", "path")
INPUT_EXCERPT_KEYS = ("new_string", "old_string", "content")
EXCERPT_CHARS = 2048  # the Mac keeps 512 bytes of each; this only bounds the request
MAX_PAYLOAD_BYTES = 8 * 1024 * 1024
MAX_PROMPT_BYTES = 8 * 1024
MAX_ID_BYTES = 4 * 1024
TAIL_BYTES = 512 * 1024
TRANSCRIPT_NAME = "messages.jsonl"
TRANSCRIPT_DEADLINE_SECONDS = 0.25
USER_ROLE_MARKERS = (b'"role": "user"', b'"role":"user"')
ANCESTOR_HOPS = 4
PS_TIMEOUT_SECONDS = 0.5


def truncate_utf8(text, limit):
    data = text.encode("utf-8")
    if len(data) <= limit:
        return text
    return data[:limit].decode("utf-8", "ignore")


def read_tail(path):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    fd = os.open(path, flags)
    try:
        info = os.fstat(fd)
        import stat as stat_module

        if not stat_module.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            return b""
        length = min(info.st_size, TAIL_BYTES)
        if length <= 0:
            return b""
        # A read may return short, and a short read of a tail window is its
        # OLDER end: the scan below would then publish a stale prompt. Fill the
        # window or give the prompt up.
        start = info.st_size - length
        chunks = []
        filled = 0
        while filled < length:
            chunk = os.pread(fd, length - filled, start + filled)
            if not chunk:
                return b""
            chunks.append(chunk)
            filled += len(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


def last_user_prompt(path):
    """The newest message the user typed, or None.

    Only a line Vibe wrote with the user role and `"injected": false` counts,
    and only its `content` string is kept. A line without the user-role marker
    is not parsed at all.
    """
    if not isinstance(path, str) or not path.startswith("/"):
        return None
    if os.path.basename(path) != TRANSCRIPT_NAME:
        return None
    for line in reversed(read_tail(path).split(b"\n")):
        if not any(marker in line for marker in USER_ROLE_MARKERS):
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if not isinstance(message, dict) or message.get("role") != "user":
            continue
        if message.get("injected") is not False:
            continue
        content = message.get("content")
        if not isinstance(content, str) or not content.strip():
            continue
        return truncate_utf8(content.strip(), MAX_PROMPT_BYTES)
    return None


def last_user_prompt_within_deadline(path):
    """`last_user_prompt`, abandoned when the volume stalls.

    A daemon thread: main() ends with os._exit, so a read still blocked in the
    kernel cannot hold the hook past Vibe's timeout.
    """
    result = []

    def work():
        try:
            result.append(last_user_prompt(path))
        except Exception:
            result.append(None)

    thread = threading.Thread(target=work, daemon=True)
    thread.start()
    thread.join(TRANSCRIPT_DEADLINE_SECONDS)
    return result[0] if result else None


def absolute_file_path(tool_input, cwd):
    raw = next((tool_input[key] for key in PATH_ARGUMENTS if isinstance(tool_input.get(key), str)), None)
    if not raw:
        return None
    if not raw.startswith("/"):
        if not isinstance(cwd, str) or not cwd.startswith("/"):
            return None
        raw = os.path.join(cwd, raw)
    path = os.path.normpath(raw)
    return path if path.startswith("/") else None


def process_table():
    """{pid: (parent pid, has a controlling terminal)} from ONE ps call.

    One call under one short timeout, because this script runs inside a hook
    Vibe kills after five seconds: post.sh still has two one-second requests to
    make after it.
    """
    table = {}
    try:
        output = subprocess.run(
            ["ps", "-ax", "-o", "pid=,ppid=,tty="],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=PS_TIMEOUT_SECONDS,
            check=False,
        ).stdout.decode("ascii", "ignore")
    except Exception:
        return table
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 3:
            continue
        try:
            table[int(fields[0])] = (int(fields[1]), fields[2] not in ("?", "??", "-"))
        except ValueError:
            continue
    return table


def vibe_pid(start):
    """The Vibe process this hook descends from.

    Vibe starts a hook in a new session with no controlling terminal, behind an
    `sh -c` that may or may not have exec'd. Climb while the process is still
    one of the hook's own: same session as us, no terminal.
    """
    own_session = os.getsid(0)
    table = process_table()
    # No table (no `ps`, or it timed out): `start` may be the `sh -c` wrapper,
    # which exits with this hook. Publishing it would make post.sh's watcher
    # report a LIVE session as ended two seconds from now. Better no pid.
    if start not in table:
        return None
    current = start
    for _ in range(ANCESTOR_HOPS):
        try:
            session = os.getsid(current)
        except OSError:
            return current
        facts = table.get(current)
        if session != own_session or facts is None or facts[1] or facts[0] <= 1:
            return current
        current = facts[0]
    return current


def process_start(pid):
    """When `pid` started, as letters and digits, or None.

    Only ever compared with itself: it makes a reused pid a different session.
    """
    try:
        with open("/proc/%d/stat" % pid, "rb") as handle:
            stat = handle.read(4096)
        # The command name may hold spaces and parentheses; `starttime` is
        # field 22, the 20th after the name.
        return stat[stat.rindex(b")") + 2 :].split()[19].decode("ascii")
    except Exception:
        pass
    try:
        output = subprocess.run(
            ["ps", "-o", "lstart=", "-p", str(pid)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=PS_TIMEOUT_SECONDS,
            check=False,
        ).stdout.decode("ascii", "ignore")
    except Exception:
        return None
    return "".join(c for c in output if c.isalnum()) or None


def process_session_id(agent_pid):
    """The session id for a payload that carries none (the Unified Harness).

    One interactive Vibe process shows one session in one pane, so the process
    is the session. No pid or no start time means no id, and nothing is sent.
    """
    # A hook whose Vibe exited before this shell read `$PPID` starts from init.
    # Every such hook on the host would share that pid, and with it one session
    # id for every pane. (A payload with its own id still goes out from there:
    # the watcher cannot signal init, takes that for "gone", and ends the
    # session at once, which is right.) The same window ending at a subreaper
    # instead of init is not caught.
    if agent_pid is None or agent_pid <= 1:
        return None
    start = process_start(agent_pid)
    return "process-%d-%s" % (agent_pid, start) if start else None


def is_unified(payload):
    return "session_id" not in payload and "parent_session_id" not in payload


def events_for(payload, process_id=None):
    kind = payload.get("hook_event_name")
    if kind not in ("post_tool", "post_agent"):
        return []
    if is_unified(payload):
        session_id = process_id
    else:
        # Present and null means top level. A subagent carries its parent's id,
        # and a payload with a session id and without the field is not provably
        # top level.
        if "parent_session_id" not in payload or payload["parent_session_id"] is not None:
            return []
        session_id = payload.get("session_id")
    if not isinstance(session_id, str) or not session_id or len(session_id.encode("utf-8")) > MAX_ID_BYTES:
        return []
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else None

    def event(name, **fields):
        body = {"hook_event_name": name, "session_id": session_id}
        if cwd:
            body["cwd"] = cwd
        body.update(fields)
        return name, body

    events = []
    prompt = last_user_prompt_within_deadline(payload.get("transcript_path"))
    if prompt:
        events.append(event("UserPromptSubmit", prompt=prompt))

    if kind == "post_agent":
        events.append(event("Stop"))
        return events

    tool = TOOLS.get(payload.get("tool_name"))
    tool_input = payload.get("tool_input")
    if tool is None or not isinstance(tool_input, dict):
        return events
    path = absolute_file_path(tool_input, cwd)
    if path is None:
        return events
    kept_input = {"file_path": path}
    for key in INPUT_EXCERPT_KEYS:
        value = tool_input.get(key)
        if isinstance(value, str) and value:
            kept_input[key] = value[:EXCERPT_CHARS]
    fields = {"tool_name": tool, "tool_input": kept_input}
    output = payload.get("tool_output")
    if tool == "Read" and isinstance(output, dict) and isinstance(output.get("content"), str):
        fields["tool_response"] = {"content": output["content"][:EXCERPT_CHARS]}
    events.append(event("PostToolUse", **fields))
    return events


def main():
    workdir, start_pid = sys.argv[1], int(sys.argv[2])
    raw = sys.stdin.buffer.read(MAX_PAYLOAD_BYTES + 1)
    if len(raw) > MAX_PAYLOAD_BYTES:
        return
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        return
    if is_unified(payload):
        agent_pid = vibe_pid(start_pid)
        events = events_for(payload, process_session_id(agent_pid))
    else:
        agent_pid = None
        events = events_for(payload)
    if not events:
        return
    if agent_pid is None or agent_pid <= 1:
        agent_pid = vibe_pid(start_pid)
    if agent_pid is not None:
        with open(os.path.join(workdir, "agent-pid"), "w") as handle:
            handle.write("%d\n" % agent_pid)
    # For post.sh's exit watcher: the id goes into a file NAME and a JSON body
    # there, so it is only handed over when it is plainly safe for both.
    session_id = events[0][1]["session_id"]
    if len(session_id) <= 64 and all(c.isascii() and (c.isalnum() or c == "-") for c in session_id):
        with open(os.path.join(workdir, "session-id"), "w") as handle:
            handle.write(session_id + "\n")
    plan = []
    for index, (name, body) in enumerate(events, start=1):
        with open(os.path.join(workdir, "event-%d.json" % index), "w", encoding="utf-8") as handle:
            json.dump(body, handle, ensure_ascii=True)
        plan.append("%d %s\n" % (index, name))
    # Written last: a plan line never names a body that is not there yet.
    with open(os.path.join(workdir, "plan"), "w") as handle:
        handle.writelines(plan)


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        pass
    sys.stdout.flush()
    os._exit(0)
