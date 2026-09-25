#!/usr/bin/env python3
"""Replay the "Suggest terms" request against a frozen dictation history (#611).

No lane sends the suggestion prompt, so a change to it is judged here: the
prompt at a base ref against the working tree's, each arm run REPEATS times on
the same export through the hosted endpoint the app uses. GLM 5.3 is not
deterministic even at temperature 0, so the repeat is the noise floor: a
difference between arms smaller than the difference between two runs of one
arm is not a difference.

    # once, on the Mac that dictated (the files hold dictated text: copy
    # them only into the gitignored local-notes/, delete them when done):
    sqlite3 ~/Library/Application\\ Support/default.store ".backup default.store"
    defaults read com.localvoxtral.app settings.polish_speaker_terms \\
        | plutil -convert json -r -o speaker-terms.json -
    defaults read com.localvoxtral.app settings.polish_dismissed_term_suggestions \\
        | plutil -convert json -r -o refused-terms.json -
    # then, on the dev box:
    eval-term-suggestions.py export --store default.store --terms speaker-terms.json \\
        --refused refused-terms.json -o local-notes/term-suggest-eval/export.json
    eval-term-suggestions.py run local-notes/term-suggest-eval/export.json --base origin/main

Scores per run, as counts of distinct terms:
  proposed    distinct terms the model returned
  spelled     the recognizer wrote it exactly right in some dictation and
              polishing never fixed it: inference spent on a useless chip
  accepted    on the owner's Names and terms list
  refused     on the owner's refused list
Only these aggregates are printed; the terms themselves go to the JSONL in
--out, which belongs in the gitignored local-notes/.

The request mirrors `SpeakerTermSuggestions.request` in the app; the script
reads each arm's instructions from that file at the arm's ref.
`--self-check` renders the input of the app test that pins that layout and
compares it with the test's expected message, read from the test file, so a
layout change in the app that this script misses fails loudly.

Standard library only. The Mistral key is read from MISTRAL_API_KEY or
~/.config/localvoxtral/mistral_api_key.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "Sources/localvoxtral/SpeakerTermSuggestions.swift"
TEST = "Tests/localvoxtralTests/SpeakerTermSuggestionsTests.swift"
ENDPOINT = "https://api.mistral.ai/v1/chat/completions"
# EUR per million tokens, from MistralUsageLedger's GLM 5.3 row.
PRICE_IN, PRICE_OUT = 1.19, 3.74
MAX_DICTATIONS = 120
MAX_REQUEST_CHARACTERS = 60_000


# --- export ---------------------------------------------------------------

def export(store: Path, terms: Path | None, refused: Path | None, out: Path) -> None:
    """Newest dictations first, the way `DictationSessionStore.recentEntries`
    returns them. The SwiftData table is found by its columns, not its name."""
    db = sqlite3.connect(f"file:{store}?mode=ro", uri=True)
    table = next(
        name for (name,) in db.execute("SELECT name FROM sqlite_master WHERE type='table'")
        if {"ZRAWTEXT", "ZPOLISHEDTEXT", "ZSTARTEDAT"}
        <= {row[1] for row in db.execute(f'PRAGMA table_info("{name}")')}
    )
    rows = db.execute(
        f'SELECT ZRAWTEXT, ZPOLISHEDTEXT FROM "{table}" ORDER BY ZSTARTEDAT DESC LIMIT ?',
        (MAX_DICTATIONS * 2,),
    ).fetchall()
    data = {
        "dictations": [{"raw": raw or "", "final": polished or raw or ""} for raw, polished in rows],
        "accepted": json.loads(terms.read_text()) if terms else [],
        "refused": json.loads(refused.read_text()) if refused else [],
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(data, ensure_ascii=False, indent=1))
    print(f"{len(data['dictations'])} dictations, {len(data['accepted'])} accepted, "
          f"{len(data['refused'])} refused -> {out}")


# --- request --------------------------------------------------------------

def instructions(ref: str | None) -> tuple[str, bool]:
    """The arm's instructions, and whether its request shows what was heard
    (#612) or only the final text (the layout before it)."""
    source = (
        (ROOT / SOURCE).read_text() if ref is None
        else subprocess.run(["git", "-C", str(ROOT), "show", f"{ref}:{SOURCE}"],
                            check=True, capture_output=True, text=True).stdout
    )
    match = re.search(r'static let instructions = """\n(.*?)\n( *)"""', source, re.S)
    if not match:
        sys.exit(f"no instructions literal in {SOURCE} at {ref or 'working tree'}")
    indent = len(match.group(2))
    prompt = "\n".join(line[indent:] for line in match.group(1).split("\n"))
    return prompt, '"heard: \\(' in source


def key(term: str) -> str:
    return "".join(c for c in term.casefold() if c.isalnum())


def block(dictation: dict, heard: bool) -> str:
    """`SpeakerTermSuggestions.block`, or the bare final text before #612."""
    if not heard:
        return dictation["final"]
    if dictation["final"] == dictation["raw"]:
        return f"heard: {dictation['raw']}"
    return f"heard: {dictation['raw']}\nfinal: {dictation['final']}"


def selected(dictations: list[dict], reserved: int, heard: bool) -> list[dict]:
    budget, result = MAX_REQUEST_CHARACTERS - reserved, []
    for dictation in dictations[:MAX_DICTATIONS]:
        trimmed = {"raw": dictation["raw"].strip(), "final": dictation["final"].strip()}
        shown = trimmed["raw"] or trimmed["final"] if heard else trimmed["final"]
        if not shown:
            continue
        cost = len(block(trimmed, heard))
        if cost > budget:
            break
        budget -= cost
        result.append(trimmed)
    return result


def message(prompt: str, texts: list[str], terms: list[str], dismissed: list[str]) -> str:
    sections = [prompt]
    if terms:
        sections.append("Already known (do not list): " + ", ".join(terms))
    if dismissed:
        sections.append("Refused by the user (do not list): " + ", ".join(dismissed))
    sections.append("\n\n".join(f"[text {i + 1}]\n{t}" for i, t in enumerate(texts)))
    return "\n\n".join(sections)


def self_check() -> None:
    """Renders the input of the app test that pins the request layout and
    compares it with that test's expected message, read from the test file."""
    test = (ROOT / TEST).read_text()
    match = re.search(
        r'func testRequestNamesKnownAndRefusedTermsAndAllowsALongWait.*?'
        r'instructions \+ "\\n\\n" \+ """\n(.*?)\n( *)"""', test, re.S)
    if not match:
        sys.exit(f"self-check: the layout test is gone from {TEST}")
    indent = len(match.group(2))
    prompt, heard = instructions(None)
    want = prompt + "\n\n" + "\n".join(line[indent:] for line in match.group(1).split("\n"))
    dictations = [{"raw": "first", "final": "first"}, {"raw": "coin", "final": "Qwen"}]
    got = message(prompt, [block(d, heard) for d in dictations], ["Qwen"], ["SessionStart"])
    if got != want:
        sys.exit("self-check failed: the script's request no longer matches the app's")
    print("self-check ok")


# --- scoring --------------------------------------------------------------

def parse(reply: str) -> list[tuple[str, list[str]]]:
    """`SpeakerTermSuggestions.parseCandidates`: the first span that is a JSON
    array, as (term, heard forms)."""
    for start in (i for i, c in enumerate(reply) if c == "["):
        end = len(reply)
        while (close := reply.rfind("]", start, end)) != -1:
            try:
                array = json.loads(reply[start:close + 1])
            except ValueError:
                end = close
                continue
            if isinstance(array, list):
                terms = [(e, []) if isinstance(e, str)
                         else (e["term"], [h for h in e["heard"] if isinstance(h, str)]
                               if isinstance(e.get("heard"), list) else [])
                         for e in array
                         if isinstance(e, str) or (isinstance(e, dict) and isinstance(e.get("term"), str))]
                if terms or not array:
                    return terms
            end = close
    return []


def whole_word(term: str, flags: int = 0) -> re.Pattern:
    return re.compile(rf"(?<![^\W_]){re.escape(term.strip())}(?![^\W_])", flags)


def spelled_right(term: str, heard: list[str], dictations: list[dict]) -> bool:
    """The recognizer wrote it exactly right somewhere, and no dictation shows
    it getting it wrong: no polish fix, no quoted wrong form found in a
    transcript (`TermSuggestionScreen.screened`'s definition of a useless chip)."""
    exact, loose = whole_word(term), whole_word(term, re.I)
    wrong = [whole_word(h) for h in heard if h.strip() and h.strip() != term.strip()]
    right = sum(bool(exact.search(d["raw"])) for d in dictations)
    missed = sum(not exact.search(d["raw"]) and (bool(loose.search(d["final"]))
                 or any(w.search(d["raw"]) for w in wrong)) for d in dictations)
    return right > 0 and missed == 0


def score(terms: list[tuple[str, list[str]]], dictations: list[dict],
          accepted: list[str], refused: list[str]) -> dict:
    accepted_keys, refused_keys = {key(t) for t in accepted}, {key(t) for t in refused}
    return {
        "proposed": len(terms),
        "spelled": sum(spelled_right(t, h, dictations) for t, h in terms),
        "accepted": sum(key(t) in accepted_keys for t, _ in terms),
        "refused": sum(key(t) in refused_keys for t, _ in terms),
    }


# --- run ------------------------------------------------------------------

def api_key() -> str:
    if value := os.environ.get("MISTRAL_API_KEY"):
        return value.strip()
    return (Path.home() / ".config/localvoxtral/mistral_api_key").read_text().strip()


def ask(model: str, content: str, secret: str) -> tuple[str, dict, float]:
    """The body `LLMPolishingService.requestBody` sends for this request on
    the Mistral shape: one user message, temperature 0.3, high effort."""
    body = {"model": model, "messages": [{"role": "user", "content": content}],
            "temperature": 0.3, "reasoning_effort": "high"}
    request = urllib.request.Request(
        ENDPOINT, data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {secret}", "Content-Type": "application/json"},
    )
    started = time.monotonic()
    with urllib.request.urlopen(request, timeout=600) as response:
        reply = json.load(response)
    content = reply["choices"][0]["message"]["content"]
    if isinstance(content, list):  # thinking + text chunks: score the text only
        content = "".join(c.get("text", "") for c in content if c.get("type") == "text")
    return content, reply.get("usage", {}), time.monotonic() - started


def run(args: argparse.Namespace) -> None:
    data = json.loads(Path(args.export).read_text())
    # Known and refused lists go out empty: the eval measures what the model
    # proposes on its own, and scores it against the owner's lists.
    known: list[str] = []
    dismissed: list[str] = []
    arms = {"base": instructions(args.base), "head": instructions(None)}
    if arms["base"] == arms["head"]:
        print("note: both arms carry the same instructions; the result is a noise measurement")
    secret = api_key()
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    spend = 0.0
    results: dict[str, list[dict]] = {arm: [] for arm in arms}
    for repeat in range(args.repeats):
        for arm, (prompt, heard) in arms.items():  # interleaved, so drift hits both arms
            chosen = selected(data["dictations"], len(prompt), heard)
            texts = [block(d, heard) for d in chosen]
            reply, usage, seconds = ask(args.model, message(prompt, texts, known, dismissed), secret)
            seen, terms = set(), []
            for term, forms in parse(reply):
                if key(term) and key(term) not in seen:
                    seen.add(key(term))
                    terms.append((term, forms))
            row = score(terms, chosen, data["accepted"], data["refused"])
            cost = (usage.get("prompt_tokens", 0) * PRICE_IN
                    + usage.get("completion_tokens", 0) * PRICE_OUT) / 1e6
            spend += cost
            results[arm].append({"terms": terms, **row})
            with out.open("a") as log:
                log.write(json.dumps({"arm": arm, "repeat": repeat, "base": args.base,
                                      "dictations": len(chosen), "terms": terms, "reply": reply,
                                      "usage": usage, "seconds": round(seconds, 1), **row},
                                     ensure_ascii=False) + "\n")
            print(f"{arm} #{repeat + 1}: {len(chosen)} dictations, {seconds:.0f} s, "
                  f"{cost:.3f} EUR, " + ", ".join(f"{k} {v}" for k, v in row.items()))
    for arm, rows in results.items():
        if len(rows) >= 2:
            first, second = ({key(t) for t, _ in r["terms"]} for r in rows[:2])
            union = first | second
            overlap = len(first & second) / len(union) if union else 1.0
            print(f"{arm} repeat overlap: {overlap:.0%} of {len(union)} distinct terms")
    print(f"spend: {spend:.2f} EUR")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-check", action="store_true", help="check the request layout and exit")
    sub = parser.add_subparsers(dest="command")
    ex = sub.add_parser("export", help="history store + term lists -> export JSON")
    ex.add_argument("--store", required=True, type=Path)
    ex.add_argument("--terms", type=Path, help="Names and terms, as a JSON array")
    ex.add_argument("--refused", type=Path, help="refused suggestions, as a JSON array")
    ex.add_argument("-o", "--output", required=True, type=Path)
    rn = sub.add_parser("run", help="replay both arms against an export")
    rn.add_argument("export")
    rn.add_argument("--base", default="origin/main", help="ref whose prompt is the baseline arm")
    rn.add_argument("--repeats", type=int, default=2)
    rn.add_argument("--model", default="zai-glm-5-3")
    rn.add_argument("--out", default="local-notes/term-suggest-eval/runs.jsonl")
    args = parser.parse_args()
    if args.self_check:
        self_check()
    elif args.command == "export":
        export(args.store, args.terms, args.refused, args.output)
    elif args.command == "run":
        run(args)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
