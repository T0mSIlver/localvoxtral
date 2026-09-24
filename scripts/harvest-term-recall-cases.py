#!/usr/bin/env python3
"""Harvest term-recall eval cases from local Claude Code transcripts.

PRIVATE-DATA TOOL. Reads the operator's own Claude Code session transcripts
(~/.claude/projects) and writes:

  EvalRecordings/term-recall/cases.json  the cases, the only file that goes
                                         to the Mac (gitignored)
  <private dir>/terms.json               the ranked term inventory
  <private dir>/session-map.json         case session hash -> transcript path

The private dir defaults to ~/.local/share/localvoxtral/term-recall, outside
the repo, so no remote-build sync can carry those two off this machine.
Never commit or upload any of it. `./scripts/remote-build.sh
eval-term-recall` scores the cases; EvalCorpus/term-recall/README.md has the
schema and the rules.

Deterministic for a fixed transcript corpus. A case id is derived from its
sentence, so a re-harvest keeps the ids of the sentences it keeps.

Usage:
  python3 scripts/harvest-term-recall-cases.py [--projects-dir ~/.claude/projects]
      [--out-dir EvalRecordings/term-recall] [--private-dir DIR]
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
    language: str | None = None  # "en", "fr", or None when undecided

    @property
    def project(self) -> str:
        return self.session_path.split(os.sep, 1)[0]


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
    # Claude Code's own summary of a compacted conversation, filed as a user
    # message; its section headers would otherwise rank as terms.
    "This session is being continued from a previous conversation",
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
# Language
# --------------------------------------------------------------------------

FRENCH_WORDS = {
    "le", "la", "les", "des", "une", "un", "est", "pas", "que", "qui", "dans",
    "pour", "avec", "sur", "mais", "je", "tu", "il", "elle", "nous", "vous",
    "ce", "cette", "ces", "sont", "fait", "faire", "du", "au", "aux", "on",
    "ça", "et", "ou", "si", "ne", "plus", "tout", "tous", "mon", "ton", "son",
    "moi", "toi", "lui", "leur", "quand", "comme", "où", "donc", "alors",
    "aussi", "bien", "très", "peux", "peut", "veux", "faut", "c'est", "j'ai",
    "n'est", "qu'il", "d'un", "d'une", "l'on", "encore", "déjà", "juste",
    "après", "avant", "chaque", "entre", "sans", "sous", "vers", "chez",
    "de", "en", "à", "ai", "est-ce", "parce", "qu'on", "c'était", "y",
}
ENGLISH_WORDS = {
    "the", "is", "are", "and", "to", "of", "in", "that", "it", "for", "with",
    "this", "you", "not", "but", "be", "we", "can", "should", "what", "when",
}
RE_WORD = re.compile(r"[a-zàâäçéèêëîïôöûùüÿœæ']+")


def detect_language(text: str, min_hits: int = 3) -> str | None:
    """"fr", "en", or None when the function-word counts do not decide.

    A sentence is decided on its own when it is clear, else it takes its
    message's language: a short sentence carries few function words, but a
    message can quote a line in the other language.
    """
    words = RE_WORD.findall(text.lower().replace("\u2019", "'"))
    if len(words) < 4:
        return None
    fr = sum(w in FRENCH_WORDS for w in words)
    en = sum(w in ENGLISH_WORDS for w in words)
    if fr >= min_hits and fr > en * 1.5:
        return "fr"
    if en >= min_hits - 1 and en > fr * 1.5:
        return "en"
    return None


# --------------------------------------------------------------------------
# Term inventory
# --------------------------------------------------------------------------

# Words considered "plain English" even if absent from the system dictionary.
EXTRA_COMMON = {
    "ok", "okay", "yeah", "yep", "nope", "btw", "tbh", "aka", "vs", "etc",
    "repo", "repos", "config", "configs", "dev", "prod", "todo", "readme",
    "info", "meta", "async", "sync", "auto", "multi", "misc", "impl",
    "don", "doesn", "isn", "wasn", "won", "can", "let", "lets", "ll", "ve",
    "didn", "couldn", "shouldn", "wouldn", "haven", "hasn", "aren", "weren",
    "hadn", "mustn", "needn", "ain",
    # Chat shorthand: typed, never dictated, and no engine writes it.
    "imo", "imho", "idk", "bc", "afaik", "iirc", "fyi", "lol", "thx", "pls",
    "plz", "ofc", "wdyt", "qqn",
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
# Unicode word characters, so an accented French word stays one token.
RE_TOKEN = re.compile(r"\w(?:[\w.+#-]*[\w#+])?")

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
                # Lowercase entries only: a capitalized entry is a name
                # ("Claude"), and a name is a term to spell right.
                w = w.strip()
                if w and w == w.lower():
                    words.add(w)
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
                # A phrase is a term when two of its words are ("gh pr",
                # "DNS TXT record"), or when it is a capitalized name with at
                # least one word outside the dictionary ("Claude Code"). One
                # technical word inside ordinary words ("review the PR") is
                # that word's case, and a title-cased heading ("Next Step") is
                # not a name.
                n_tech = sum(1 for g in gram if is_technical_unigram(g, dictionary))
                n_caps = sum(1 for g in gram if g[:1].isupper())
                n_uncommon = sum(1 for g in gram if g.lower() not in dictionary)
                if n_tech < 2 and not (n_caps == len(gram) and n_uncommon >= 1):
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
    re.compile(r"[\u2500-\u257f]"),  # box-drawing table borders
    re.compile(r"(?:^|\s)--?[a-z][\w-]*"),  # command-line flags
    re.compile(r"\w\("),  # call syntax
    re.compile(r"\s=\s"),  # assignments
    re.compile(r"#{2,}|\{#"),  # markdown headings and anchors
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
    if looks_like_identifier_list(s):
        return False
    # A table header or log column row: mostly ALLCAPS words.
    words = s.split()
    shouted = sum(1 for w in words if len(w) >= 2 and w.isupper())
    if shouted >= 3 and shouted * 2 >= len(words):
        return False
    return True


RE_JOINED_NAME = re.compile(r"[A-Za-z0-9][._#+-][A-Za-z0-9]|[a-z][A-Z]")


def looks_like_identifier_list(s: str) -> bool:
    """A run of names nobody would dictate: CSS class lists, import lines,
    flag lists. normalize_sentence strips a leading "- " as a list marker, so
    a diff line of class names ("- flex-row items-center gap-2 px-4") reaches
    this point looking like prose; what gives it away is that most of its
    words are joined names."""
    words = s.split()
    joined = sum(1 for w in words if RE_JOINED_NAME.search(w))
    return joined >= 3 and joined * 5 >= len(words) * 2


def scorer_targets(text: str, session_list: list[str], noise: list[str]) -> list[str]:
    """The session-list terms TermRecallScorer finds in `text`, in list order.

    A port of TermRecallScorer.Matcher: patterns with more words first; a
    pattern matches its words in order, or fewer adjacent words that glue to
    it; a match claims its words. TermRecallEvalTests fails a run whose cases
    disagree with the Swift scorer, so a drift here cannot go unseen.
    """
    patterns = []
    seen: set[str] = set()
    for term in session_list + noise:
        key = scorer_key(term)
        if key and key not in seen:
            seen.add(key)
            patterns.append((key.split(" "), key.replace(" ", ""), key, term))
    patterns.sort(key=lambda p: (len(p[0]), len(p[1]), p[2]), reverse=True)
    words = scorer_key(text).split(" ") if scorer_key(text) else []
    found: set[str] = set()
    i = 0
    while i < len(words):
        length = 0
        for parts, glued, key, _ in patterns:
            n = len(parts)
            if words[i : i + n] == parts:
                length = n
            else:
                length = next(
                    (w for w in range(n - 1, 0, -1)
                     if i + w <= len(words) and "".join(words[i : i + w]) == glued),
                    0,
                )
            if length:
                found.add(key)
                break
        i += length or 1
    return [t for t in dict.fromkeys(session_list) if scorer_key(t) in found]


def glued_key(text: str) -> str:
    """A term's identity as TermRecallScorer sees it: its words with case
    and separators dropped. "Next.js", "nextjs" and "next js" are one term to
    the scorer, which lets a spelling glue to it, so they are one term here."""
    return scorer_key(text).replace(" ", "")


_LOOKUPS: dict[int, dict[str, str]] = {}


def term_rank_lookup(term_rank: dict[str, int]) -> dict[str, str]:
    lookup = _LOOKUPS.get(id(term_rank))
    if lookup is None:
        lookup = {glued_key(t): t for t in sorted(term_rank, key=term_rank.get, reverse=True)}
        _LOOKUPS[id(term_rank)] = lookup
    return lookup


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
            key = term_rank_lookup(term_rank).get(glued_key(phrase))
            # Fewer words may glue to a term, more may not: "with a" is not
            # the term "witha", as the scorer sees it.
            if key is not None and len(scorer_key(phrase).split()) > len(scorer_key(key).split()):
                key = None
            if key is not None:
                for j in range(i, i + n):
                    claimed[j] = True
                hits.append((term_rank[key], key))
    hits.sort()
    return [t for _, t in hits]


@dataclass
class Candidate:
    text: str
    terms: list[str]
    session: str
    project: str
    language: str
    score: float


def terms_by_scope(messages: list[UserMessage], term_rank: dict[str, int]):
    """Listed terms seen in each session and each project, as rank-ordered
    lists. A case's bias list is its session's terms, topped up from its
    project, as #316 builds the live list from the joined session and the
    repository."""
    by_session: dict[str, set[str]] = defaultdict(set)
    by_project: dict[str, set[str]] = defaultdict(set)
    for m in messages:
        found = find_terms_in_sentence(m.text, term_rank)
        by_session[m.session_path].update(found)
        by_project[m.project].update(found)

    def ranked(terms: set[str]) -> list[str]:
        return sorted(terms, key=lambda t: term_rank[t])

    return (
        {k: ranked(v) for k, v in by_session.items()},
        {k: ranked(v) for k, v in by_project.items()},
    )


def session_terms_for(
    case: Candidate,
    by_session: dict[str, list[str]],
    by_project: dict[str, list[str]],
    limit: int,
) -> list[str]:
    listed = list(case.terms)
    for term in by_session.get(case.session, []) + by_project.get(case.project, []):
        if len(listed) >= limit:
            break
        if term not in listed:
            listed.append(term)
    return listed


def noise_terms_for(
    ranked_terms: list[str],
    cases: list[Candidate],
    session_lists: list[list[str]],
    limit: int,
) -> list[str]:
    """Terms from the inventory that no case speaks and no case lists: the
    unrelated list #316's noise-control arm biases with. A case may still say
    one by accident, so the scorer counts insertions against the reference."""
    used = {scorer_key(t) for listed in session_lists for t in listed}
    # Padded word strings, so " pull request " finds "pull-request" the way
    # the scorer would, and never matches inside a longer word.
    spoken = [f" {scorer_key(c.text)} " for c in cases]
    noise: list[str] = []
    for term in ranked_terms:
        if len(noise) >= limit:
            break
        key = scorer_key(term)
        glued = key.replace(" ", "")
        if not key or key in used or any(
            f" {key} " in text or f" {glued} " in text for text in spoken
        ):
            continue
        noise.append(term)
    return noise


def scorer_key(text: str) -> str:
    """The words TermRecallScorer compares: lowercased, split on anything
    that is not a letter or digit."""
    return " ".join(re.findall(r"[^\W_]+", text.lower()))


def select_cases(
    candidates: list[Candidate], max_cases: int, per_term_cap: int
) -> list[Candidate]:
    """Best-scored first, at most per_term_cap cases led by the same term."""
    per_term = Counter()
    selected: list[Candidate] = []
    for c in sorted(candidates, key=lambda c: (-c.score, c.text)):
        dom = c.terms[0]
        if per_term[dom] >= per_term_cap:
            continue
        per_term[dom] += 1
        selected.append(c)
        if len(selected) >= max_cases:
            break
    return selected


def write_json(path: str, payload) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, ensure_ascii=False)
        fh.write("\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--projects-dir",
        default=os.path.expanduser("~/.claude/projects"),
        help="Claude Code transcripts root (default: ~/.claude/projects)",
    )
    ap.add_argument("--out-dir", default="EvalRecordings/term-recall")
    ap.add_argument(
        "--private-dir",
        default=os.path.expanduser("~/.local/share/localvoxtral/term-recall"),
        help="where terms.json and session-map.json go: outside the repo, so "
        "no remote-build sync can carry them off this machine",
    )
    ap.add_argument("--max-cases-en", type=int, default=200)
    ap.add_argument("--min-cases-en", type=int, default=150)
    ap.add_argument("--max-cases-fr", type=int, default=60)
    ap.add_argument("--min-cases-fr", type=int, default=40)
    ap.add_argument("--top-terms", type=int, default=400,
                    help="inventory size used for sentence matching")
    ap.add_argument("--per-term-cap", type=int, default=6,
                    help="max sentences dominated by the same top term")
    ap.add_argument("--list-size", type=int, default=100,
                    help="entries in each case's session list and in the noise list")
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
        m.language = detect_language(m.text)
        messages.append(m)
    by_language = Counter(m.language for m in messages)
    print(f"sessions scanned: {n_sessions}")
    print(
        f"unique real user messages: {len(messages)} "
        f"(en {by_language['en']}, fr {by_language['fr']}, undecided {by_language[None]})"
    )

    # 2) Dictation-shaped sentences. Everything below reads only these, so
    # pasted logs and tool output never rank as terms or reach a bias list.
    sentences: list[UserMessage] = []
    for m in messages:
        for raw in split_sentences(m.text):
            s = normalize_sentence(raw)
            if not sentence_ok(s):
                continue
            language = detect_language(s, min_hits=2) or m.language
            if language is not None:
                sentences.append(UserMessage(s, m.session_path, language))

    # 3) Term inventory. The dictionary test that makes a word "technical" is
    # English, so only English sentences build it; French sentences are then
    # matched against the same inventory, which also keeps French words out.
    english = [m for m in sentences if m.language == "en"]
    # One entry per scorer identity: the best-ranked spelling stands for
    # "Next.js", "nextjs" and "next js" alike.
    # Of those spellings, the one with the most words: the scorer lets fewer
    # words glue to a term, never more, so "Next.js" also finds "nextjs"
    # while "nextjs" would miss "Next.js".
    ranked = []
    position: dict[str, int] = {}
    for entry in build_inventory(english, dictionary):
        key = glued_key(entry[0])
        if entry[0].lower() in FRENCH_WORDS or not key:
            continue
        # The scorer ignores case, so a one-word term that is an ordinary
        # word in lowercase ("DO", "ONE", "GET") would make every "do" a
        # target.
        words = scorer_key(entry[0]).split()
        if len(words) == 1 and words[0] in dictionary:
            continue
        if key not in position:
            position[key] = len(ranked)
            ranked.append(entry)
        elif len(scorer_key(entry[0]).split()) > len(scorer_key(ranked[position[key]][0]).split()):
            _, stats, score = ranked[position[key]]
            ranked[position[key]] = (entry[0], stats, score)
    print(f"technical terms extracted: {len(ranked)}")
    top = ranked[: args.top_terms]
    term_rank = {term: i for i, (term, _, _) in enumerate(top)}
    term_provenance = {
        term: {"count": st.count, "sessions": len(st.sessions)}
        for term, st, _ in ranked
    }

    # 4) Cases, kept whether or not the engine will get them right: a clean
    # case is the only way to count a term a change breaks.
    candidates: list[Candidate] = []
    seen_sent: set[str] = set()
    for m in sentences:
        key = re.sub(r"[^\w ]", "", m.text.lower())
        if key in seen_sent:
            continue
        terms = find_terms_in_sentence(m.text, term_rank)
        terms = list(
            dict.fromkeys(t for t in terms if t.lower() not in STOP_TERMS)
        )
        if not (1 <= len(terms) <= 3):
            continue
        seen_sent.add(key)
        sc = sum(
            (1.5 if " " in t else 1.0) / (1 + term_rank[t] / 50)
            for t in terms
        )
        candidates.append(
            Candidate(m.text, terms, m.session_path, m.project, m.language, sc)
        )
    print(
        "candidate sentences: "
        f"en {sum(c.language == 'en' for c in candidates)}, "
        f"fr {sum(c.language == 'fr' for c in candidates)}"
    )

    # 5) Per-language selection.
    selected: list[Candidate] = []
    for language, max_cases, min_cases in (
        ("en", args.max_cases_en, args.min_cases_en),
        ("fr", args.max_cases_fr, args.min_cases_fr),
    ):
        picked = select_cases(
            [c for c in candidates if c.language == language],
            max_cases,
            args.per_term_cap,
        )
        if len(picked) < min_cases:
            print(
                f"warning: only {len(picked)} {language} cases (< {min_cases}); "
                "relax caps or thresholds",
                file=sys.stderr,
            )
        selected.extend(picked)

    # 6) Bias lists.
    by_session, by_project = terms_by_scope(sentences, term_rank)
    selected.sort(key=lambda c: (c.language, c.session, c.text))
    session_lists = [
        session_terms_for(c, by_session, by_project, args.list_size) for c in selected
    ]
    noise = noise_terms_for(
        [term for term, _, _ in ranked], selected, session_lists, args.list_size
    )
    # A case's terms are what the scorer will find in its text from its
    # lists, so the two can never disagree about a case's targets.
    kept = []
    for c, listed in zip(selected, session_lists):
        c.terms = scorer_targets(c.text, listed, noise)
        if c.terms:
            kept.append((c, listed))
    selected = [c for c, _ in kept]
    session_lists = [listed for _, listed in kept]

    # 7) Emit. cases.json is the only file that travels to the Mac, so it
    # carries a short HASH of the session path; the transcript paths go to
    # session-map.json in the private dir, outside the repo.
    os.makedirs(args.out_dir, exist_ok=True)
    os.makedirs(args.private_dir, exist_ok=True)
    session_map: dict[str, str] = {}

    def session_hash(path: str) -> str:
        digest = hashlib.sha256(path.encode()).hexdigest()[:12]
        session_map[digest] = path
        return digest

    counters: Counter = Counter()
    cases = []
    for c, listed in zip(selected, session_lists):
        counters[c.language] += 1
        digest = hashlib.sha256(c.text.encode()).hexdigest()[:10]
        cases.append(
            {
                "id": f"tr-{c.language}-{digest}",
                "language": c.language,
                "text": c.text,
                "terms": c.terms,
                "sessionTerms": listed,
                "sessionHash": session_hash(c.session),
            }
        )
    cases_path = os.path.join(args.out_dir, "cases.json")
    write_json(
        cases_path,
        {
            "schemaVersion": 2,
            "set": "term-recall",
            "private": True,
            "note": "Transcript-derived. Gitignored under /EvalRecordings/. Never commit or upload.",
            "noiseTerms": noise,
            "cases": cases,
        },
    )
    terms_path = os.path.join(args.private_dir, "terms.json")
    write_json(
        terms_path,
        {
            "schemaVersion": 1,
            "private": True,
            "terms": [
                {
                    "term": term,
                    "count": term_provenance[term]["count"],
                    "sessions": term_provenance[term]["sessions"],
                    "score": round(sc, 2),
                }
                for term, _, sc in ranked[:1000]
            ],
        },
    )
    map_path = os.path.join(args.private_dir, "session-map.json")
    write_json(
        map_path,
        {
            "schemaVersion": 1,
            "private": True,
            "note": "hash -> transcript session path. LOCAL ONLY: never copy off this machine (cases.json carries only the hashes).",
            "sessions": session_map,
        },
    )

    list_sizes = [len(listed) for listed in session_lists] or [0]
    print(
        f"cases written: en {counters['en']}, fr {counters['fr']} -> {cases_path}"
    )
    print(
        f"session lists: {min(list_sizes)}-{max(list_sizes)} terms; "
        f"noise list: {len(noise)} terms"
    )
    print(f"terms written: {min(len(ranked), 1000)} -> {terms_path} (local only)")
    print(f"session map:   {len(session_map)} entries -> {map_path} (local only)")
    if args.print_terms:
        print("top 30 terms:")
        for term, st, sc in ranked[:30]:
            print(f"  {st.count:5d}x  {len(st.sessions):3d} sessions  {term}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
