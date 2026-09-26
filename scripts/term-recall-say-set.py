#!/usr/bin/env python3
"""Build a `say` recording set for the term-recall cases (#685).

PRIVATE-DATA TOOL: the bundle, the WAVs and the manifest hold case text.
Keep them outside any checkout; EvalCorpus/term-recall/README.md has the rules.

    term-recall-say-set.py bundle CASES_JSON OUT.tgz
        A tarball of one text file per case and gen.sh. On the Mac, in an
        empty directory: tar xzf OUT.tgz && bash gen.sh. It writes wav/<id>.wav
        with the voices the Mac eval uses, without playing audio.
    term-recall-say-set.py manifest CASES_JSON WAV_DIR
        Writes WAV_DIR/manifest.json in the agent-dictation format, with
        "source": "say" so a run names the set as TTS audio.

The text goes to `say -f`, so no case text passes through a shell.
"""

import hashlib
import io
import json
import re
import sys
import tarfile
from pathlib import Path

# EvalSpeechStage's first preferences, which the Mac eval resolves to.
VOICES = {"en": "Samantha", "fr": "Thomas"}


def load_cases(path):
    data = json.loads(Path(path).read_text())
    if data.get("schemaVersion") != 2:
        sys.exit(f"{path}: schemaVersion must be 2; re-harvest")
    for case in data["cases"]:
        # The id names a file and goes into gen.sh unquoted.
        if not re.fullmatch(r"tr-(en|fr)-[0-9a-f]{10}", case["id"]):
            sys.exit(f"{path}: unexpected case id {case['id']!r}")
    return data["cases"]


def add_file(tar, name, text):
    data = text.encode()
    info = tarfile.TarInfo(name)
    info.size = len(data)
    tar.addfile(info, io.BytesIO(data))


def bundle(cases, out):
    lines = ["set -e", 'cd "$(dirname "$0")"', "mkdir -p wav"]
    with tarfile.open(out, "w:gz") as tar:
        for case in cases:
            add_file(tar, f"txt/{case['id']}.txt", case["text"])
            lines.append(
                f"[ -s wav/{case['id']}.wav ] || /usr/bin/say -v {VOICES[case['language']]}"
                f" -o wav/{case['id']}.wav --file-format=WAVE --data-format=LEI16@16000"
                f" -f txt/{case['id']}.txt"
            )
        lines.append("ls wav | wc -l")
        add_file(tar, "gen.sh", "\n".join(lines) + "\n")
    print(f"{len(cases)} cases -> {out}")


def manifest(cases, wav_dir):
    wav_dir = Path(wav_dir)
    recordings, missing = [], 0
    for case in cases:
        wav = wav_dir / f"{case['id']}.wav"
        if not wav.is_file():
            missing += 1
            continue
        recordings.append({
            "id": case["id"],
            "lang": case["language"],
            "spokenForm": case["text"],
            "file": wav.name,
            "sha256": hashlib.sha256(wav.read_bytes()).hexdigest(),
        })
    if not recordings:
        sys.exit(f"{wav_dir}: no <case id>.wav files")
    (wav_dir / "manifest.json").write_text(json.dumps({
        "schemaVersion": 1,
        "dataFormat": "pcm_s16le@16000Hz-mono",
        "source": "say",
        "recordings": recordings,
    }, indent=1, ensure_ascii=False) + "\n")
    print(f"{len(recordings)} recordings, {missing} cases without a WAV -> {wav_dir}/manifest.json")


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("bundle", "manifest"):
        sys.exit(__doc__)
    cases = load_cases(sys.argv[2])
    (bundle if sys.argv[1] == "bundle" else manifest)(cases, sys.argv[3])


if __name__ == "__main__":
    main()
