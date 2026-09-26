"""Run one #316 biasing arm over a term-recall recording set on vLLM.

    vllm_term_bias_eval.py --arm none|session|noise --out HYP.jsonl \\
        [--cases EvalRecordings/term-recall/cases.json] \\
        [--recordings EvalRecordings/term-recall/say-samantha-thomas] \\
        [--first 1.5 --continuation 4.0 --margin 3.0]

The server must run with the vllm_term_bias:TermBias processor (see that
module). For each case it writes the arm's list to the processor's side file
(none: empty; session: the case's sessionTerms; noise: the file's
noiseTerms), transcribes the case, and appends {"id", "text"} to HYP.jsonl,
which TermRecallEvalTests scores in hypotheses mode. Per-case flip counts and
processor time go to HYP.flips.jsonl. Both files hold transcripts: keep them
under the gitignored EvalRecordings/term-recall/.
"""

import argparse
import asyncio
import json
import os
import sys
from pathlib import Path

from vllm_term_bias import DEFAULT_FILE
from vllm_transcribe import transcribe


def write_atomic(path: Path, data: dict) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data))
    os.replace(tmp, path)


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--arm", required=True, choices=["none", "session", "noise"])
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--cases", type=Path, default=Path("EvalRecordings/term-recall/cases.json"))
    parser.add_argument(
        "--recordings", type=Path, default=Path("EvalRecordings/term-recall/say-samantha-thomas")
    )
    parser.add_argument("--first", type=float, default=1.5)
    parser.add_argument("--continuation", type=float, default=4.0)
    parser.add_argument("--margin", type=float, default=3.0)
    parser.add_argument("--url", default="ws://127.0.0.1:8000/v1/realtime")
    parser.add_argument("--model", default="mistralai/Voxtral-Mini-4B-Realtime-2602")
    parser.add_argument("--limit", type=int)
    args = parser.parse_args()

    bias_file = Path(os.environ.get("VOXTRAL_TERM_BIAS_FILE", DEFAULT_FILE))
    stats_dir = bias_file.parent / (bias_file.stem + "-stats")
    case_file = json.loads(args.cases.read_text())
    manifest = json.loads((args.recordings / "manifest.json").read_text())
    files = {r["id"]: args.recordings / r["file"] for r in manifest["recordings"]}
    cases = [c for c in case_file["cases"] if c["id"] in files][: args.limit]
    missing = len(case_file["cases"]) - len([c for c in case_file["cases"] if c["id"] in files])
    print(f"arm={args.arm} cases={len(cases)} without audio={missing}", file=sys.stderr)

    params = {"first": args.first, "continuation": args.continuation, "margin": args.margin}
    flips_path = args.out.with_suffix(".flips.jsonl")
    with args.out.open("w") as out, flips_path.open("w") as flips:
        for n, case in enumerate(cases, 1):
            terms = {"none": [], "session": case["sessionTerms"], "noise": case_file["noiseTerms"]}[args.arm]
            session = f"{args.arm}-{case['id']}"
            (stats_dir / f"{session}.json").unlink(missing_ok=True)
            write_atomic(bias_file, {"session": session, "terms": terms, **params})
            result = await transcribe(args.url, args.model, str(files[case["id"]]), False)
            out.write(json.dumps({"id": case["id"], "text": result["text"]}) + "\n")
            out.flush()
            stats_path = stats_dir / f"{session}.json"
            stats = json.loads(stats_path.read_text()) if stats_path.exists() else {}
            flips.write(json.dumps({"id": case["id"], "listSize": len(terms), **stats}) + "\n")
            flips.flush()
            if n % 20 == 0:
                print(f"{n}/{len(cases)}", file=sys.stderr, flush=True)
    write_atomic(bias_file, {"session": "idle", "terms": []})


if __name__ == "__main__":
    asyncio.run(main())
