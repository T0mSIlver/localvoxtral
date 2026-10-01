#!/usr/bin/env python3
"""Prints what killed an xctest process, from macOS crash reports.

A unit shard that dies on a signal leaves only "exited with unexpected signal
code 11" in the test log; the frames are in the .ips report macOS writes to
~/Library/Logs/DiagnosticReports, which a hosted runner throws away with the
VM (#1162). build-test runs this after a failed unit step so the report's
exception and crashed-thread frames land in the job log.

  xctest-crash-summary.py [--dir DIR] [--max N] [--wait SECONDS]

--wait polls for the first report that long: ReportCrash writes it a few
seconds after the process dies. Always exits 0 unless the arguments are bad;
it is forensics, not a gate.
"""

import argparse
import glob
import json
import os
import sys
import time

FRAMES = 40
OTHER_THREAD_FRAMES = 20


def redact(value):
    home = os.path.expanduser("~")
    return value.replace(home, "~") if isinstance(value, str) and home != "/" else value


def frame_lines(frames, images, limit):
    lines = []
    for index, frame in enumerate(frames[:limit]):
        image_index = frame.get("imageIndex")
        image = images[image_index] if isinstance(image_index, int) and 0 <= image_index < len(images) else {}
        symbol = frame.get("symbol") or hex(frame.get("imageOffset", 0))
        offset = frame.get("symbolLocation")
        where = f" + {offset}" if offset is not None else ""
        source = frame.get("sourceFile")
        source = f" ({source}:{frame.get('sourceLine', '?')})" if source else ""
        lines.append(f"  {index:2d} {image.get('name', '?'):<28} {symbol}{where}{source}")
    return lines


def summarize(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        header_line, _, rest = handle.read().partition("\n")
    try:
        header = json.loads(header_line)
        body = json.loads(rest)
    except json.JSONDecodeError as error:
        return [f"===== {os.path.basename(path)}: not a JSON crash report ({error})"]

    lines = [f"===== {os.path.basename(path)} ({header.get('timestamp', '?')})"]
    exception = body.get("exception", {})
    lines.append(
        "exception: "
        + " ".join(str(exception.get(key, "")) for key in ("type", "signal", "subtype")).strip()
    )
    termination = body.get("termination", {})
    if termination:
        reasons = " ".join(str(reason) for reason in termination.get("reasons", []))
        lines.append(f"termination: {termination.get('indicator', '')} {redact(reasons)}".rstrip())
    for messages in (body.get("asi") or {}).values():
        lines.extend(f"asi: {redact(message)}" for message in messages)

    images = body.get("usedImages", [])
    threads = body.get("threads", [])
    faulting = body.get("faultingThread", 0)
    if body.get("lastExceptionBacktrace"):
        lines.append("-- last exception backtrace --")
        lines.extend(frame_lines(body["lastExceptionBacktrace"], images, FRAMES))
    if 0 <= faulting < len(threads):
        thread = threads[faulting]
        name = thread.get("name") or thread.get("queue")
        label = f" ({redact(name)})" if name else ""
        lines.append(f"-- crashed thread {faulting}{label} --")
        lines.extend(frame_lines(thread.get("frames", []), images, FRAMES))
    if faulting != 0 and threads:
        lines.append("-- main thread --")
        lines.extend(frame_lines(threads[0].get("frames", []), images, OTHER_THREAD_FRAMES))
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dir", default=os.path.expanduser("~/Library/Logs/DiagnosticReports"))
    parser.add_argument("--max", type=int, default=3)
    parser.add_argument("--wait", type=float, default=0)
    args = parser.parse_args()

    deadline = time.monotonic() + args.wait
    while True:
        reports = sorted(glob.glob(os.path.join(args.dir, "xctest*.ips")), key=os.path.getmtime, reverse=True)
        if reports or time.monotonic() >= deadline:
            break
        time.sleep(1)

    print(f"xctest crash reports: {len(reports)}")
    for path in reports[: args.max]:
        print("\n".join(summarize(path)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
