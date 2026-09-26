"""vLLM (BF16) vs speechd (4-bit qhead) on the same eval-e2e TTS audio.

    vllm_fidelity.py EVAL_E2E_LOG WAV_DIR OUT.jsonl

EVAL_E2E_LOG is an eval-e2e scoreboard log (the `eval-e2e-scoreboard`
artifact); the `transcript` field of its inspection report is speechd's raw
ASR on the Mac. WAV_DIR holds the `say` WAVs, named by the eval's cache key.
Transcribes each case through the local vLLM server (resuming from OUT.jsonl),
then prints aggregate scores for both engines.

    vllm_fidelity.py EVAL_E2E_LOG --say-script > gen.sh

prints the `say` commands that make those WAVs; run it on a Mac.
"""

import asyncio
import hashlib
import json
import re
import shlex
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vllm_transcribe import transcribe  # noqa: E402

REPORT_BEGIN = "=== AGENT-E2E-INSPECTION-REPORT-BEGIN ==="
REPORT_END = "=== AGENT-E2E-INSPECTION-REPORT-END ==="
VOICES = {"en": "Samantha", "fr": "Thomas"}
URL = "ws://127.0.0.1:8000/v1/realtime"
MODEL = "mistralai/Voxtral-Mini-4B-Realtime-2602"


def cache_key(text, voice, fmt="LEI16@16000"):
    h = hashlib.sha256()
    for field in (text, voice, fmt):
        b = field.encode()
        h.update(struct.pack("<Q", len(b)))
        h.update(b)
    return h.hexdigest()


def words(text):
    # IntegrationTestSupport.wordAccuracy: lowercase, [\p{L}\p{N}]+ tokens.
    return re.findall(r"[^\W_]+", text.lower())


def lev(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a):
        cur = [i + 1]
        for j, y in enumerate(b):
            cur.append(min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (x != y)))
        prev = cur
    return prev[-1]


def word_accuracy(expected, actual):
    e, a = words(expected), words(actual)
    if not e:
        return 1.0 if not a else 0.0
    return max(0.0, 1 - lev(e, a) / max(len(e), len(a)))


def spacing(text):
    return re.sub(r"\s+", " ", text).strip()


def tokens_pass(case, output):
    out = spacing(output)
    hay = out.lower() if case.get("caseInsensitive") else out
    for t in case["requiredTokens"]:
        needle = spacing(t).lower() if case.get("caseInsensitive") else spacing(t)
        if needle not in hay:
            return False
    return not any(spacing(f).lower() in out.lower() for f in case.get("forbiddenSubstrings", []))


def say_script(cases):
    print("set -e")
    for c in cases:
        key = cache_key(c["spokenForm"], VOICES[c["lang"]])
        print(f"[ -s {key}.wav ] || /usr/bin/say -o {key}.wav --file-format=WAVE "
              f"--data-format=LEI16@16000 -v {VOICES[c['lang']]} {shlex.quote(c['spokenForm'])}")


async def main():
    text = open(sys.argv[1]).read()
    text = text.split(REPORT_BEGIN, 1)[-1].split(REPORT_END, 1)[0]
    rows = [json.loads(line) for line in text.splitlines() if line.strip()][1:]
    cases = [r for r in rows if r.get("pipeline") != "polish-only" and r.get("spokenForm")]
    if sys.argv[2] == "--say-script":
        return say_script(cases)
    wav_dir, out_path = Path(sys.argv[2]), Path(sys.argv[3])
    done = {}
    if out_path.exists():
        done = {json.loads(line)["caseID"]: json.loads(line) for line in open(out_path)}
    with open(out_path, "a") as out:
        for c in cases:
            if c["caseID"] in done:
                continue
            wav = wav_dir / f"{cache_key(c['spokenForm'], VOICES[c['lang']])}.wav"
            r = await transcribe(URL, MODEL, str(wav), False)
            row = {"caseID": c["caseID"], "vllm": r["text"], "seconds": r["seconds"],
                   "audio_seconds": r["audio_seconds"]}
            out.write(json.dumps(row) + "\n")
            out.flush()
            done[c["caseID"]] = row

    def summary(label, subset):
        n = len(subset)
        # Reference = what `say` spoke. intendedText is the polished target
        # (code spans, pasted clipboard), which no ASR can produce.
        mac_wa = sum(word_accuracy(c["spokenForm"], c["transcript"]) for c in subset) / n
        vl_wa = sum(word_accuracy(c["spokenForm"], done[c["caseID"]]["vllm"]) for c in subset) / n
        asr_only = [c for c in subset if c["pipeline"] == "asr-only"]
        mac_tok = sum(tokens_pass(c, c["transcript"]) for c in asr_only)
        vl_tok = sum(tokens_pass(c, done[c["caseID"]]["vllm"]) for c in asr_only)
        agree = sum(words(c["transcript"]) == words(done[c["caseID"]]["vllm"]) for c in subset)
        cross = sum(word_accuracy(c["transcript"], done[c["caseID"]]["vllm"]) for c in subset) / n
        better = sum(word_accuracy(c["spokenForm"], done[c["caseID"]]["vllm"])
                     > word_accuracy(c["spokenForm"], c["transcript"]) + 1e-9 for c in subset)
        worse = sum(word_accuracy(c["spokenForm"], done[c["caseID"]]["vllm"])
                    < word_accuracy(c["spokenForm"], c["transcript"]) - 1e-9 for c in subset)
        tok_gain = sum(tokens_pass(c, done[c["caseID"]]["vllm"]) and not tokens_pass(c, c["transcript"])
                       for c in asr_only)
        tok_loss = sum(tokens_pass(c, c["transcript"]) and not tokens_pass(c, done[c["caseID"]]["vllm"])
                       for c in asr_only)
        print(f"{label}: n={n}")
        print(f"  word accuracy vs spoken text: speechd {mac_wa:.3f}, vLLM {vl_wa:.3f}; "
              f"vLLM better on {better}, worse on {worse}")
        print(f"  required tokens pass (asr-only cases): speechd {mac_tok}/{len(asr_only)}, vLLM {vl_tok}/{len(asr_only)} "
              f"(vLLM gains {tok_gain}, loses {tok_loss})")
        print(f"  same words: {agree}/{n}; mean word agreement between engines {cross:.3f}")

    # Metric check: the Swift harness scores the polished output vs intendedText.
    drift = max(abs(word_accuracy(c["intendedText"], c["output"]) - c["wordAccuracyVsIntended"])
                for c in cases)
    print(f"metric check: max |python - swift| word accuracy on the Mac's output = {drift:.4f}")
    summary("all", cases)
    for lang in ("en", "fr"):
        summary(lang, [c for c in cases if c["lang"] == lang])
    rtf = sum(d["seconds"] for d in done.values()) / sum(d["audio_seconds"] for d in done.values())
    print(f"vLLM wall time / audio time (bulk send, sequential): {rtf:.3f}")


asyncio.run(main())
