#!/usr/bin/env python3
"""Harvest term-recall eval cases from local Claude Code transcripts.

PRIVATE-DATA TOOL. Reads the operator's own Claude Code session transcripts
(~/.claude/projects/*/*.jsonl) on the local machine and produces:

  EvalRecordings/term-recall/cases.json   — (sentence, target terms, context) triples
  EvalRecordings/term-recall/terms.json   — ranked technical-term inventory

Both outputs are transcript-derived and land under EvalRecordings/, which is
wholesale gitignored (see the root .gitignore) and receiver-protected by
remote-build.sh's rsync filters. Never commit the outputs; never send them to
a remote service. Only this script (code) is committed.

The cases feed the Mac-side ASR-corruption mining pass
(scripts/mine-term-recall-asr.sh), which runs each sentence through
say-TTS -> live voxmlx ASR and keeps the cases where a target term got
corrupted. Those (intended, heard) pairs become the raw material for the
polish-LLM term-recall eval.

Re-runnable and deterministic for a fixed transcript corpus (stable sort
keys, seeded selection). Parses defensively: transcript schema varies across
Claude Code versions.

Usage:
  python3 scripts/harvest-term-recall-cases.py [--projects-dir ~/.claude/projects]
      [--out-dir EvalRecordings/term-recall] [--max-cases 300] [--min-cases 150]
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass, field


def resolve_out_dir(out_dir: str) -> str:
    """Anchor a relative --out-dir at the REPO ROOT, never the cwd.

    The privacy guarantee rests on the root-anchored `/EvalRecordings/`
    .gitignore rule; a cwd-relative default run from a subdirectory (e.g.
    scripts/) would write transcript-derived JSON to an UNIGNORED path.
    Fails hard when the repo root cannot be determined.
    """
    if os.path.isabs(out_dir):
        return out_dir
    try:
        top = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        print(
            "error: cannot resolve the repo root (git rev-parse "
            f"--show-toplevel failed: {error}); refusing to write "
            "transcript-derived data to a cwd-relative path",
            file=sys.stderr,
        )
        sys.exit(1)
    if not top:
        print("error: empty repo root from git rev-parse", file=sys.stderr)
        sys.exit(1)
    return os.path.join(top, out_dir)

# --------------------------------------------------------------------------
# Transcript loading
# --------------------------------------------------------------------------


@dataclass
class UserMessage:
    text: str
    session_path: str  # relative to projects dir


def _extract_text(content) -> str | None:
    """Pull human-authored text out of a message content field.

    Content is either a plain string or a list of blocks; only `text` blocks
    count (tool_result blocks are machine output echoed into the user role).
    """
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                parts.append(block.get("text", ""))
        if parts:
            return "\n".join(parts)
    return None


_NON_HUMAN_MARKERS = (
    "<command-name>",
    "<local-command-",
    "<system-reminder>",
    "<task-notification>",
    "[Request interrupted",
    "Caveat: The messages below",
    "<bash-input>",
    "<bash-stdout>",
    "<bash-stderr>",
)


def iter_user_messages(projects_dir: str):
    """Yield real human user messages from every session transcript.

    Skips: meta rows, sidechains (subagent traffic), files under subagents/
    (their "user" messages are parent-agent prompts, not the human), command
    wrappers, and tool-result echoes.
    """
    pattern = os.path.join(projects_dir, "*", "**", "*.jsonl")
    files = sorted(glob.glob(pattern, recursive=True))
    n_sessions = 0
    for path in files:
        if "/subagents/" in path:
            continue
        rel = os.path.relpath(path, projects_dir)
        n_sessions += 1
        try:
            fh = open(path, encoding="utf-8", errors="replace")
        except OSError:
            continue
        with fh:
            for line in fh:
                try:
                    obj = json.loads(line)
                except (json.JSONDecodeError, ValueError):
                    continue
                if not isinstance(obj, dict) or obj.get("type") != "user":
                    continue
                if obj.get("isMeta") or obj.get("isSidechain"):
                    continue
                msg = obj.get("message")
                if not isinstance(msg, dict) or msg.get("role") != "user":
                    continue
                text = _extract_text(msg.get("content"))
                if not text:
                    continue
                stripped = text.strip()
                if not stripped or stripped.startswith("<"):
                    continue
                if any(m in stripped for m in _NON_HUMAN_MARKERS):
                    continue
                yield UserMessage(text=stripped, session_path=rel), n_sessions
    return


# --------------------------------------------------------------------------
# Redaction / privacy filters
# --------------------------------------------------------------------------

SECRET_PATTERNS = [
    re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"),  # GitHub tokens
    re.compile(r"\bsk-[A-Za-z0-9_-]{16,}"),  # OpenAI-style keys
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),  # AWS access keys
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}"),  # Slack tokens
    re.compile(r"\beyJ[A-Za-z0-9_-]{20,}"),  # JWTs
    re.compile(r"\b[0-9a-fA-F]{32,}\b"),  # long hex (keys, digests)
    re.compile(r"(?i)\b(password|passwd|secret|api[_ ]?key|token)\s*[:=]\s*\S+"),
    re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.]+\b"),  # email addresses
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
]


def looks_sensitive(sentence: str) -> bool:
    return any(p.search(sentence) for p in SECRET_PATTERNS)


# --------------------------------------------------------------------------
# Term inventory
# --------------------------------------------------------------------------

# Words considered "plain English" even if absent from the system dictionary.
EXTRA_COMMON = {
    "ok", "okay", "yeah", "yep", "nope", "btw", "tbh", "aka", "vs", "etc",
    "repo", "repos", "config", "configs", "dev", "prod", "todo", "readme",
    "info", "meta", "async", "sync", "auto", "multi", "misc", "impl",
    "don", "doesn", "isn", "wasn", "won", "can", "let", "lets", "ll", "ve",
    "cf", "eg", "ie", "nb", "ps", "http", "https", "www", "com",
}

# Pure-symbol / unspeakable token guards.
RE_HEXISH = re.compile(r"^[0-9a-f]{7,}$", re.IGNORECASE)
RE_UUID = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I
)
RE_NUMERIC = re.compile(r"^[\d.,:x-]+$")
RE_WORDISH = re.compile(r"[A-Za-z]")

# A token: word chars plus the joiners that appear inside technical names.
RE_TOKEN = re.compile(r"[A-Za-z0-9_](?:[A-Za-z0-9_.+#-]*[A-Za-z0-9_#+])?")

STOP_TERMS = {
    # High-frequency but not really "technical terms a user dictates".
    "the", "and", "for", "with", "that", "this", "you", "not", "are", "but",
    "было",  # defensive: anything non-ascii single word gets filtered anyway
}


def load_dictionary() -> set[str]:
    words: set[str] = set()
    try:
        with open("/usr/share/dict/words", encoding="utf-8", errors="replace") as fh:
            for w in fh:
                words.add(w.strip().lower())
    except OSError:
        pass
    words |= EXTRA_COMMON
    return words


def is_speakable_token(tok: str) -> bool:
    if len(tok) < 2 or len(tok) > 30:
        return False
    if not RE_WORDISH.search(tok):
        return False
    if RE_HEXISH.match(tok) or RE_UUID.match(tok) or RE_NUMERIC.match(tok):
        return False
    if tok.count("/") > 0:  # paths handled at sentence level; tokens never have /
        return False
    # Mostly-symbol tokens are unspeakable.
    alnum = sum(c.isalnum() for c in tok)
    if alnum < len(tok) * 0.6:
        return False
    return True


def is_technical_unigram(tok: str, dictionary: set[str]) -> bool:
    """Heuristic: would a plain-English TTS/ASR round-trip preserve this
    token trivially?  If not, it is a term worth testing."""
    if not is_speakable_token(tok):
        return False
    low = tok.lower()
    if low in STOP_TERMS:
        return False
    # Latin abbreviations tokenized with their dot are not terms.
    if low in {"e.g", "i.e", "etc", "vs"}:
        return False
    # Filenames / dotted / hyphenated / underscored names are always technical.
    if any(c in tok for c in "._-#+") and RE_WORDISH.search(tok):
        return True
    # camelCase / PascalCase / mixed case beyond simple capitalization.
    if re.search(r"[a-z][A-Z]", tok) or re.search(r"[A-Z]{2,}[a-z]", tok):
        return True
    # digits glued to letters (mlx4, ci2, qwen35) — technical.
    if re.search(r"[A-Za-z]\d|\d[A-Za-z]", tok):
        return True
    # ALLCAPS initialisms (TTS, ASR, WER, CI, PR...) — but not SHOUTED
    # ordinary words ("ONLY", "NEVER"), which are emphasis, not terms.
    if tok.isupper() and 2 <= len(tok) <= 6:
        return low not in dictionary or len(tok) <= 3
    # Plain lowercase word: technical iff not in the dictionary.
    if low not in dictionary:
        return True
    return False


CONNECTOR_WORDS = {
    # Allowed interior words of a multi-word term ("of" in "point of sale").
    "of", "the", "to", "in",
}

FUNCTION_WORDS = {
    # Never valid at the EDGE of a multi-word term.
    "a", "an", "the", "to", "of", "in", "on", "at", "is", "are", "be", "was",
    "it", "as", "by", "or", "if", "so", "do", "we", "my", "me", "your", "our",
    "and", "for", "with", "that", "this", "you", "not", "but", "its", "it's",
    "then", "than", "into", "from", "when", "what", "how", "why", "who",
    "can", "will", "should", "would", "could", "does", "did", "has", "have",
    "had", "per", "via", "any", "all", "both", "each", "only", "just", "now",
    "new", "one", "two", "no", "yes", "please", "also", "still", "some",
}

# Known multi-word collocations get a boost even when the parts are dictionary
# words ("pull request", "Claude Code", "unit test" ...): a bigram/trigram is a
# term when at least one member is technical OR both members are capitalized.


def sentence_tokens(sentence: str) -> list[str]:
    return RE_TOKEN.findall(sentence)


def sentence_token_spans(sentence: str) -> list[tuple[str, int, int]]:
    return [(m.group(0), m.start(), m.end()) for m in RE_TOKEN.finditer(sentence)]


def whitespace_adjacent(sentence: str, spans, i: int, n: int) -> bool:
    """True iff tokens i..i+n-1 are separated by whitespace only in the
    original text.  Prevents n-grams glued across '/', '@', ':', '=' — path,
    URL, and log fragments are not speakable phrases."""
    for j in range(i, i + n - 1):
        gap = sentence[spans[j][2] : spans[j + 1][1]]
        if gap and not gap.isspace():
            return False
        if not gap:  # zero gap means one token was split oddly; be safe
            return False
    return True


@dataclass
class TermStats:
    count: int = 0
    sessions: set[str] = field(default_factory=set)


def build_inventory(messages: list[UserMessage], dictionary: set[str]):
    """Rank technical terms (unigrams + n-grams up to 3) by
    frequency x speakability, with provenance counts."""
    uni: dict[str, TermStats] = defaultdict(TermStats)
    ngrams: dict[str, TermStats] = defaultdict(TermStats)

    for m in messages:
        spans = sentence_token_spans(m.text)
        toks = [t for t, _, _ in spans]
        for t in toks:
            if is_technical_unigram(t, dictionary):
                key = t if not t.islower() else t.lower()
                uni[key].count += 1
                uni[key].sessions.add(m.session_path)
        # n-grams over whitespace-adjacent tokens only (2..3)
        for n in (2, 3):
            for i in range(len(toks) - n + 1):
                if not whitespace_adjacent(m.text, spans, i, n):
                    continue
                gram = toks[i : i + n]
                if not all(is_speakable_token(g) for g in gram):
                    continue
                interior = gram[1:-1]
                if any(g.lower() in FUNCTION_WORDS for g in (gram[0], gram[-1])):
                    continue
                if any(
                    g.lower() in FUNCTION_WORDS
                    and g.lower() not in CONNECTOR_WORDS
                    for g in interior
                ):
                    continue
                n_tech = sum(1 for g in gram if is_technical_unigram(g, dictionary))
                n_caps = sum(1 for g in gram if g[:1].isupper())
                if n_tech == 0 and n_caps < len(gram):
                    continue
                phrase = " ".join(gram)
                ngrams[phrase].count += 1
                ngrams[phrase].sessions.add(m.session_path)

    # Score: frequency weighted by session spread and length (multi-word terms
    # matter most for the ASR-corruption goal).
    def score(term: str, st: TermStats) -> float:
        words = term.count(" ") + 1
        return st.count * (1 + 0.5 * len(st.sessions) ** 0.5) * (1.4 ** (words - 1))

    ranked: list[tuple[str, TermStats, float]] = []
    for term, st in uni.items():
        if st.count >= 2:
            ranked.append((term, st, score(term, st)))
    for term, st in ngrams.items():
        if st.count >= 3:  # n-grams need more support to beat chance
            ranked.append((term, st, score(term, st)))
    ranked.sort(key=lambda x: (-x[2], x[0]))
    return ranked


# --------------------------------------------------------------------------
# Sentence frames
# --------------------------------------------------------------------------

RE_SENT_SPLIT = re.compile(r"(?<=[.!?])\s+|\n+")
RE_URL = re.compile(r"https?://\S+")
RE_LONG_PATH = re.compile(r"(?:/[\w.@+-]+){3,}|\b[\w.-]+/[\w.-]+/[\w./-]+")
RE_CODE_FENCE = re.compile(r"```")
RE_WS = re.compile(r"\s+")

# Pasted-content tells: shell prompts/log dumps/diffs/markup are not
# something a person dictates, even when they slip into a user message.
RE_PASTED = [
    re.compile(r"^\s*[+-]\s*<"),  # diff line with markup
    re.compile(r"</?[A-Za-z][A-Za-z0-9]*[ />]"),  # HTML/JSX tags
    re.compile(r'=["\']'),  # attribute / assignment syntax
    re.compile(r"\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}"),  # log timestamps
    re.compile(r"0x[0-9a-fA-F]+"),  # hex literals
    re.compile(r"[\w-]+ % |^\$ "),  # shell prompts (zsh "host % ", "$ ")
    re.compile(r"[{};]\s*$"),  # code line endings
    re.compile(r"\bfunc \w+\(|\bdef \w+\(|\bconst \w+ ="),  # code
    re.compile(r"\b[0-9a-f]{7,40}\b"),  # commit hashes — unspeakable
]


def split_sentences(text: str) -> list[str]:
    return [s.strip() for s in RE_SENT_SPLIT.split(text) if s.strip()]


def normalize_sentence(s: str) -> str:
    s = unicodedata.normalize("NFC", s)
    s = RE_WS.sub(" ", s).strip()
    # Strip leading list markers / quote markers a person would not speak.
    s = re.sub(r"^(?:[-*>•]|\d+[.)])\s+", "", s)
    # Strip markdown emphasis/inline-code markers; the words remain speakable.
    s = s.replace("**", "").replace("`", "")
    return s.strip()


def sentence_ok(s: str) -> bool:
    if looks_sensitive(s):
        return False
    if RE_URL.search(s) or RE_LONG_PATH.search(s) or RE_CODE_FENCE.search(s):
        return False
    if any(p.search(s) for p in RE_PASTED):
        return False
    if re.search(r"\b[\w.+-]+@[A-Za-z][\w-]*", s):  # user@host, not just emails
        return False
    n_words = len(s.split())
    if not (4 <= n_words <= 40):
        return False
    if len(s) < 25 or len(s) > 240:
        return False
    # Mostly-ASCII prose (dictation-shaped); allow accents but not walls of
    # symbols or table fragments.
    alpha = sum(c.isalpha() or c.isspace() for c in s)
    if alpha < len(s) * 0.75:
        return False
    return True


def find_terms_in_sentence(
    sentence: str, term_rank: dict[str, int]
) -> list[str]:
    """Terms (from the ranked inventory) present in this sentence, longest
    match first, no overlaps (a token claimed by 'Claude Code' is not also
    counted for 'Code')."""
    spans = sentence_token_spans(sentence)
    toks = [t for t, _, _ in spans]
    claimed = [False] * len(toks)
    hits: list[tuple[int, str]] = []
    for n in (3, 2, 1):
        for i in range(len(toks) - n + 1):
            if any(claimed[i : i + n]):
                continue
            if n > 1 and not whitespace_adjacent(sentence, spans, i, n):
                continue
            phrase = " ".join(toks[i : i + n])
            key = phrase if phrase in term_rank else phrase.lower()
            if key in term_rank:
                for j in range(i, i + n):
                    claimed[j] = True
                hits.append((term_rank[key], key))
    hits.sort()
    return [t for _, t in hits]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--projects-dir",
        default=os.path.expanduser("~/.claude/projects"),
        help="Claude Code transcripts root (default: ~/.claude/projects)",
    )
    ap.add_argument("--out-dir", default="EvalRecordings/term-recall")
    ap.add_argument("--max-cases", type=int, default=300)
    ap.add_argument("--min-cases", type=int, default=150)
    ap.add_argument("--top-terms", type=int, default=400,
                    help="inventory size used for sentence matching")
    ap.add_argument("--per-term-cap", type=int, default=6,
                    help="max sentences dominated by the same top term")
    ap.add_argument("--print-terms", action="store_true",
                    help="print the top-30 term inventory to stdout "
                    "(transcript-derived content; off by default so terminal "
                    "scrollback/logs stay clean)")
    args = ap.parse_args()
    args.out_dir = resolve_out_dir(args.out_dir)

    if not os.path.isdir(args.projects_dir):
        print(f"error: no transcripts at {args.projects_dir}", file=sys.stderr)
        return 1

    dictionary = load_dictionary()

    # 1) Load + dedupe user messages (resumed sessions duplicate history).
    messages: list[UserMessage] = []
    seen: set[str] = set()
    n_sessions = 0
    for m, n_sessions in iter_user_messages(args.projects_dir):
        digest = hashlib.sha256(m.text.encode()).hexdigest()
        if digest in seen:
            continue
        seen.add(digest)
        messages.append(m)
    print(f"sessions scanned: {n_sessions}")
    print(f"unique real user messages: {len(messages)}")

    # 2) Term inventory.
    ranked = build_inventory(messages, dictionary)
    print(f"technical terms extracted: {len(ranked)}")
    top = ranked[: args.top_terms]
    term_rank = {term: i for i, (term, _, _) in enumerate(top)}
    term_provenance = {
        term: {"count": st.count, "sessions": len(st.sessions)}
        for term, st, _ in ranked
    }

    # 3) Sentence frames.
    @dataclass
    class Candidate:
        text: str
        terms: list[str]
        session: str
        context: list[str]
        score: float

    candidates: list[Candidate] = []
    seen_sent: set[str] = set()
    for m in messages:
        msg_terms = find_terms_in_sentence(m.text, term_rank)
        for raw in split_sentences(m.text):
            s = normalize_sentence(raw)
            if not sentence_ok(s):
                continue
            key = re.sub(r"[^a-z0-9 ]", "", s.lower())
            if key in seen_sent:
                continue
            terms = find_terms_in_sentence(s, term_rank)
            # 1-3 distinct target terms; prefer rare + multiword terms
            terms = list(
                dict.fromkeys(t for t in terms if t.lower() not in STOP_TERMS)
            )
            if not (1 <= len(terms) <= 3):
                continue
            seen_sent.add(key)
            context = list(dict.fromkeys(t for t in msg_terms if t not in terms))[:6]
            sc = sum(
                (1.5 if " " in t else 1.0) / (1 + term_rank[t] / 50)
                for t in terms
            )
            candidates.append(Candidate(s, terms, m.session_path, context, sc))

    print(f"candidate sentences: {len(candidates)}")

    # 4) Diverse selection: best-scored first, cap per dominant term.
    candidates.sort(key=lambda c: (-c.score, c.text))
    per_term = Counter()
    selected: list[Candidate] = []
    for c in candidates:
        dom = c.terms[0]
        if per_term[dom] >= args.per_term_cap:
            continue
        per_term[dom] += 1
        selected.append(c)
        if len(selected) >= args.max_cases:
            break
    if len(selected) < args.min_cases:
        print(
            f"warning: only {len(selected)} cases (< --min-cases "
            f"{args.min_cases}); relax caps or thresholds",
            file=sys.stderr,
        )

    # 5) Emit. cases.json is the file that travels to the Mac for mining, so
    # it carries only a short HASH of the session path — the home-dir-shaped
    # transcript paths stay in session-map.json, which never leaves this box.
    os.makedirs(args.out_dir, exist_ok=True)
    session_map: dict[str, str] = {}

    def session_hash(path: str) -> str:
        digest = hashlib.sha256(path.encode()).hexdigest()[:12]
        session_map[digest] = path
        return digest

    cases = []
    for i, c in enumerate(sorted(selected, key=lambda c: (c.session, c.text))):
        cases.append(
            {
                "id": f"tr-{i:04d}",
                "text": c.text,
                "target_terms": c.terms,
                "term_provenance": {
                    t: term_provenance.get(t, {"count": 0, "sessions": 0})
                    for t in c.terms
                },
                "source_session_hash": session_hash(c.session),
                "context_hint": c.context,
            }
        )
    cases_path = os.path.join(args.out_dir, "cases.json")
    with open(cases_path, "w", encoding="utf-8") as fh:
        json.dump(
            {
                "schemaVersion": 1,
                "set": "term-recall",
                "private": True,
                "note": "Transcript-derived. Gitignored under /EvalRecordings/. Never commit or upload.",
                "cases": cases,
            },
            fh,
            indent=2,
            ensure_ascii=False,
        )
        fh.write("\n")
    terms_path = os.path.join(args.out_dir, "terms.json")
    with open(terms_path, "w", encoding="utf-8") as fh:
        json.dump(
            {
                "schemaVersion": 1,
                "private": True,
                "terms": [
                    {
                        "term": term,
                        "count": st.count,
                        "sessions": len(st.sessions),
                        "score": round(sc, 2),
                    }
                    for term, st, sc in ranked[:1000]
                ],
            },
            fh,
            indent=2,
            ensure_ascii=False,
        )
        fh.write("\n")

    map_path = os.path.join(args.out_dir, "session-map.json")
    with open(map_path, "w", encoding="utf-8") as fh:
        json.dump(
            {
                "schemaVersion": 1,
                "private": True,
                "note": "hash -> transcript session path. LOCAL ONLY: never copy off this machine (cases.json carries only the hashes).",
                "sessions": session_map,
            },
            fh,
            indent=2,
            ensure_ascii=False,
        )
        fh.write("\n")

    print(f"cases written: {len(cases)} -> {cases_path}")
    print(f"terms written: {min(len(ranked), 1000)} -> {terms_path}")
    print(f"session map:   {len(session_map)} entries -> {map_path} (local only)")
    if args.print_terms:
        print("top 30 terms:")
        for term, st, sc in ranked[:30]:
            print(f"  {st.count:5d}x  {len(st.sessions):3d} sessions  {term}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
