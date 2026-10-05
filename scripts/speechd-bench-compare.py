#!/usr/bin/env python3
"""Compare speechd-bench runs word by word against a baseline run.

Usage: scripts/speechd-bench-compare.py BASELINE.log RUN.log [RUN.log ...]

Each log is the output of one `remote-build.sh speechd-bench ... speech` run
(its .build/last-remote.log, or LOCALVOXTRAL_REMOTE_LOG). Prints one Markdown
row per run: its step settings, mean step, worst lag, first text, and the
median over every word of its appearance time minus the baseline's, with how
many words came later, sooner or at the same millisecond. A run whose
transcript differs from the baseline's gets no word columns: its words are not
the same words.
"""
import re
import statistics
import sys


def parse(path):
    text = open(path, encoding="utf-8", errors="replace").read()

    def field(pattern, default=None):
        match = re.search(pattern, text)
        return match.group(1) if match else default

    words = field(r"BENCH words_s=([0-9.,]*)")
    if words is None:
        sys.exit(f"{path}: no BENCH words_s line; was it a speech run?")
    return {
        "model": field(r"BENCH model=(\S+)", "?"),
        "cadence": field(r"cadence_ms=(\d+)", "?"),
        "phase": field(r"phase_ms=(\d+)", "0"),
        "mic": field(r"mic_buffer_us=(\d+)", "0"),
        "mean_step": field(r"BENCH timeline .*?mean_step_ms=([0-9.]+)", "?"),
        "max_lag": field(r"BENCH timeline .*?max_lag_ms=([0-9.]+)", "?"),
        "first_text": field(r"BENCH timeline .*?first_text_s=(\S+)", "?"),
        "sha": field(r"BENCH transcript sha256=([0-9a-f]+)"),
        "words": [float(w) for w in words.split(",") if w],
    }


def main(paths):
    if len(paths) < 2:
        sys.exit(__doc__)
    base = parse(paths[0])
    print("| Run | Model | Cadence | Phase | Mic buffer | Mean step | Worst lag | First text "
          "| Words later than baseline (median) | Later / sooner / same |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for path in paths:
        run = parse(path)
        if run["sha"] != base["sha"] or len(run["words"]) != len(base["words"]):
            median, counts = "transcript differs", ""
        else:
            deltas = [round((r - b) * 1000) for r, b in zip(run["words"], base["words"])]
            median = f"{statistics.median(deltas):+.0f} ms ({len(deltas)} words)"
            later = sum(d > 0 for d in deltas)
            sooner = sum(d < 0 for d in deltas)
            counts = f"{later} / {sooner} / {len(deltas) - later - sooner}"
        mic = "none" if run["mic"] == "0" else f"{int(run['mic']) / 1000:.2f} ms"
        print(f"| {path.rsplit('/', 1)[-1]} | {run['model'].rsplit('/', 1)[-1]} "
              f"| {run['cadence']} ms | {run['phase']} ms | {mic} | {run['mean_step']} ms "
              f"| {run['max_lag']} ms | {run['first_text']} s | {median} | {counts} |")


if __name__ == "__main__":
    main(sys.argv[1:])
